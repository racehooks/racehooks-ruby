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
  #   # Create a webhook
  #   result = client.create_webhook(
  #     feed_id:        "timingdata",
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
    #   - +:event_types+    Array of raceevent types (raceevent feed only)
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
    # Requires Starter plan or above.
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
