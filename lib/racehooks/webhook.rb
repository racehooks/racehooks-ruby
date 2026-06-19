require "openssl"
require "json"

module Racehooks
  # Payload parsed from an incoming RaceHooks webhook delivery.
  #
  # Attributes:
  # - +feed+         Feed identifier (e.g. "timingdata", "cardata", "raceevent",
  #                  "analytics.strategy", "analytics.race-odds", etc.).
  # - +session_id+   Active session ID string, or +nil+ between sessions.
  # - +data+         Feed payload as a Ruby Hash/Array (already parsed from JSON).
  #                  Present on most feeds; analytics feeds use +drivers+, +constructors+,
  #                  or +sectors+ at the top level instead.
  # - +replay+       Replay metadata Hash, or +nil+ for live deliveries.
  #
  # @example Accessing weather data
  #   event = Racehooks::Webhook.construct_event(raw_body, sig, secret)
  #   case event.feed
  #   when "weatherdata"
  #     puts event.data["AirTemp"]
  #   when "analytics.strategy"
  #     event.raw["drivers"].each { |d| puts "#{d["tla"]}: pit #{d["pitStopProbability"]}" }
  #   end
  class WebhookPayload
    attr_reader :feed, :session_id, :data, :replay, :raw

    def initialize(feed:, session_id:, data:, replay: nil, raw: {})
      @feed       = feed
      @session_id = session_id
      @data       = data
      @replay     = replay
      @raw        = raw
    end

    # Returns true when this delivery is part of a session replay.
    def replay?
      !@replay.nil?
    end
  end

  # Webhook contains the signature verification and event construction helpers
  # for incoming RaceHooks webhook deliveries.
  module Webhook
    # Computes the expected X-RaceHooks-Signature header value.
    #
    # @param secret [String] The webhook signing secret.
    # @param raw_body [String] The raw (unparsed) request body.
    # @return [String] Signature in the form "sha256=<hex>".
    # @raise [ArgumentError] if +secret+ or +raw_body+ is nil.
    def self.compute_signature(secret, raw_body)
      raise ArgumentError, "secret must not be nil"   if secret.nil?
      raise ArgumentError, "raw_body must not be nil" if raw_body.nil?

      digest = OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body)
      "sha256=#{digest}"
    end

    # Verifies the HMAC-SHA256 signature on an incoming webhook.
    #
    # Uses a constant-time comparison to prevent timing attacks.
    # Returns +false+ (rather than raising) when +signature+ is nil or empty,
    # so callers can treat a missing header the same as an invalid one.
    #
    # @param secret    [String] The webhook signing secret.
    # @param raw_body  [String] The raw (unparsed) request body.
    # @param signature [String] Value of the X-RaceHooks-Signature header.
    # @return [Boolean] +true+ if the signature is valid.
    def self.verify_signature(secret, raw_body, signature)
      return false if signature.nil? || signature.empty?

      expected = compute_signature(secret, raw_body)
      secure_compare(expected, signature)
    end

    # Parses and verifies an incoming webhook delivery.
    #
    # Raises +SignatureVerificationError+ when the signature does not match.
    # Raises +JSON::ParserError+ when the body is not valid JSON.
    #
    # @param raw_body  [String] The raw request body (do not parse before calling).
    # @param signature [String] Value of the X-RaceHooks-Signature header.
    # @param secret    [String] The webhook signing secret.
    # @return [WebhookPayload] Parsed webhook payload.
    #
    # @example Rails controller
    #   def create
    #     raw_body = request.raw_post
    #     event = Racehooks::Webhook.construct_event(
    #       raw_body,
    #       request.headers["X-RaceHooks-Signature"],
    #       ENV["RACEHOOKS_WEBHOOK_SECRET"]
    #     )
    #     # handle event...
    #     head :ok
    #   rescue Racehooks::SignatureVerificationError
    #     head :unauthorized
    #   end
    def self.construct_event(raw_body, signature, secret)
      unless verify_signature(secret, raw_body, signature)
        raise SignatureVerificationError
      end
      parse_payload(raw_body)
    end

    # Parses an incoming webhook body without verifying the signature.
    #
    # Prefer +construct_event+ when you have a signing secret.
    #
    # @param raw_body [String] The raw JSON body.
    # @return [WebhookPayload]
    def self.parse_payload(raw_body)
      parsed = JSON.parse(raw_body)
      WebhookPayload.new(
        feed:       parsed["feed"],
        session_id: parsed["sessionId"],
        data:       parsed["data"],
        replay:     parsed["_replay"],
        raw:        parsed,
      )
    end

    # Constant-time string comparison to prevent timing attacks.
    # @api private
    def self.secure_compare(a, b)
      return false if a.bytesize != b.bytesize
      res = 0
      a.bytes.zip(b.bytes) { |x, y| res |= x ^ y }
      res == 0
    end
    private_class_method :secure_compare
  end
end
