# racehooks

Official Ruby gem for RaceHooks — F1 live timing webhook signature verification

[![Gem Version](https://badge.fury.io/rb/racehooks.svg)](https://badge.fury.io/rb/racehooks)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%202.6-red.svg)](https://www.ruby-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> RaceHooks is an independent service and is not affiliated with or endorsed by Formula One Management or the FIA. "Formula 1," "F1," and related marks are trademarks of Formula One Licensing BV.

RaceHooks pushes Formula 1 live timing events to your webhook endpoint. Each delivery is signed with HMAC-SHA256 so you can confirm it really came from RaceHooks and was not tampered with in transit. This gem verifies those signatures and parses deliveries into structured Ruby objects.

## Install

```bash
gem install racehooks
```

Ruby 2.6+. No runtime dependencies — uses only the Ruby standard library (`net/http`, `json`, `openssl`).

Add to your `Gemfile`:

```ruby
gem "racehooks"
```

## Quick start

```ruby
require "racehooks"

# Your webhook secret is shown when you create a webhook (POST /v1/webhooks).
# Store it securely — it is only returned once at creation time.
secret = ENV["RACEHOOKS_WEBHOOK_SECRET"]
```

## Verifying webhooks

Always verify against the **raw request body** before parsing — re-serializing a parsed body can change whitespace or key order and break the signature.

### Rails

```ruby
class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    raw_body = request.raw_post
    event = Racehooks::Webhook.construct_event(
      raw_body,
      request.headers["X-RaceHooks-Signature"],
      ENV["RACEHOOKS_WEBHOOK_SECRET"]
    )

    case event.feed
    when "timingdata"
      # event.data contains the full timing payload hash
      Rails.logger.info "Timing update for session #{event.session_id}"
    when "weatherdata"
      Rails.logger.info "Air temp: #{event.data['AirTemp']}"
    when "raceevent"
      Rails.logger.info "Race event: #{event.data['Message']}"
    end

    head :ok
  rescue Racehooks::SignatureVerificationError
    head :unauthorized
  rescue JSON::ParserError
    head :bad_request
  end
end
```

### Sinatra / plain Ruby

```ruby
require "sinatra"
require "racehooks"

post "/webhook" do
  raw_body = request.body.read
  begin
    event = Racehooks::Webhook.construct_event(
      raw_body,
      request.env["HTTP_X_RACEHOOKS_SIGNATURE"],
      ENV["RACEHOOKS_WEBHOOK_SECRET"]
    )
  rescue Racehooks::SignatureVerificationError
    halt 401, "Invalid signature"
  rescue JSON::ParserError
    halt 400, "Invalid JSON"
  end

  if event.analytics?
    puts "Overtake probability: #{event.analytics['overtakeProb']}"
  end

  if event.replay?
    puts "Replaying from #{event.replay['sourcePath']}"
  end

  status 200
  json received: true
end
```

### Manual verification

If you need to verify without parsing, use `verify_signature` directly:

```ruby
valid = Racehooks::Webhook.verify_signature(secret, raw_body, signature_header)
# returns true/false — never raises
```

Or parse without verification (useful in tests):

```ruby
event = Racehooks::Webhook.parse_payload(raw_body)
puts event.feed       # => "timingdata"
puts event.session_id # => "session_monaco_r"
puts event.data       # => Hash
```

## WebhookPayload fields

`construct_event` and `parse_payload` both return a `Racehooks::WebhookPayload` with these attributes:

| Attribute | Type | Description |
|---|---|---|
| `feed` | `String` | Feed identifier — e.g. `"timingdata"`, `"cardata"`, `"weatherdata"`, `"raceevent"` |
| `session_id` | `String, nil` | Active session ID, or `nil` between sessions |
| `data` | `Hash, Array` | Feed payload (already parsed from JSON) |
| `analytics` | `Hash, nil` | Analytics enrichment (Analytics tier subscribers only) |
| `replay` | `Hash, nil` | Replay metadata — present only for replayed deliveries |

Helper predicates:

```ruby
event.analytics?  # true when analytics enrichment is present
event.replay?     # true when this is a replayed delivery
```

## Replay protection

Signature verification confirms the payload was signed by RaceHooks. For additional protection against replay attacks, check the `X-RaceHooks-Sent-At` header (epoch milliseconds) and reject deliveries outside your acceptable window:

```ruby
sent_at = request.headers["X-RaceHooks-Sent-At"].to_i / 1000.0
if (Time.now.to_f - sent_at).abs > 300
  head :unauthorized and return
end
```

## How verification works

```
X-RaceHooks-Signature: sha256=HMAC_SHA256(webhook_secret, raw_body)
```

The gem computes `HMAC-SHA256(secret, raw_body)` and compares using a constant-time byte comparison to prevent timing attacks. The signature always starts with `sha256=` followed by 64 lowercase hex characters.

## REST client

`Racehooks::Client` handles OAuth token management automatically and exposes the full RaceHooks API.

```ruby
require "racehooks"

client = Racehooks::Client.new(
  ENV["RACEHOOKS_CLIENT_ID"],
  ENV["RACEHOOKS_CLIENT_SECRET"]
)
```

The client authenticates lazily on the first request and re-authenticates automatically when the token expires. It is thread-safe.

### Feeds

```ruby
# List available F1 timing feeds
result = client.get_feeds
result[:feeds].each { |f| puts "#{f[:feedId]} — #{f[:name]}" }
```

### Webhooks

```ruby
# Create a subscription
result = client.create_webhook(
  feed_id:        "timingdata",
  webhook_url:    "https://example.com/hook",
  webhook_method: "post"
)
puts result[:webhookSecret]  # store this immediately — shown once

# List subscriptions
client.list_webhooks[:webhooks].each { |w| puts w[:webhookId] }

# Get a single webhook
wh = client.get_webhook("wh_abc123")

# Update a webhook
client.update_webhook("wh_abc123", active: false)

# Delete a webhook
client.delete_webhook("wh_abc123")

# Test delivery to the webhook URL
result = client.test_webhook("wh_abc123")
puts result[:delivered]   # true/false
puts result[:statusCode]  # HTTP status returned by your endpoint

# Retrieve delivery logs
logs = client.get_webhook_logs("wh_abc123")
logs[:logs].each { |l| puts "#{l[:logId]} — #{l[:statusCode]}" }
```

### Webhook secrets

```ruby
# Retrieve the current signing secret
secret = client.get_webhook_secret("wh_abc123")

# Rotate to a new secret (old secret stops working immediately)
new_secret = client.rotate_webhook_secret("wh_abc123")
```

### Optional filters (on `create_webhook` and `update_webhook`)

```ruby
client.create_webhook(
  feed_id:     "timingdata",
  webhook_url: "https://example.com/hook",
  filters: {
    drivers:        ["VER", "NOR"],       # TLA codes
    driver_numbers: ["1", "4"],           # racing numbers
    constructors:   ["ferrari"],          # team keyword
    positions:      { min: 1, max: 5 },  # position range
    event_types:    ["DRS_ENABLED"],      # raceevent feed only
  }
)
```

### Error handling

```ruby
begin
  client.create_webhook(feed_id: "invalid", webhook_url: "https://example.com/hook")
rescue Racehooks::AuthenticationError => e
  puts "Bad credentials: #{e.status_code}"
rescue Racehooks::APIError => e
  puts "API error #{e.status_code}: #{e.body}"
rescue Racehooks::NetworkError => e
  puts "Network failure: #{e.message}"
end
```

| Exception | When raised |
|---|---|
| `Racehooks::SignatureVerificationError` | Webhook signature does not match |
| `Racehooks::AuthenticationError` | Invalid `client_id` / `client_secret` (401/403) |
| `Racehooks::APIError` | Non-2xx response from the API |
| `Racehooks::NetworkError` | Timeout, connection refused, DNS failure |

## License

MIT
