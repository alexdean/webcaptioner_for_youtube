require 'test_helper'
require 'logger'
require_relative '../../lib/youtube_emitter'

describe YoutubeEmitter do
  before do
    @endpoint = 'http://upload.youtube.com/closedcaption?cid=XXXXXX'
    @logger = Logger.new($stdout, level: Logger::ERROR)
    @subject = YoutubeEmitter.new(endpoint: @endpoint, logger: @logger)
  end

  describe '#enqueue and #flush' do
    it 'POSTs an enqueued cue' do
      Timecop.freeze('2020-12-05T16:00:00Z') { @subject.enqueue(1, 'text') }

      expected_body = <<~EOF
        2020-12-05T16:00:00.000
         text
      EOF

      stub_post = stub_request(:post, "#{@endpoint}&seq=1")
                  .with(body: expected_body)
                  .and_return(body: "2020-12-05T16:00:00.000\n")

      Timecop.freeze("2020-12-05T16:00:00Z") do
        @subject.flush
      end

      assert_requested stub_post
    end

    it 'reorders cues by sequence value and distributes them across the received time range' do
      Timecop.freeze('2020-12-05T16:00:00Z') { @subject.enqueue(1, 'text1') }
      Timecop.freeze('2020-12-05T16:00:01Z') { @subject.enqueue(3, 'text3') }
      Timecop.freeze('2020-12-05T16:00:02Z') { @subject.enqueue(2, 'text2') }
      Timecop.freeze('2020-12-05T16:00:03Z') { @subject.enqueue(5, 'text5') }
      Timecop.freeze('2020-12-05T16:00:04Z') { @subject.enqueue(4, 'text4') }

      expected_body = <<~EOF
        2020-12-05T16:00:00.000
         text1
        2020-12-05T16:00:01.000
         text2
        2020-12-05T16:00:02.000
         text3
        2020-12-05T16:00:03.000
         text4
        2020-12-05T16:00:04.000
         text5
      EOF

      stub_post = stub_request(:post, "#{@endpoint}&seq=1")
                  .with(body: expected_body)
                  .and_return(body: "2020-12-05T16:00:04.000\n")

      Timecop.freeze("2020-12-05T16:00:04Z") do
        @subject.flush
      end

      assert_requested stub_post
    end

    # see comments in QueuedCue for explanation
    it 'can compensate for latency in cue reception' do
      @subject.latency = 2.5

      Timecop.freeze('2020-12-05T16:00:00Z') { @subject.enqueue(1, 'text1') }
      Timecop.freeze('2020-12-05T16:00:01Z') { @subject.enqueue(3, 'text3') }
      Timecop.freeze('2020-12-05T16:00:02Z') { @subject.enqueue(2, 'text2') }

      expected_body = <<~EOF
        2020-12-05T15:59:57.500
         text1
        2020-12-05T15:59:58.500
         text2
        2020-12-05T15:59:59.500
         text3
      EOF

      stub_post = stub_request(:post, "#{@endpoint}&seq=1")
                  .with(body: expected_body)
                  .and_return(body: "2020-12-05T15:59:59.500\n")

      Timecop.freeze("2020-12-05T15:59:59.500Z") do
        @subject.flush
      end

      assert_requested stub_post
    end

    it 'increments &seq= after each flush' do
      Timecop.freeze('2020-12-05T16:00:00Z') { @subject.enqueue(1, 'text1') }
      Timecop.freeze('2020-12-05T16:00:01Z') { @subject.enqueue(2, 'text2') }

      expected_body = <<~EOF
        2020-12-05T16:00:00.000
         text1
        2020-12-05T16:00:01.000
         text2
      EOF

      stub_post = stub_request(:post, "#{@endpoint}&seq=1")
                  .with(body: expected_body)
                  .and_return(body: "2020-12-05T16:00:01.000\n")

      Timecop.freeze('2020-12-05T16:00:01Z') do
        @subject.flush
      end

      assert_requested stub_post

      Timecop.freeze('2020-12-05T16:00:02Z') { @subject.enqueue(3, 'text3') }
      Timecop.freeze('2020-12-05T16:00:03Z') { @subject.enqueue(4, 'text4') }

      expected_body = <<~EOF
        2020-12-05T16:00:02.000
         text3
        2020-12-05T16:00:03.000
         text4
      EOF

      stub_post = stub_request(:post, "#{@endpoint}&seq=2")
                  .with(body: expected_body)
                  .and_return(body: "2020-12-05T16:00:03.000\n")

      Timecop.freeze("2020-12-05T16:00:03Z") do
        @subject.flush
      end

      assert_requested stub_post
    end

    it 'adjusts caption timing based on drift between local clock and time returned from server' do
      server_time = "2020-12-05T16:00:00.750"
      local_time  = "2020-12-05T16:00:00.250"

      stub_post = stub_request(:post, "#{@endpoint}&seq=1")
                  .with(body: "#{local_time}\n \n")
                  .and_return(body: "#{server_time}\n")

      Timecop.freeze("#{local_time}Z") do
        @subject.flush
      end

      assert_requested stub_post

      # drift between server & local is 500ms so we expect that to be added to later captions

      Timecop.freeze('2020-12-05T16:01:00Z') { @subject.enqueue(1, 'text1') }

      expected_body = <<~EOF
        2020-12-05T16:01:00.500
         text1
      EOF

      stub_post = stub_request(:post, "#{@endpoint}&seq=2")
                  .with(body: expected_body)
                  .and_return(body: "#{server_time}\n")

      Timecop.freeze('2020-12-05T16:01:00Z') do
        @subject.flush
      end

      assert_requested stub_post
    end

    describe 'when nothing is enqueued' do
      describe 'when send_heartbeat is true' do
        # YT docs say...
        # "HTTP POSTs with an empty body, or an empty text line after the timestamp
        # line, MAY be used to perform a heartbeat function."
        it 'sends an empty payload' do
          Timecop.freeze('2020-12-05T16:00:00Z') do
            @subject.send_heartbeat = true

            expected_body = "2020-12-05T16:00:00.000\n \n"

            stub_post = stub_request(:post, "#{@endpoint}&seq=1")
                  .with(body: expected_body)
                  .and_return(body: "2020-12-05T16:00:00.000\n")

            Timecop.freeze("2020-12-05T16:00:00Z") do
              @subject.flush
            end

            assert_requested stub_post
          end
        end
      end

      describe 'when send_heartbeat is false' do
        it 'sends nothing' do
          @subject.send_heartbeat = false
          @subject.flush
        end
      end
    end
  end
end
