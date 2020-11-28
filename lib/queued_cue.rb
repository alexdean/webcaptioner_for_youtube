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
