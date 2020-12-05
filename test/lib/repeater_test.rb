require 'test_helper'
require_relative '../../lib/repeater'

describe Repeater do
  before do
    @red_config = { label: 'RED', url:'http://10.4.2.12/RED', color: '#FF0000' }
    @green_config = { label: 'GREEN', url:'http://10.4.2.12/GREEN', color: '#00FF00' }

    @subject = Repeater.new([
      @red_config,
      @green_config
    ])
  end

  describe '#initialize' do
    it 'raises an error if not given exactly 2 config hashes' do
      assert_raises(ArgumentError) do
        Repeater.new
      end

      assert_raises(ArgumentError) do
        Repeater.new([{}])
      end

      assert_raises(ArgumentError) do
        Repeater.new([{}, {}, {}])
      end

      Repeater.new([{}, {}])
    end
  end

  describe '#set_current and accessors' do
    it 'sets current, alternate, and returns true' do
      out = @subject.set_current('RED')

      assert_equal true, out

      assert_equal @red_config, @subject.current
      assert_equal @green_config, @subject.alternate
    end

    it 'returns false and does not update if given key does not exist' do
      @subject.set_current('GREEN')

      out = @subject.set_current('WHAT')

      assert_equal false, out

      assert_equal @green_config, @subject.current
    end
  end

  describe '#send_request' do
    it 'sends and returns true if config has a current value' do
      stub_get = stub_request(:get, @green_config[:url])

      @subject.set_current('GREEN')

      out = @subject.send_request

      assert_equal true, out
      assert_requested stub_get
    end

    it 'returns false if config has no current value' do
      stub_get = stub_request(:get, @green_config[:url])

      out = @subject.send_request

      assert_equal false, out
      assert_not_requested stub_get
    end
  end
end
