require "minitest/autorun"
require_relative "../lib/racehooks"

class WebhookTest < Minitest::Test
  SECRET = "test_webhook_secret_abc123"
  SAMPLE_BODY = '{"feed":"timingdata","sessionId":"session_monaco_r","data":{"1":{"LastLapTime":{"Value":"1:12.345"}}}}'

  # ---------------------------------------------------------------------------
  # compute_signature
  # ---------------------------------------------------------------------------

  def test_compute_signature_format
    sig = Racehooks::Webhook.compute_signature(SECRET, SAMPLE_BODY)
    assert sig.start_with?("sha256="), "signature must start with sha256="
    assert_equal 71, sig.length, "sha256= (7) + 64 hex chars"
  end

  def test_compute_signature_deterministic
    sig1 = Racehooks::Webhook.compute_signature(SECRET, SAMPLE_BODY)
    sig2 = Racehooks::Webhook.compute_signature(SECRET, SAMPLE_BODY)
    assert_equal sig1, sig2
  end

  # ---------------------------------------------------------------------------
  # verify_signature
  # ---------------------------------------------------------------------------

  def test_verify_signature_valid
    sig = Racehooks::Webhook.compute_signature(SECRET, SAMPLE_BODY)
    assert Racehooks::Webhook.verify_signature(SECRET, SAMPLE_BODY, sig)
  end

  def test_verify_signature_invalid_sig
    refute Racehooks::Webhook.verify_signature(SECRET, SAMPLE_BODY, "sha256=badhex")
  end

  def test_verify_signature_wrong_secret
    sig = Racehooks::Webhook.compute_signature("other_secret", SAMPLE_BODY)
    refute Racehooks::Webhook.verify_signature(SECRET, SAMPLE_BODY, sig)
  end

  def test_verify_signature_tampered_body
    sig = Racehooks::Webhook.compute_signature(SECRET, SAMPLE_BODY)
    tampered = SAMPLE_BODY + "!"
    refute Racehooks::Webhook.verify_signature(SECRET, tampered, sig)
  end

  def test_verify_signature_empty_body
    sig = Racehooks::Webhook.compute_signature(SECRET, "")
    assert Racehooks::Webhook.verify_signature(SECRET, "", sig)
  end

  # ---------------------------------------------------------------------------
  # construct_event
  # ---------------------------------------------------------------------------

  def test_construct_event_valid_signature
    sig = Racehooks::Webhook.compute_signature(SECRET, SAMPLE_BODY)
    event = Racehooks::Webhook.construct_event(SAMPLE_BODY, sig, SECRET)

    assert_instance_of Racehooks::WebhookPayload, event
    assert_equal "timingdata", event.feed
    assert_equal "session_monaco_r", event.session_id
    assert_instance_of Hash, event.data
  end

  def test_construct_event_invalid_signature
    assert_raises(Racehooks::SignatureVerificationError) do
      Racehooks::Webhook.construct_event(SAMPLE_BODY, "sha256=bad", SECRET)
    end
  end

  def test_construct_event_nil_signature_raises_verification_error
    # nil signature (missing header) must raise SignatureVerificationError,
    # not crash with NoMethodError.
    assert_raises(Racehooks::SignatureVerificationError) do
      Racehooks::Webhook.construct_event(SAMPLE_BODY, nil, SECRET)
    end
  end

  def test_verify_signature_nil_signature_returns_false
    refute Racehooks::Webhook.verify_signature(SECRET, SAMPLE_BODY, nil),
           "nil signature must return false, not raise"
  end

  def test_verify_signature_empty_signature_returns_false
    refute Racehooks::Webhook.verify_signature(SECRET, SAMPLE_BODY, ""),
           "empty signature must return false"
  end

  def test_compute_signature_nil_secret_raises_argument_error
    assert_raises(ArgumentError) { Racehooks::Webhook.compute_signature(nil, SAMPLE_BODY) }
  end

  def test_compute_signature_nil_body_raises_argument_error
    assert_raises(ArgumentError) { Racehooks::Webhook.compute_signature(SECRET, nil) }
  end

  # ---------------------------------------------------------------------------
  # parse_payload
  # ---------------------------------------------------------------------------

  def test_parse_payload_no_signature
    event = Racehooks::Webhook.parse_payload(SAMPLE_BODY)
    assert_equal "timingdata", event.feed
  end

  def test_parse_payload_analytics_strategy_feed
    body = '{"feed":"analytics.strategy","sessionId":"s1","raceId":"2026-bahrain-r1","lap":22,"regulationsEra":"2026","drivers":[{"tla":"VER","pitStopProbability":0.82}]}'
    event = Racehooks::Webhook.parse_payload(body)
    assert_equal "analytics.strategy", event.feed
    assert_equal "2026-bahrain-r1", event.race_id
    assert_equal 22, event.lap
    assert_equal "2026", event.regulations_era
    assert_equal 0.82, event.drivers[0]["pitStopProbability"]
  end

  def test_parse_payload_analytics_constructor_feed
    body = '{"feed":"analytics.constructor","sessionId":"s1","raceId":"2026-bahrain-r1","lap":22,"constructors":[{"constructorId":"red_bull","expectedConstructorPoints":31.2}]}'
    event = Racehooks::Webhook.parse_payload(body)
    assert_equal "analytics.constructor", event.feed
    assert_equal 31.2, event.constructors[0]["expectedConstructorPoints"]
    assert_nil event.drivers
  end

  def test_parse_payload_analytics_race_odds_includes_pairs
    body = '{"feed":"analytics.race-odds","sessionId":"s1","raceId":"2026-bahrain-r1","lap":22,"drivers":[],"pairs":[{"constructorId":"red_bull","driverA":"1","driverB":"11","h2hAWinsProbability":0.61}]}'
    event = Racehooks::Webhook.parse_payload(body)
    assert_equal 0.61, event.pairs[0]["h2hAWinsProbability"]
  end

  def test_parse_payload_analytics_qualifying_feed
    body = '{"feed":"analytics.qualifying","sessionId":"s1","raceId":null,"lap":3,"sectors":{"poleMarginMs":142},"drivers":[]}'
    event = Racehooks::Webhook.parse_payload(body)
    assert_equal "analytics.qualifying", event.feed
    assert_equal 142, event.sectors["poleMarginMs"]
  end

  def test_parse_payload_with_replay
    body = '{"feed":"cardata","sessionId":"s1","data":{},"_replay":{"sourcePath":"2025/race/","originalUtc":"2025-05-25T14:00:00Z","speed":60,"isReplay":true}}'
    event = Racehooks::Webhook.parse_payload(body)
    assert event.replay?, "expected replay? to be true"
    assert_equal "2025/race/", event.replay["sourcePath"]
  end

  def test_parse_payload_null_session_id
    body = '{"feed":"trackstatus","sessionId":null,"data":{"Status":"1"}}'
    event = Racehooks::Webhook.parse_payload(body)
    assert_nil event.session_id
  end

  def test_parse_payload_data_accessible
    body = '{"feed":"weatherdata","sessionId":"s1","data":{"AirTemp":"23.5","Humidity":"55"}}'
    event = Racehooks::Webhook.parse_payload(body)
    assert_equal "23.5", event.data["AirTemp"]
    assert_equal "55", event.data["Humidity"]
  end

  def test_parse_payload_invalid_json
    assert_raises(JSON::ParserError) do
      Racehooks::Webhook.parse_payload("not json")
    end
  end
end
