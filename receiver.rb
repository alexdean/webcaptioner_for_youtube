require 'sinatra'
require 'net/http'
require 'time'
require 'logger'
require_relative 'lib/storage'
require_relative 'lib/repeater_config'

set :logging, false
$request_log = Logger.new($stderr)

$storage = Storage.new('data.yml')
# valid repeat configs.
$repeater_config = Marshal.load($storage.get('repeater_config'))
$repeater_config_mutex = Mutex.new

# thread that makes requests based on repeater_config, to keep tally lights alive.
Thread.new do
  repeater_config = nil

  loop do
    $repeater_config_mutex.synchronize do
      repeater_config = $repeater_config.dup
    end

    repeater_config.each do |_key, item|
      item.send_request
    end

    sleep 3
  end
end

# docs for POST format
# https://support.google.com/youtube/answer/6077032?&ref_topic=2853697
#
# my stream setup
# https://studio.youtube.com/channel/UCEX9BscEMpJfaASiewenbYg/livestreaming/dashboard?v=dt-jMQXntJE
#
# this is the endpoint we POST cue info to. it's specific to a live stream.
# anyone with this URL can post cues to your stream, so it should be treated as private information.
$youtube_endpoint = $storage.get('youtube_endpoint')

log_file = File.open('output.txt', 'a')
log_file.sync = true
$cue_log = Logger.new(log_file)
$cue_log.level = Logger::INFO
$cue_log.formatter = proc { |severity, datetime, progname, msg|
  "------------ #{datetime.utc.strftime('%Y-%m-%dT%H:%M:%S.%3N')} ------------#{msg}"
}

$enabled = true
$queue = Queue.new

Thread.new do
  $yt_post_sequence = 0

  loop do
    outbox = []
    while !$queue.empty?
      outbox << $queue.pop
    end

    if $enabled && !outbox.empty?
      $yt_post_sequence += 1
      uri = URI("#{$youtube_endpoint}&seq=#{$yt_post_sequence}")

      # webhooks can be received out of order
      # we need to sort by the webcaptioner sequence values
      # since sequence is more correct that the recieved-at timestamps,
      # we will assign each cue to a time based on linear interpolation of
      # the min and max times we see.

      desired_words_per_cue = 1

      now = Time.now
      min_time = now + (3600 * 24)
      max_time = now - (3600 * 24)

      outbox.each do |cue|
        if cue.timestamp < min_time
          min_time = cue.timestamp
        end

        if cue.timestamp > max_time
          max_time = cue.timestamp
        end
      end

      total_duration = max_time - min_time

      words = outbox
                .sort_by {|cue| cue.sequence }
                .map { |cue| cue.transcript.strip } # strip to remove newlines sometimes added by webcaptioner

      time_between_cues = if total_duration == 0
                            0
                          else
                            desired_cue_count = (words.size / desired_words_per_cue.to_f).ceil
                            total_duration / desired_cue_count.to_f
                          end

      $cue_log.debug do
        "desired_cue_count:#{desired_cue_count}" \
        " max_time:#{max_time}" \
        " min_time:#{min_time}" \
        " total_duration:#{total_duration}" \
        " time_between_cues:#{time_between_cues}"
      end

      output = []
      current_cue_time = min_time
      loop do
        cue_words = words.shift(desired_words_per_cue)
        break if cue_words.size == 0

        output << current_cue_time.utc.strftime('%Y-%m-%dT%H:%M:%S.%3N') + "\n" + cue_words.join(' ') + ' '

        current_cue_time = current_cue_time + time_between_cues
      end

      # POST body must end with a final \n or YT rejects the post. ("unable to parse post body.")
      payload = output.join("\n") + "\n"

      # TODO handle & retry errors from YT endpoint
      # last_post_at = Time.now
      res = Net::HTTP.post(uri, payload)
      $cue_log.info "\n#{payload}"
      $cue_log.debug res.body.inspect

      # TODO: response from YT is a timestamp (when the post was processed.)
      # use this to synchronize the clocks, to correct for drift on my local machine?
    end

    sleep 0.2
  end
end

get '/' do
  redirect '/setup'
end

post '/captions' do
  request.body.rewind
  data = JSON.parse(request.body.read)

  $queue.push(
    QueuedCue.new(sequence: data['sequence'], transcript: data['transcript'])
  )

  status 200
  content_type 'application/json'
  {status: 'ok'}.to_json
end

get '/control' do
  repeater_config = nil
  $repeater_config_mutex.synchronize do
    repeater_config = $repeater_config.dup
  end
  erb(:control, locals: { enabled: $enabled, repeater_config: repeater_config })
end

# todo need to accept changes to repeat value
# maybe post to /repeater and that can redirect to /control based on content-type
post '/control' do
  if params['enabled'] == 'true'
    $enabled = true
  elsif params['enabled'] == 'false'
    $enabled = false
  end

  repeater_config = nil
  $repeater_config_mutex.synchronize do
    repeater_config = $repeater_config.dup
  end
  erb(:control, locals: { enabled: $enabled, repeater_config: repeater_config })
end

get '/setup' do
  erb(:setup, locals: { youtube_endpoint: $youtube_endpoint })
end

post '/setup' do
  if params['youtube_endpoint']
    $youtube_endpoint = params['youtube_endpoint']
    $storage.set('youtube_endpoint', $youtube_endpoint)
  end

  redirect '/control'
end

get '/repeater' do
  content_type 'application/json'

  key = params[:key] # A
  value = params[:value] # GREEN

  repeater_config = nil
  $repeater_config_mutex.synchronize do
    repeater_config = $repeater_config[key]
  end

  errors = []

  if !repeater_config
    errors << "unknown key #{key}"
  end

  if errors.empty? && value != ''
    ok = false

    $repeater_config_mutex.synchronize do
      ok = repeater_config.set_current(value)
    end

    if !ok
      errors << "unknown value #{value} for key #{key}"
    end
  end

  if errors.empty?
    # want endpoint to complete as quickly as possible so OBS isn't blocked
    Thread.new { repeater_config.send_request }

    status 200
    {status: 'ok'}.to_json
  else
    status 400
    {status: 'error', errors: errors}.to_json
  end
end
