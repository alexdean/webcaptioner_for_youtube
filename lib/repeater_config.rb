class RepeaterConfig
  def initialize(states)
    @current = nil
    @alternate = nil

    if states.size != 2
      raise ArgumentError, "states must have exactly 2 members."
    end

    # key: label, value: full hash
    @states = states.each_with_object({}) { |item, memo| memo[item[:label]] = item }
  end

  def set_current(key)
    if @states[key]
      @current = @states[key]
      @alternate = @states[_other_key(key)]
      true
    else
      false
    end
  end

  def send_request
    if @current
      begin
        Net::HTTP.get(URI(@current[:url]))
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT => e
        # TODO better logging
        puts "caught #{e.class} from #{@current[:url]}"
      end
      true
    else
      false
    end
  end

  def states
    @states.values
  end

  def current
    @current
  end

  def alternate
    @alternate
  end

  def _other_key(key)
    keys = @states.keys
    if key == keys[0]
      keys[1]
    else
      keys[0]
    end
  end
end
