require_relative './queued_cue'
require_relative './null_logger'

class YoutubeEmitter
  attr_accessor :endpoint, :enabled, :send_heartbeat, :latency

  def initialize(endpoint:, enabled: true, logger: nil, transcript: nil, send_heartbeat: true, latency: 0)
    @endpoint = endpoint
    @enabled = enabled
    @logger = logger || NullLogger.new
    @transcript = transcript
    @send_heartbeat = send_heartbeat
    @latency = latency

    @yt_drift = 0

    @queue = Queue.new
    @yt_post_sequence = 0
  end

  def enqueue(sequence, transcript)
    @queue.push(
      QueuedCue.new(sequence: sequence, transcript: transcript, latency: @latency)
    )
  end

  # TODO: error if a thread is already running. (@yt_post_sequence is not thread-safe.)
  def start_async(flush_interval: 1)
    Thread.new do
      loop do
        flush
        sleep flush_interval
      end
    end
  end

  def flush
    @logger.debug 'flush started'

    outbox = []
    while !@queue.empty?
      outbox << @queue.pop
    end

    if outbox.empty? && @send_heartbeat
      outbox << QueuedCue.new(sequence: 1, transcript: '', latency: @latency)
    end

    if @enabled && !outbox.empty?
      @yt_post_sequence += 1
      uri = URI("#{@endpoint}&seq=#{@yt_post_sequence}")

      # webhooks can be received out of order
      # we need to sort by the webcaptioner sequence values
      # since sequence is more correct that the recieved-at timestamps,
      # we will assign each cue to a time based on linear interpolation of
      # the min and max times we see.

      # some error when this is 5.
      # we get time_between_cues of Infinity.
      desired_words_per_cue = 1

      now = Time.now
      min_time = now + (3600 * 24)
      max_time = now - (3600 * 24)

      outbox.each do |cue|
        # puts "min_time:#{min_time}"
        # puts "max_time:#{max_time}"
        # puts cue.timestamp
        # puts
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
      has_words = words.size > 0

      time_between_cues = if total_duration == 0
                            0
                          else
                            desired_cue_count = (words.size / desired_words_per_cue.to_f).ceil
                            total_duration / (desired_cue_count - 1).to_f
                          end

      @logger.debug do
        <<~EOF

        min_time:#{min_time}
        max_time:#{max_time}
        total_duration:#{total_duration}
        desired_cue_count:#{desired_cue_count}
        time_between_cues:#{time_between_cues}
        desired_cue_count:#{desired_cue_count}
        EOF
      end

      output = []
      current_cue_time = min_time
      loop do
        cue_words = words.shift(desired_words_per_cue)

        break if cue_words.size == 0 && output.size > 0

        # docs for POST format
        # https://support.google.com/youtube/answer/6077032?&ref_topic=2853697
        #
        # my stream setup
        # https://studio.youtube.com/channel/UCEX9BscEMpJfaASiewenbYg/livestreaming/dashboard?v=dt-jMQXntJE
        #
        # this is the endpoint we POST cue info to. it's specific to a live stream.
        # anyone with this URL can post cues to your stream, so it should be treated as private information.

        # compensate for clock drift.
        adjusted_time = current_cue_time - @yt_drift

        # initial space on text lines because words from multiple cues are concatenated. w/o that space words are smushed together.
        output << adjusted_time.utc.strftime('%Y-%m-%dT%H:%M:%S.%3N') + "\n " + cue_words.join(' ')

        @logger.debug "     cue_time: #{current_cue_time.utc.strftime('%Y-%m-%dT%H:%M:%S.%3N')}"
        @logger.debug "adjusted_time: #{adjusted_time.utc.strftime('%Y-%m-%dT%H:%M:%S.%3N')}"

        current_cue_time = current_cue_time + time_between_cues
      end

      # POST body must end with a final \n or YT rejects the post. ("unable to parse post body.")
      payload = output.join("\n") + "\n"

      if @transcript && has_words
        @transcript.write "#{payload}\n"
      end

      begin
        # TODO: response from YT is a timestamp (when the post was processed.)
        # use this to synchronize the clocks, to correct for drift on my local machine?
        # TODO: set a short timeout. better to drop captions than to block for too long.
        @logger.debug uri
        @logger.debug payload

        res = Net::HTTP.post(uri, payload)

        server_time = Time.parse(res.body.strip + 'Z')
        local_time = Time.now
        @yt_drift = local_time - server_time

        @logger.debug "response:#{res.code}"
        @logger.debug "         #{res.body.inspect}"
        @logger.debug "         #{local_time.strftime('%Y-%m-%dT%H:%M:%S.%3N')}"
        @logger.debug "         #{@yt_drift}"
      rescue Errno::ECONNREFUSED => e
        @logger.error "#{e.class} #{e.message}"
      end

      @logger.debug 'flush finished'
    end
  end
end
