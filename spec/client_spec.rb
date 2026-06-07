require "minitest/autorun"
require "webrick"
require "thread"
require_relative "../lib/racehooks"

# ---------------------------------------------------------------------------
# Minimal test HTTP server (avoids webmock / external deps)
# ---------------------------------------------------------------------------
class StubServer
  attr_reader :port

  def initialize
    @routes  = {}
    @server  = nil
    @port    = nil
    @thread  = nil
  end

  # Register a route: stub.on(:post, "/v1/oauth") { |req| [200, body_hash] }
  def on(method, path, &block)
    @routes["#{method.to_s.upcase} #{path}"] = block
    self
  end

  def start
    routes = @routes  # captured by closure

    # Build a servlet class that handles all HTTP methods via the routes hash
    servlet_class = Class.new(WEBrick::HTTPServlet::AbstractServlet) do
      define_method(:do_GET)    { |req, res| _dispatch(routes, req, res) }
      define_method(:do_POST)   { |req, res| _dispatch(routes, req, res) }
      define_method(:do_PATCH)  { |req, res| _dispatch(routes, req, res) }
      define_method(:do_DELETE) { |req, res| _dispatch(routes, req, res) }

      define_method(:_dispatch) do |r, req, res|
        key = "#{req.request_method} #{req.path}"
        handler = r[key]
        if handler
          status, body = handler.call(req)
          res.status = status
          res["Content-Type"] = "application/json"
          res.body = body.is_a?(String) ? body : body.to_json
        else
          res.status = 404
          res.body   = "Not Found"
        end
      end
    end

    @server = WEBrick::HTTPServer.new(
      Port:         0,
      Logger:       WEBrick::Log.new(File::NULL),
      AccessLog:    [],
    )
    @port = @server.config[:Port]
    @server.mount("/", servlet_class)

    @thread = Thread.new { @server.start }
    # Wait until the server is accepting connections
    deadline = Time.now + 3
    begin
      TCPSocket.new("127.0.0.1", @port).close
    rescue Errno::ECONNREFUSED
      retry if Time.now < deadline
      raise "Stub server did not start in time"
    end
    self
  end

  def stop
    @server&.shutdown
    @thread&.join
  end

  def base_url
    "http://127.0.0.1:#{@port}/v1"
  end
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def stub_auth(stub)
  stub.on(:post, "/v1/oauth") do
    [200, { access_token: "tok_test", token_type: "Bearer", expires_in: 43200 }]
  end
end

def make_client(stub)
  Racehooks::Client.new("test_id", "test_secret", base_url: stub.base_url)
end

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class ClientConstructorTest < Minitest::Test
  def test_requires_client_id
    assert_raises(ArgumentError) { Racehooks::Client.new("", "secret") }
  end

  def test_requires_client_secret
    assert_raises(ArgumentError) { Racehooks::Client.new("id", "") }
  end

  def test_successful_construction
    client = Racehooks::Client.new("id", "secret")
    refute_nil client
  end
end

class ClientAuthTest < Minitest::Test
  def setup
    @stub = StubServer.new.start
    stub_auth(@stub)
  end

  def teardown
    @stub.stop
  end

  def test_authenticate_success
    client = make_client(@stub)
    result = client.authenticate
    assert_equal "tok_test", result[:access_token]
    assert_equal "Bearer", result[:token_type]
  end

  def test_authenticate_invalid_credentials
    @stub.on(:post, "/v1/oauth") { [401, "Unauthorized"] }
    client = Racehooks::Client.new("bad", "creds", base_url: @stub.base_url)
    assert_raises(Racehooks::AuthenticationError) { client.authenticate }
  end
end

class ClientFeedsTest < Minitest::Test
  def setup
    @stub = StubServer.new.start
    stub_auth(@stub)
    @stub.on(:get, "/v1/feeds") do
      [200, {
        data: {
          feeds: [
            { feedId: "cardata", name: "Car Data", path: "CarData.z", availability: "pro" },
            { feedId: "timingdata", name: "Timing Data", path: "TimingData", availability: "free" },
          ],
          total: 2, limit: 50, offset: 0,
        }
      }]
    end
  end

  def teardown
    @stub.stop
  end

  def test_get_feeds_returns_list
    client = make_client(@stub)
    result = client.get_feeds
    assert_equal 2, result[:total]
    assert_equal 2, result[:feeds].length
  end

  def test_get_feeds_first_feed_id
    client = make_client(@stub)
    result = client.get_feeds
    assert_equal "cardata", result[:feeds].first[:feedId]
  end
end

class ClientWebhooksTest < Minitest::Test
  CREATED_AT = "2026-06-07T10:00:00Z"

  def setup
    @stub = StubServer.new.start
    stub_auth(@stub)
  end

  def teardown
    @stub.stop
  end

  def webhook_fixture(id: "wh_abc", feed_id: "timingdata", active: true, tier: "starter")
    {
      webhookId:        id,
      feedId:           feed_id,
      webhookUrl:       "https://example.com/hook",
      webhookMethod:    "post",
      active:           active,
      subscriptionTier: tier,
      createdAt:        CREATED_AT,
    }
  end

  # --- create ---

  def test_create_webhook_success
    @stub.on(:post, "/v1/webhooks") do
      [200, { data: { webhook: webhook_fixture, webhookSecret: "sec_abc", tier: "starter" } }]
    end
    client = make_client(@stub)
    result = client.create_webhook(feed_id: "timingdata", webhook_url: "https://example.com/hook")
    assert_equal "wh_abc", result[:webhook][:webhookId]
    assert_equal "sec_abc", result[:webhookSecret]
  end

  def test_create_webhook_feed_not_found
    @stub.on(:post, "/v1/webhooks") { [404, "Feed not found"] }
    client = make_client(@stub)
    err = assert_raises(Racehooks::APIError) do
      client.create_webhook(feed_id: "nonexistent", webhook_url: "https://example.com/hook")
    end
    assert_equal 404, err.status_code
  end

  # --- list ---

  def test_list_webhooks_success
    @stub.on(:get, "/v1/webhooks") do
      [200, { data: { webhooks: [webhook_fixture], total: 1, limit: 20, offset: 0 } }]
    end
    client = make_client(@stub)
    result = client.list_webhooks
    assert_equal 1, result[:total]
    assert_equal 1, result[:webhooks].length
  end

  # --- get ---

  def test_get_webhook_success
    @stub.on(:get, "/v1/webhooks/wh_abc") do
      [200, { data: { webhook: webhook_fixture } }]
    end
    client = make_client(@stub)
    wh = client.get_webhook("wh_abc")
    assert_equal "timingdata", wh[:feedId]
  end

  def test_get_webhook_not_found
    @stub.on(:get, "/v1/webhooks/wh_nope") { [404, "Webhook not found"] }
    client = make_client(@stub)
    assert_raises(Racehooks::APIError) { client.get_webhook("wh_nope") }
  end

  # --- delete ---

  def test_delete_webhook_success
    @stub.on(:delete, "/v1/webhooks/wh_del") do
      [200, { data: { success: true } }]
    end
    client = make_client(@stub)
    assert_equal true, client.delete_webhook("wh_del")
  end

  # --- secret ---

  def test_get_webhook_secret
    @stub.on(:get, "/v1/webhooks/wh_sec/secret") do
      [200, { data: { webhookId: "wh_sec", webhookSecret: "supersecret" } }]
    end
    client = make_client(@stub)
    secret = client.get_webhook_secret("wh_sec")
    assert_equal "supersecret", secret
  end

  def test_rotate_webhook_secret
    @stub.on(:post, "/v1/webhooks/wh_rot/rotate-secret") do
      [200, { data: { webhookId: "wh_rot", webhookSecret: "newrotated" } }]
    end
    client = make_client(@stub)
    secret = client.rotate_webhook_secret("wh_rot")
    assert_equal "newrotated", secret
  end

  # --- test ---

  def test_test_webhook_success
    @stub.on(:post, "/v1/webhooks/wh_tst/test") do
      [200, { data: { delivered: true, statusCode: 200, errorMessage: nil } }]
    end
    client = make_client(@stub)
    result = client.test_webhook("wh_tst")
    assert_equal true, result[:delivered]
    assert_equal 200, result[:statusCode]
  end

  def test_test_webhook_failure
    @stub.on(:post, "/v1/webhooks/wh_fail/test") do
      [200, { data: { delivered: false, statusCode: 503, errorMessage: "Connection refused" } }]
    end
    client = make_client(@stub)
    result = client.test_webhook("wh_fail")
    refute result[:delivered]
    assert_equal 503, result[:statusCode]
  end

  # --- logs ---

  def test_get_webhook_logs
    @stub.on(:get, "/v1/webhooks/wh_abc/logs") do
      [200, { data: {
        logs: [{ logId: "l1", webhookId: "wh_abc", statusCode: 200, retryCount: 0 }],
        total: 1, limit: 50, offset: 0,
      } }]
    end
    client = make_client(@stub)
    result = client.get_webhook_logs("wh_abc")
    assert_equal 1, result[:total]
    assert_equal "l1", result[:logs].first[:logId]
  end
end

class ClientErrorHandlingTest < Minitest::Test
  def setup
    @stub = StubServer.new.start
    stub_auth(@stub)
  end

  def teardown
    @stub.stop
  end

  def test_api_error_has_status_code
    @stub.on(:get, "/v1/feeds") { [402, "Upgrade required"] }
    client = make_client(@stub)
    err = assert_raises(Racehooks::APIError) { client.get_feeds }
    assert_equal 402, err.status_code
  end

  def test_network_error_raises_network_error
    # Point at a port that is not listening
    client = Racehooks::Client.new("id", "sec", base_url: "http://127.0.0.1:1/v1")
    # authenticate itself will raise NetworkError
    assert_raises(Racehooks::NetworkError) { client.authenticate }
  end
end
