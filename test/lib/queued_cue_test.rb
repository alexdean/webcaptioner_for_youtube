require 'test_helper'
require 'logger'
require_relative '../../lib/queued_cue'

describe QueuedCue do
  it 'can adjust timestamp when given latency' do
    Timecop.freeze '2020-12-05T12:00:00Z' do
      subject = QueuedCue.new(sequence: 1, transcript: 'text', latency: 2)

      assert_equal subject.timestamp.iso8601, '2020-12-05T11:59:58Z'
    end
  end

  it 'does not require latency' do
    Timecop.freeze '2020-12-05T12:00:00Z' do
      subject = QueuedCue.new(sequence: 1, transcript: 'text')

      assert_equal subject.timestamp.iso8601, '2020-12-05T12:00:00Z'
    end
  end
end
