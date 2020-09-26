require 'minitest/autorun'
require_relative '../../lib/storage'

describe Storage do
  before do
    @file = '/tmp/storage_test.yml'
  end

  after do
    if File.exist?(@file)
      File.unlink(@file)
    end
  end

  describe '#set' do
    it 'can create a previously-nonexistent data file' do
      assert_equal false, File.exist?(@file)

      subject = Storage.new(@file)
      subject.set('key', 'value')

      assert_equal true, File.exist?(@file)
    end

    it 'writes set values as yaml' do
      subject = Storage.new(@file)
      subject.set('key', 'value')
      assert_equal "---\nkey: value\n", File.read(@file)
    end
  end

  describe '#get' do
    it 'returns nil if file doesnt exist' do
      subject = Storage.new(@file)
      assert_equal false, File.exist?(@file)

      assert_nil subject.get('key')
    end

    it 'returns nil if key is not in file' do
      subject = Storage.new(@file)
      subject.set('a', 'AAA')

      assert_nil subject.get('b')
    end

    it 'retrieves data from file' do
      File.open(@file, 'w') { |f| f.write("---\nkey: value\n") }
      subject = Storage.new(@file)

      assert_equal 'value', subject.get('key')
    end
  end

  it 'sets and gets multiple values' do
    subject = Storage.new(@file)

    subject.set('a', 'AAA')
    subject.set('b', 'BBB')

    assert_equal 'AAA', subject.get('a')
    assert_equal 'BBB', subject.get('b')
  end
end
