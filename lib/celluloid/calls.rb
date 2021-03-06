module Celluloid
  # Calls represent requests to an actor
  class Call
    attr_reader :method, :arguments, :block

    def initialize(method, arguments = [], block = nil)
      @method, @arguments, @block = method, arguments, block
    end

  end

  # Synchronous calls wait for a response
  class SyncCall < Call
    attr_reader :caller, :task

    def initialize(caller, method, arguments = [], block = nil, task = Thread.current[:celluloid_task])
      super(method, arguments, block)
      @caller = caller
      @task = task
    end

    def dispatch(obj)
      begin
        result = obj.public_send(@method, *@arguments, &@block)
      rescue NoMethodError => ex
        # Abort if the caller made a mistake
        detect_missing_method(ex)

        # Otherwise something blew up. Crash this actor
        raise
      rescue ArgumentError => ex
        # Abort if the caller made a mistake
        detect_argument_error(ex)

        # Otherwise something blew up. Crash this actor
        raise
      end

      respond SuccessResponse.new(self, result)
    rescue Exception => ex
      # Exceptions that occur during synchronous calls are reraised in the
      # context of the caller
      respond ErrorResponse.new(self, ex)

      # Aborting indicates a protocol error on the part of the caller
      # It should crash the caller, but the exception isn't reraised
      # Otherwise, it's a bug in this actor and should be reraised
      raise unless ex.is_a?(AbortError)
    end

    def cleanup
      exception = DeadActorError.new("attempted to call a dead actor")
      respond ErrorResponse.new(self, exception)
    end

    def respond(message)
      @caller << message
    rescue MailboxError
      # It's possible the caller exited or crashed before we could send a
      # response to them.
    end

  private

    # Detect NoMethodErrors made by the caller and abort
    def detect_missing_method(ex)
      ex.backtrace.each do |frame|
        break if frame["celluloid/lib/celluloid/calls.rb"] || frame["`public_send'"]
        return unless frame["`method_missing'"]
      end

      raise AbortError.new(ex)
    end

    # Detect ArgumentErrors made by the caller and abort
    def detect_argument_error(ex)
      if ex.backtrace[0]["`#{@method}'"] && ex.backtrace[1]["`public_send'"]
        raise AbortError.new(ex)
      end
    end
  end

  # Asynchronous calls don't wait for a response
  class AsyncCall < Call

    def dispatch(obj)
      obj.public_send(@method, *@arguments, &@block)
    rescue AbortError => ex
      # Swallow aborted async calls, as they indicate the caller made a mistake
      Logger.debug("#{obj.class}: async call `#@method` aborted!\n#{Logger.format_exception(ex.cause)}")
    end

  end

end
