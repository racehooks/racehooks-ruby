require "minitest/autorun"
require_relative "../lib/racehooks"

class WebhookTest < Minitest::Test
  SECRET = "test_webhook_secret_abc123"
  SAMPLE_BODY = '{"type":"timingdata","sessionId":"session_monaco_r","data":{"1":{"LastLapTime":{"Value":"1:12.345"}}},"analytics":null}'

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
    assert_equal "timingdata", event.type
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
    assert_equal "timingdata", event.type
  end

  def test_parse_payload_with_analytics
    body = '{"type":"timingdata","sessionId":"s1","data":{},"analytics":{"overtakeProb":0.82}}'
    event = Racehooks::Webhook.parse_payload(body)
    assert event.analytics?, "expected analytics? to be true"
    assert_equal 0.82, event.analytics["overtakeProb"]
  end

  def test_parse_payload_without_analytics
    body = '{"type":"weatherdata","sessionId":"s1","data":{"AirTemp":"23.5"}}'
    event = Racehooks::Webhook.parse_payload(body)
    refute event.analytics?, "expected analytics? to be false"
    assert_nil event.analytics
  end

  def test_parse_payload_with_replay
    body = '{"type":"cardata","sessionId":"s1","data":{},"_replay":{"sourcePath":"2025/race/","originalUtc":"2025-05-25T14:00:00Z","speed":60,"isReplay":true}}'
    event = Racehooks::Webhook.parse_payload(body)
    assert event.replay?, "expected replay? to be true"
    assert_equal "2025/race/", event.replay["sourcePath"]
  end

  def test_parse_payload_null_session_id
    body = '{"type":"trackstatus","sessionId":null,"data":{"Status":"1"}}'
    event = Racehooks::Webhook.parse_payload(body)
    assert_nil event.session_id
  end

  def test_parse_payload_data_accessible
    body = '{"type":"weatherdata","sessionId":"s1","data":{"AirTemp":"23.5","Humidity":"55"}}'
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
