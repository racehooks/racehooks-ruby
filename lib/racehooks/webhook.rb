require "openssl"
require "json"

module Racehooks
  # Payload parsed from an incoming RaceHooks webhook delivery.
  #
  # Every delivery follows the same envelope: a canonical hyphenated +feed+
  # discriminator (e.g. "timing.data", "events.race", "analytics.strategy"),
  # a +sessionId+, a +utc+ timestamp, and the feed body. Driver entries carry the
  # full DriverRef identity block: +driverId+, +constructorId+, +number+, +tla+,
  # +name+, +team+.
  #
  # Attributes:
  # - +feed+             Canonical feed identifier (e.g. "timing.data", "weather.data",
  #                      "events.race", "analytics.strategy", "weather.forecast-update").
  # - +session_id+       Active session ID string, or +nil+ between sessions.
  # - +event+            Event slug on events.race/events.qualifying ("overtake") and
  #                      weather feeds ("rain-onset", "forecast-update"); +nil+ otherwise.
  # - +data+             Feed payload Hash for session-wide and data-wrapped feeds.
  # - +drivers+          Array of per-driver DriverRef Hashes. Present for timing.data,
  #                      analytics.strategy, analytics.race-odds, analytics.gap-projection,
  #                      and analytics.tire-strategy.
  # - +constructors+     Array of constructor Hashes. Present for analytics.team-points.
  # - +sectors+          Sector-probability Hash. Present for analytics.qualifying.
  # - +pairs+            Array of same-constructor H2H Hashes. Present for analytics.race-odds.
  # - +race_id+          Race identifier string, distinct from +session_id+. Present on
  #                      analytics feeds (nullable).
  # - +lap+              Race lap number. Present on per-lap analytics feeds.
  # - +utc+              UTC timestamp string. Present on most feeds.
  # - +after_race_id+    Identifies which race triggered the payload. Present on
  #                      analytics.championship-probability.
  # - +regulations_era+  Regulations era string (e.g. "2026"). Present on analytics feeds.
  # - +replay+           Replay metadata Hash (+simulationId+, +originalSessionId+,
  #                      +sessionElapsed+), or +nil+ for live deliveries.
  # - +raw+              The full parsed Hash. Use +event[key]+ to read fields on the
  #                      flat weather feeds (weather.forecast-update, .tire-mismatch,
  #                      .compound-crossover), whose fields live at the top level.
  #
  # The Analytics tier delivers a range of derived +analytics.*+ and +weather.*+
  # feeds: the live-alert feeds (analytics.sector-pace, .battle, .pit-window,
  # .track-conditions, .pit-quality) and data-wrapped weather feeds (rain-onset,
  # rain-cleared, strategy-divergence) carry their payload in +data+; the flat
  # weather feeds expose fields at the top level (read via +event[...]+).
  #
  # @example
  #   event = Racehooks::Webhook.construct_event(raw_body, sig, secret)
  #   case event.feed
  #   when "weather.data"
  #     puts event.data["AirTemp"]
  #   when "analytics.strategy"
  #     event.drivers.each { |d| puts "#{d["tla"]}: pit #{d["pitStopProbability"]}" }
  #   when "analytics.battle"
  #     puts "battle: #{event.data["battleStatus"]} (lap #{event.lap})"
  #   when "weather.forecast-update"
  #     puts "rain #{event["precipProbabilityPct"]}% — model #{event["model"]}"
  #   end
  class WebhookPayload
    attr_reader :feed, :session_id, :event, :data, :drivers, :constructors, :sectors,
                :pairs, :race_id, :lap, :utc, :after_race_id, :regulations_era, :replay, :raw

    def initialize(parsed)
      @raw              = parsed
      @feed             = parsed["feed"]
      @session_id       = parsed["sessionId"]
      @event            = parsed["event"]
      @data             = parsed["data"]
      @drivers          = parsed["drivers"]
      @constructors     = parsed["constructors"]
      @sectors          = parsed["sectors"]
      @pairs            = parsed["pairs"]
      @race_id          = parsed["raceId"]
      @lap              = parsed["lap"]
      @utc              = parsed["utc"]
      @after_race_id    = parsed["afterRaceId"]
      @regulations_era  = parsed["regulationsEra"]
      @replay           = parsed["_replay"]
    end

    # Reads any top-level field from the raw payload — handy for the flat weather
    # feeds whose fields are not surfaced as named accessors.
    def [](key)
      @raw[key]
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
      raise SignatureVerificationError unless verify_signature(secret, raw_body, signature)
      parse_payload(raw_body)
    end

    # Parses an incoming webhook body without verifying the signature.
    #
    # Prefer +construct_event+ when you have a signing secret.
    #
    # @param raw_body [String] The raw JSON body.
    # @return [WebhookPayload]
    def self.parse_payload(raw_body)
      WebhookPayload.new(JSON.parse(raw_body))
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
