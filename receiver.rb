require 'sinatra'
require 'net/http'
require 'time'
require 'logger'

log_file = File.open('output.txt', 'w')
log_file.sync = true
$log = Logger.new(log_file)
$log.level = Logger::ERROR

# docs for POST format
# https://support.google.com/youtube/answer/6077032?&ref_topic=2853697

$yt_post_sequence = 0
$queue = Queue.new

# cue text we've received which should be relayed to youtube.
class QueuedCue
  attr_reader :sequence, :transcript, :timestamp
  def initialize(sequence:, transcript:)
    @sequence = sequence,
    @transcript = transcript
    @timestamp = now_with_latency
  end

  def now_with_latency
    # seconds to offset caption timing
    # to account for webcaptioner latency
    #
    # webcaptioner supplies a sequence value for ordering, but does not provide
    # timing info to know what time a given word was spoken. since there is
    # some processing delay, assuming received-time is identical to spoken-time
    # produces some drift between spoken words and on-screen captions. this
    # latency value allows this to be tuned/accounted-for somewhat.
    captioning_latency = 2.5

    Time.now - captioning_latency
  end
end

Thread.new do
  loop do
    outbox = []
    while !$queue.empty?
      outbox << $queue.pop
    end

    # if we haven't received anything during this iteration, we'll still send an
    # empty POST to YT as a heartbeat.
    if outbox.empty?
      outbox << QueuedCue.new(sequence: 0, transcript: '')
    end

    $yt_post_sequence += 1
    uri = URI("http://upload.youtube.com/closedcaption?cid=9wbd-jcvx-0phb-6xh9-fj0a&seq=#{$yt_post_sequence}")

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

    $log.debug "desired_cue_count:#{desired_cue_count} max_time:#{max_time} min_time:#{min_time} total_duration:#{total_duration} time_between_cues:#{time_between_cues}"

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

    $log.info payload
    # TODO handle & retry errors
    # last_post_at = Time.now
    res = Net::HTTP.post(uri, payload)
    # puts '------------------>'
    # puts payload
    # puts '<------------------'
    # puts res.body.inspect
    # puts '------------------'
    # puts

    # TODO: response from YT is a timestamp (when the post was processed.)
    # use this to synchronize the clocks, to correct for drift on my local machine.


    sleep 0.2
  end
end

post '/captions' do


  request.body.rewind
  data = JSON.parse(request.body.read)

  # have to add a space after each transcript chunk, otherwise captions have no spaces between words.
  # stripping because webcaptioner adds a "\n" when it thinks a line break should occur, but we
  # want to let youtube decide where to put the breaks.

  $queue.push(
    QueuedCue.new(sequence: data['sequence'], transcript: data['transcript'])
  )

  status 200
  content_type 'application/json'
  {status: 'ok'}.to_json
end



