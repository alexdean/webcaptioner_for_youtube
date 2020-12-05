require_relative './queued_cue'

class YoutubeEmitter
  attr_accessor :endpoint, :enabled

  def initialize(endpoint:, logger:, enabled:, transcript: nil)
    @queue = Queue.new
    @endpoint = endpoint
    @yt_post_sequence = 0
    @logger = logger
    @enabled = enabled
    @transcript = transcript
  end

  def enqueue(sequence, transcript)
    @queue.push(QueuedCue.new(sequence: sequence, transcript: transcript))
  end

  # TODO: error if a thread is already running. (@yt_post_sequence is not thread-safe.)
  def run_async
    Thread.new do
      loop do
        run_sync
        sleep 0.2
      end
    end
  end

  def run_sync
    @logger.debug 'run_sync started'

    outbox = []
    while !@queue.empty?
      outbox << @queue.pop
    end

    if @enabled && !outbox.empty?
      @logger.debug 'outbox has items'

      @yt_post_sequence += 1
      uri = URI("#{@youtube_endpoint}&seq=#{@yt_post_sequence}")

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

      @logger.debug do
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

        # docs for POST format
        # https://support.google.com/youtube/answer/6077032?&ref_topic=2853697
        #
        # my stream setup
        # https://studio.youtube.com/channel/UCEX9BscEMpJfaASiewenbYg/livestreaming/dashboard?v=dt-jMQXntJE
        #
        # this is the endpoint we POST cue info to. it's specific to a live stream.
        # anyone with this URL can post cues to your stream, so it should be treated as private information.
        output << current_cue_time.utc.strftime('%Y-%m-%dT%H:%M:%S.%3N') + "\n" + cue_words.join(' ') + ' '

        current_cue_time = current_cue_time + time_between_cues
      end

      # POST body must end with a final \n or YT rejects the post. ("unable to parse post body.")
      payload = output.join("\n") + "\n"

      if @transcript
        @transcript.write "#{payload}\n"
      end

      begin
        # TODO: response from YT is a timestamp (when the post was processed.)
        # use this to synchronize the clocks, to correct for drift on my local machine?
        # TODO: set a short timeout. better to drop captions than to block for too long.
        res = Net::HTTP.post(uri, payload)
        @logger.debug res.body.inspect
      rescue Errno::ECONNREFUSED => e
        @logger.error "#{e.class} #{e.message}"
      end

      @logger.debug 'run_sync finished'
    end
  end
end
