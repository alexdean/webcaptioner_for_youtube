# cue text we've received which should be relayed to youtube.
class QueuedCue
  attr_reader :sequence, :transcript, :timestamp
  def initialize(sequence:, transcript:, latency: 0)
    @sequence = sequence,
    @transcript = transcript

    # webcaptioner supplies a sequence value for ordering, but does not provide
    # timing info to know what time a given word was spoken. since there is
    # some processing delay, assuming received-time is identical to spoken-time
    # produces some drift between spoken words and on-screen captions. this
    # latency value allows this to be tuned/accounted-for somewhat.
    @timestamp = Time.now - latency
  end
end
