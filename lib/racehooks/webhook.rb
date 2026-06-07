require "openssl"
require "json"

module Racehooks
  # Payload parsed from an incoming RaceHooks webhook delivery.
  #
  # Attributes:
  # - +type+         Feed identifier (e.g. "timingdata", "cardata", "raceevent").
  # - +session_id+   Active session ID string, or +nil+ between sessions.
  # - +data+         Feed payload as a Ruby Hash/Array (already parsed from JSON).
  # - +analytics+    Analytics enrichment Hash, or +nil+ if not present.
  # - +replay+       Replay metadata Hash, or +nil+ for live deliveries.
  #
  # @example Accessing weather data
  #   event = Racehooks::Webhook.construct_event(raw_body, sig, secret)
  #   case event.type
  #   when "weatherdata"
  #     puts event.data["AirTemp"]
  #   end
  class WebhookPayload
    attr_reader :type, :session_id, :data, :analytics, :replay

    def initialize(type:, session_id:, data:, analytics: nil, replay: nil)
      @type       = type
      @session_id = session_id
      @data       = data
      @analytics  = analytics
      @replay     = replay
    end

    # Returns true when analytics enrichment data is present in this delivery.
    def analytics?
      !@analytics.nil?
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
    def self.compute_signature(secret, raw_body)
      digest = OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body)
      "sha256=#{digest}"
    end

    # Verifies the HMAC-SHA256 signature on an incoming webhook.
    #
    # Uses a constant-time comparison to prevent timing attacks.
    #
    # @param secret    [String] The webhook signing secret.
    # @param raw_body  [String] The raw (unparsed) request body.
    # @param signature [String] Value of the X-RaceHooks-Signature header.
    # @return [Boolean] +true+ if the signature is valid.
    def self.verify_signature(secret, raw_body, signature)
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
        type:       parsed["type"],
        session_id: parsed["sessionId"],
        data:       parsed["data"],
        analytics:  parsed["analytics"],
        replay:     parsed["_replay"],
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
