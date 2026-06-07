module Racehooks
  # Base class for all RaceHooks SDK errors.
  class Error < StandardError; end

  # Raised when the HMAC-SHA256 signature on an incoming webhook is invalid.
  class SignatureVerificationError < Error
    def initialize(msg = "Webhook signature verification failed")
      super
    end
  end

  # Raised when the RaceHooks API returns a non-2xx response.
  class APIError < Error
    # @return [Integer] HTTP status code
    attr_reader :status_code
    # @return [String] Response body message
    attr_reader :message

    def initialize(status_code, message)
      @status_code = status_code
      @message = message
      super("RaceHooks API error #{status_code}: #{message}")
    end
  end

  # Raised when authentication fails (wrong client_id / client_secret).
  class AuthenticationError < APIError; end

  # Raised on network-level errors (timeouts, connection refused, etc.).
  class NetworkError < Error; end
end
