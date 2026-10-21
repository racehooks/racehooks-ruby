require "net/http"
require "uri"
require "json"
require "openssl"
require "time"

module Racehooks
  # Client is the main entry point for the RaceHooks REST API.
  #
  # @example
  #   client = Racehooks::Client.new("your_client_id", "your_client_secret")
  #
  #   # List available feeds
  #   feeds = client.get_feeds
  #   feeds[:feeds].each { |f| puts f["feedId"] }
  #
  #   # List events
  #   events = client.get_events(upcoming: true)
  #   events[:events].each { |e| puts e[:name] }
  #
  #   # Create a webhook
  #   result = client.create_webhook(
  #     feed_id:        "timing.data",
  #     webhook_url:    "https://example.com/hook",
  #     webhook_method: "post"
  #   )
  #   puts result[:webhook_secret]  # store immediately — shown once
  class Client
    DEFAULT_BASE_URL = "https://api.racehooks.io/v1"
    DEFAULT_TIMEOUT  = 30 # seconds

    # @param client_id     [String] Your RaceHooks client ID.
    # @param client_secret [String] Your RaceHooks client secret.
    # @param base_url      [String] API base URL override (useful for testing).
    # @param timeout       [Integer] HTTP timeout in seconds.
    def initialize(client_id, client_secret, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT)
      raise ArgumentError, "client_id is required"     if client_id.nil? || client_id.empty?
      raise ArgumentError, "client_secret is required" if client_secret.nil? || client_secret.empty?

      @client_id     = client_id
      @client_secret = client_secret
      @base_url      = base_url.chomp("/")
      @timeout       = timeout
      @access_token  = nil
      @token_expiry  = nil
      @mutex         = Mutex.new
    end

    # ---------------------------------------------------------------------------
    # Authentication
    # ---------------------------------------------------------------------------

    # Exchange client credentials for a Bearer token.
    # Called automatically before any API request when the token is absent or expired.
    #
    # @return [Hash] +{ access_token:, token_type:, expires_in: }+
    # @raise  [AuthenticationError] on invalid credentials.
    def authenticate
      body = JSON.generate(
        client_id:     @client_id,
        client_secret: @client_secret,
        grant_type:    "client_credentials"
      )
      resp = raw_post("/oauth", body, auth: false)
      @mutex.synchronize do
        @access_token = resp[:access_token]
        @token_expiry = Time.now + (resp[:expires_in].to_i - 60)
      end
      resp
    end

    # ---------------------------------------------------------------------------
    # Feeds
    # ---------------------------------------------------------------------------

    # List available F1 timing feeds (GET /v1/feeds).
    #
    # @param limit  [Integer] Page size (1–100, default 50).
    # @param offset [Integer] Pagination offset.
    # @return [Hash] +{ feeds: [...], total:, limit:, offset: }+
    def get_feeds(limit: 50, offset: 0)
      query = build_query(limit: limit, offset: offset)
      get("/feeds#{query}")[:data]
    end

    # ---------------------------------------------------------------------------
    # Events
    # ---------------------------------------------------------------------------

    # List calendar events and their sessions (GET /v1/events).
    #
    # Each Event carries: +eventId+, +name+, +officialName+, +countryCode+,
    # +countryName+, +location+, +circuitName+, +state+, +type+, +roundText+, and
    # a nested +sessions+ array of EventSession records (+sessionId+, +type+,
    # +name+, +status+, +startDate+, +endDate+, +gmtOffset+, +path+).
    #
    # @param limit    [Integer, nil] Page size.
    # @param offset   [Integer, nil] Pagination offset.
    # @param upcoming [Boolean] When true, only future events are returned.
    # @param year     [String, Integer, nil] Restrict to a single season.
    # @return [Hash] +{ events: [...], total: }+
    def get_events(limit: nil, offset: nil, upcoming: false, year: nil)
      query = build_query(
        limit:    limit,
        offset:   offset,
        upcoming: (upcoming ? 1 : nil),
        year:     year
      )
      get("/events#{query}")[:data]
    end

    # ---------------------------------------------------------------------------
    # Live
    # ---------------------------------------------------------------------------

    # Fetch the current live-session context snapshot (GET /v1/live/context).
    #
    # Returns +{ active:, sessionName:, sessionType:, currentLap:, totalLaps:,
    # flag:, drivers: [...], rcMessages: [...], updatedAt: }+. When no session is
    # live, +active+ is +false+.
    #
    # @return [Hash] The LiveContext snapshot.
    def get_live_context
      get("/live/context")[:data]
    end

    # ---------------------------------------------------------------------------
    # Fantasy
    #
    # Pit stop leaderboards and estimated F1 Fantasy points per driver. All three
    # endpoints require a paid plan (Developer or higher).
    # ---------------------------------------------------------------------------

    # Estimated fantasy points per driver for a completed session
    # (GET /v1/fantasy/races/:race_id/scores).
    #
    # Defaults to the Grand Prix; pass +session: "sprint"+ to score the Sprint
    # (compressed points table). The response +sessionType+ echoes which session
    # was scored.
    #
    # @param race_id [String] Race ID slug, e.g. "2026-bahrain-r1".
    # @param session [String, nil] "grand_prix" (default) or "sprint".
    # @return [Hash] +{ raceId:, sessionType:, scores: [...], dataQuality: }+
    def get_race_scores(race_id, session: nil)
      # The API querystring accepts session=sprint (default = Grand Prix); only
      # the Sprint needs an explicit param.
      query = session.to_s == "sprint" ? "?session=sprint" : ""
      get("/fantasy/races/#{race_id}/scores#{query}")[:data]
    end

    # Running (provisional) fantasy score for each driver while a session is live
    # (GET /v1/fantasy/session/:session_id/scores).
    #
    # Position, teammate and DNF components update live; grid-derived and
    # fastest-lap components stay nil until the session ends (use
    # +get_race_scores+ for the final breakdown). +live+ is false and +scores+ is
    # empty when no session is currently live for this id.
    #
    # @param session_id [String] Session ID, e.g. "2026-bahrain-r1_Race".
    # @return [Hash] +{ sessionId:, live:, provisional:, sessionType:,
    #   currentLap:, totalLaps:, scores: [...] }+
    def get_session_scores(session_id)
      get("/fantasy/session/#{session_id}/scores")[:data]
    end

    # Pit stop time rankings for a session
    # (GET /v1/fantasy/session/:session_id/pit-times).
    #
    # Each entry in +stops+ (and +fastestStop+) carries +driver+, +tla+, +team+,
    # +pitStopTimeSec+ (the stationary pit-stop time in seconds), and +lap+.
    #
    # @param session_id [String] Session ID, e.g. "2026-bahrain-r1_Race".
    # @return [Hash] +{ sessionId:, source:, fastestStop:, stops: [...] }+
    def get_session_pit_times(session_id)
      get("/fantasy/session/#{session_id}/pit-times")[:data]
    end

    # ---------------------------------------------------------------------------
    # Session replay (simulate)
    #
    # Prepare a completed session's recorded-playback artifact, then stream it
    # from the simulate-stream service as if it were live. Any authenticated tier
    # can list and prepare real sessions; tier controls the artifact profile
    # ("lite" vs "full") and the replay quota.
    # ---------------------------------------------------------------------------

    # List completed sessions available for replay (GET /v1/simulate/sessions).
    #
    # Self-serve tiers see the current season plus the curated demo session;
    # +restrictedToSeason+ reports the applied clamp (nil when unrestricted).
    # Each session carries +sessionId+ (e.g. "2026-great-britain_r"), +sessionName+,
    # +eventId+, +eventName+, +circuitId+, +year+, +type+, +startDate+ and
    # +analyticsPreview+ (full Analytics feeds on any plan, no replay slot used).
    #
    # @param year   [Integer, String, nil] Calendar year, e.g. 2026.
    # @param type   [String, nil] "race", "qualifying", "sprint" or "practice".
    # @param limit  [Integer, nil] Page size (1-500, default 200).
    # @param offset [Integer, nil] Pagination offset.
    # @return [Hash] +{ sessions: [...], total:, limit:, offset:, restrictedToSeason: }+
    def get_replayable_sessions(year: nil, type: nil, limit: nil, offset: nil)
      query = build_query(year: year, type: type, limit: limit, offset: offset)
      get("/simulate/sessions#{query}")[:data]
    end

    # The curated demo session, resolved server-side (GET /v1/simulate/demo).
    #
    # @return [Hash] +{ sessionId:, sessionName:, status: }+ where +status+ is
    #   "ready" or "missing".
    def get_demo_session
      get("/simulate/demo")[:data]
    end

    # Distinct-session replay-delivery quota for your tier (GET /v1/simulate/quota).
    # Watching is unlimited; +-1+ means unlimited.
    #
    # @return [Hash] +{ limit:, used:, remaining:, unlocked: [...], currentSeasonOnly: }+
    def get_replay_quota
      get("/simulate/quota")[:data]
    end

    # Ensure a session's playback artifact exists, triggering (deduplicated)
    # generation if it is cold (POST /v1/simulate/prepare).
    #
    # @param session_id [String] Archive session id, e.g. "2026-great-britain_r".
    # @return [Hash] +{ sessionId:, sessionName:, modelVersion:, profile:, status:,
    #   formatFallback: }+. +status+ is "ready", "preparing" (poll
    #   +get_replay_status+), "missing" or "unknown".
    def prepare_replay(session_id)
      post("/simulate/prepare", { sessionId: session_id })[:data]
    end

    # Whether a session's playback artifact is ready to stream
    # (GET /v1/simulate/status). Same shape as +prepare_replay+.
    #
    # @param session_id [String] Archive session id, e.g. "2026-great-britain_r".
    # @return [Hash] The SimulateArtifact state.
    def get_replay_status(session_id)
      get("/simulate/status?session=#{URI.encode_www_form_component(session_id)}")[:data]
    end

    # ---------------------------------------------------------------------------
    # Webhooks
    # ---------------------------------------------------------------------------

    # Create a webhook subscription (POST /v1/webhooks).
    #
    # @param feed_id        [String]  Feed ID from +get_feeds+.
    # @param webhook_url    [String]  Public HTTPS URL to receive payloads.
    # @param webhook_method [String]  "post" or "put".
    # @param filters        [Hash, nil] Optional delivery filters.
    #   - +:drivers+        Array of driver TLA codes, e.g. +["VER","NOR"]+
    #   - +:driver_numbers+ Array of racing numbers, e.g. +["1","4"]+
    #   - +:constructors+   Array of team keywords, e.g. +["ferrari"]+
    #   - +:positions+      Hash +{ min: 1, max: 5 }+ for position range filter
    #   - +:event_types+    Array of event types (events.race / events.qualifying feeds only)
    # @return [Hash] +{ webhook: {...}, webhook_secret: "...", tier: "..." }+
    def create_webhook(feed_id:, webhook_url:, webhook_method: "post", filters: nil)
      body = { feedId: feed_id, webhookUrl: webhook_url, webhookMethod: webhook_method }
      body[:filters] = snake_to_camel_filters(filters) if filters
      post("/webhooks", body)[:data]
    end

    # List all webhook subscriptions (GET /v1/webhooks).
    #
    # @return [Hash] +{ webhooks: [...], total:, limit:, offset: }+
    def list_webhooks(limit: 20, offset: 0)
      query = build_query(limit: limit, offset: offset)
      get("/webhooks#{query}")[:data]
    end

    # Get a single webhook by ID (GET /v1/webhooks/:id).
    #
    # @param webhook_id [String]
    # @return [Hash] Webhook record.
    def get_webhook(webhook_id)
      get("/webhooks/#{webhook_id}")[:data][:webhook]
    end

    # Update a webhook subscription (PATCH /v1/webhooks/:id).
    #
    # All keyword arguments are optional; only provided values are sent.
    #
    # @param webhook_id     [String]
    # @param webhook_url    [String, nil]
    # @param webhook_method [String, nil]  "post" or "put"
    # @param filters        [Hash, nil]
    # @param active         [Boolean, nil]
    # @return [Hash] Updated webhook record.
    def update_webhook(webhook_id, webhook_url: nil, webhook_method: nil, filters: nil, active: nil)
      body = {}
      body[:webhookUrl]    = webhook_url    unless webhook_url.nil?
      body[:webhookMethod] = webhook_method unless webhook_method.nil?
      body[:filters]       = snake_to_camel_filters(filters) unless filters.nil?
      body[:active]        = active         unless active.nil?
      patch("/webhooks/#{webhook_id}", body)[:data][:webhook]
    end

    # Delete a webhook subscription (DELETE /v1/webhooks/:id).
    #
    # @param webhook_id [String]
    # @return [Boolean] true on success.
    def delete_webhook(webhook_id)
      delete("/webhooks/#{webhook_id}")
      true
    end

    # Retrieve the HMAC signing secret for a webhook (GET /v1/webhooks/:id/secret).
    # Available on all paid plans (Live, Analytics, Enterprise).
    #
    # @param webhook_id [String]
    # @return [String] The signing secret.
    def get_webhook_secret(webhook_id)
      get("/webhooks/#{webhook_id}/secret")[:data][:webhookSecret]
    end

    # Rotate the HMAC signing secret (POST /v1/webhooks/:id/rotate-secret).
    #
    # @param webhook_id [String]
    # @return [String] The new signing secret.
    def rotate_webhook_secret(webhook_id)
      post("/webhooks/#{webhook_id}/rotate-secret", nil)[:data][:webhookSecret]
    end

    # Retrieve delivery logs for a webhook (GET /v1/webhooks/:id/logs).
    #
    # @return [Hash] +{ logs: [...], total:, limit:, offset: }+
    def get_webhook_logs(webhook_id, limit: 50, offset: 0)
      query = build_query(limit: limit, offset: offset)
      get("/webhooks/#{webhook_id}/logs#{query}")[:data]
    end

    # Send a test payload to the webhook URL (POST /v1/webhooks/:id/test).
    #
    # @return [Hash] +{ delivered: true/false, status_code:, error_message: }+
    def test_webhook(webhook_id)
      post("/webhooks/#{webhook_id}/test", nil)[:data]
    end

    private

    # ---------------------------------------------------------------------------
    # HTTP internals
    # ---------------------------------------------------------------------------

    def ensure_token
      # Hold the mutex for the full check-then-act to prevent concurrent threads
      # from both seeing an expired/missing token and both calling authenticate.
      need_auth = false
      @mutex.synchronize do
        need_auth = !(@access_token && @token_expiry && Time.now < @token_expiry)
      end
      authenticate if need_auth
    end

    def get(path)
      ensure_token
      request(:get, path)
    end

    def post(path, body)
      ensure_token
      request(:post, path, body)
    end

    def patch(path, body)
      ensure_token
      request(:patch, path, body)
    end

    def delete(path)
      ensure_token
      request(:delete, path)
    end

    def raw_post(path, raw_body, auth: true)
      uri = URI.parse("#{@base_url}#{path}")
      http = build_http(uri)
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{@access_token}" if auth && @access_token
      req.body = raw_body

      resp = http.request(req)
      handle_response(resp)
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
      raise NetworkError, "#{e.class}: #{e.message}"
    end

    def request(method, path, body = nil)
      uri = URI.parse("#{@base_url}#{path}")
      http = build_http(uri)

      klass = {
        get:    Net::HTTP::Get,
        post:   Net::HTTP::Post,
        patch:  Net::HTTP::Patch,
        delete: Net::HTTP::Delete,
      }.fetch(method)

      req = klass.new(uri)
      req["Authorization"] = "Bearer #{@access_token}"
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end

      resp = http.request(req)
      handle_response(resp)
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
      raise NetworkError, "#{e.class}: #{e.message}"
    rescue NetworkError, APIError, AuthenticationError
      raise
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = @timeout
      http.open_timeout = @timeout
      http
    end

    def handle_response(resp)
      code = resp.code.to_i
      body = resp.body.to_s.strip

      if code == 401 || code == 403
        raise AuthenticationError.new(code, body)
      end

      unless (200..299).cover?(code)
        raise APIError.new(code, body)
      end

      return {} if body.empty?

      JSON.parse(body, symbolize_names: true)
    end

    def build_query(params)
      pairs = params.reject { |_, v| v.nil? }.map { |k, v| "#{k}=#{v}" }
      pairs.empty? ? "" : "?#{pairs.join('&')}"
    end

    # Convert Ruby snake_case filter keys to camelCase for the API.
    def snake_to_camel_filters(filters)
      return filters unless filters.is_a?(Hash)
      result = {}
      filters.each do |k, v|
        camel = k.to_s.gsub(/_([a-z])/) { $1.upcase }
        result[camel] = v
      end
      result
    end
  end
end
