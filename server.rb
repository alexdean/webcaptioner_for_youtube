require 'sinatra'
require 'net/http'
require 'time'
require 'logger'
require_relative 'lib/storage'
require_relative 'lib/repeater'
require_relative 'lib/youtube_emitter'

$storage = Storage.new('data.yml')

$repeater = Marshal.load($storage.get('repeater'))
$repeater_mutex = Mutex.new

# thread that makes requests based on repeater, to keep tally lights alive.
Thread.new do
  repeater = nil

  loop do
    $repeater_mutex.synchronize do
      repeater = $repeater.dup
    end

    repeater.each do |_key, item|
      item.send_request
    end

    sleep 3
  end
end

log_file = File.open('log.txt', 'a')
log_file.sync = true
cue_log = Logger.new(log_file)
cue_log.level = Logger::DEBUG
# cue_log.formatter = proc { |severity, datetime, progname, msg|
#   "------------ #{datetime.utc.strftime('%Y-%m-%dT%H:%M:%S.%3N')} ------------\n#{msg}\n"
# }

transcript = File.open('transcript.txt', 'a')
transcript.sync = true

$emitter = YoutubeEmitter.new(
             endpoint: $storage.get('youtube_endpoint'),
             enabled: true,
             send_heartbeat: true,
             latency: 0,
             logger: cue_log,
             transcript: transcript
           )

$emitter.start_async

get '/' do
  redirect '/setup'
end

post '/captions' do
  request.body.rewind
  data = JSON.parse(request.body.read)

  $emitter.enqueue(data['sequence'], data['transcript'])

  status 200
  content_type 'application/json'
  {status: 'ok'}.to_json
end

get '/control' do
  repeater = nil
  $repeater_mutex.synchronize do
    repeater = $repeater.dup
  end
  erb(:control, locals: { enabled: $emitter.enabled, repeater: repeater })
end

# todo need to accept changes to repeat value
# maybe post to /repeater and that can redirect to /control based on content-type
post '/control' do
  if params['enabled'] == 'true'
    $emitter.enabled = true
  elsif params['enabled'] == 'false'
    $emitter.enabled = false
  end

  repeater = nil
  $repeater_mutex.synchronize do
    repeater = $repeater.dup
  end
  erb(:control, locals: { enabled: $emitter.enabled, repeater: repeater })
end

get '/setup' do
  erb(:setup, locals: { youtube_endpoint: $emitter.endpoint })
end

post '/setup' do
  if params['youtube_endpoint']
    $emitter.endpoint = params['youtube_endpoint']
    $storage.set('youtube_endpoint', $emitter.endpoint)
  end

  redirect '/control'
end

repeater_proc = lambda do
  content_type 'application/json'

  key = params[:key] # A
  value = params[:value] # GREEN

  repeater = nil
  $repeater_mutex.synchronize do
    repeater = $repeater[key]
  end

  errors = []

  if !repeater
    errors << "unknown key #{key}"
  end

  if errors.empty?
    ok = false

    $repeater_mutex.synchronize do
      ok = repeater.set_current(value)
    end

    if !ok
      errors << "unknown value #{value} for key #{key}"
    end
  end

  if errors.empty?
    # want endpoint to complete as quickly as possible so OBS isn't blocked
    Thread.new { repeater.send_request }
    ok = true
    status 200
    body = {status: 'ok'}.to_json
  else
    ok = false
    status 400
    body = {status: 'error', errors: errors}.to_json
  end

  if ok && request.env['CONTENT_TYPE'] == "application/x-www-form-urlencoded"
    redirect '/control'
  else
    body
  end
end

get '/repeater', &repeater_proc
post '/repeater', &repeater_proc
