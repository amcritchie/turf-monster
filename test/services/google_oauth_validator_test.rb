require "test_helper"

class GoogleOauthValidatorTest < ActiveSupport::TestCase
  # OPSEC-005: production paths set id_token from the real OAuth bounce.
  # Test env may not — see validator's :test_skip affordance.

  test "blank id_token in test env returns ok (mock_auth carries no id_token)" do
    result = GoogleOauthValidator.new(id_token: "", expected_aud: "client").validate!
    assert result.ok?
    assert_equal :test_skip, result.reason
  end

  test "blank expected_aud rejects" do
    # Force non-test path by passing a token. We need the validator to skip the
    # test_skip branch (which requires blank id_token). With a token + blank
    # aud → :missing_expected_aud.
    result = GoogleOauthValidator.new(id_token: "fake_token", expected_aud: "").validate!
    refute result.ok?
    assert_equal :missing_expected_aud, result.reason
  end

  test "tokeninfo unreachable returns ok=false with reason" do
    # Replace fetch_tokeninfo to simulate a network failure.
    validator = GoogleOauthValidator.new(id_token: "fake", expected_aud: "client")
    validator.define_singleton_method(:fetch_tokeninfo) { nil }
    result = validator.validate!
    refute result.ok?
    assert_equal :tokeninfo_unreachable, result.reason
  end

  test "wrong audience rejected" do
    validator = GoogleOauthValidator.new(id_token: "fake", expected_aud: "expected-client")
    fake_response = Struct.new(:code, :body).new("200", { "aud" => "other-client", "email" => "x@example.com", "email_verified" => "true" }.to_json)
    validator.define_singleton_method(:fetch_tokeninfo) { fake_response }
    result = validator.validate!
    refute result.ok?
    assert_equal :wrong_audience, result.reason
  end

  test "email_verified=false rejected" do
    validator = GoogleOauthValidator.new(id_token: "fake", expected_aud: "client")
    fake_response = Struct.new(:code, :body).new("200", { "aud" => "client", "email" => "x@example.com", "email_verified" => "false" }.to_json)
    validator.define_singleton_method(:fetch_tokeninfo) { fake_response }
    result = validator.validate!
    refute result.ok?
    assert_equal :email_not_verified, result.reason
  end

  test "expired token rejected" do
    validator = GoogleOauthValidator.new(id_token: "fake", expected_aud: "client")
    fake_response = Struct.new(:code, :body).new("200", { "aud" => "client", "email" => "x@example.com", "email_verified" => "true", "exp" => (Time.current.to_i - 60) }.to_json)
    validator.define_singleton_method(:fetch_tokeninfo) { fake_response }
    result = validator.validate!
    refute result.ok?
    assert_equal :expired, result.reason
  end

  test "happy path: matching aud + verified + unexpired" do
    validator = GoogleOauthValidator.new(id_token: "fake", expected_aud: "client")
    fake_response = Struct.new(:code, :body).new("200", { "aud" => "client", "email" => "x@example.com", "email_verified" => "true", "exp" => (Time.current.to_i + 3600) }.to_json)
    validator.define_singleton_method(:fetch_tokeninfo) { fake_response }
    result = validator.validate!
    assert result.ok?
    assert_equal "x@example.com", result.email
    assert result.email_verified
  end
end
