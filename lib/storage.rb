require 'yaml'

# bare-bones on-disk persistence.
class Storage
  attr_reader :file

  def initialize(file)
    @file = file
  end

  def get(key)
    data[key]
  end

  def set(key, value)
    updated = data
    updated[key] = value
    File.open(file, 'w') { |f| f.write(YAML.dump(updated)) }
  end

  private

  def data
    begin
      YAML.load_file(file)
    rescue Errno::ENOENT
      {}
    end
  end
end
