require "test_helper"

class Cdp::AuthTest < ActiveSupport::TestCase
  KEY_ID = "11111111-2222-3333-4444-555555555555".freeze

  setup do
    @original_key_id  = ENV["CDP_API_KEY_ID"]
    @original_secret  = ENV["CDP_API_KEY_SECRET"]
    @signing_key = Ed25519::SigningKey.new(SecureRandom.bytes(32))
    ENV["CDP_API_KEY_ID"] = KEY_ID
    # 64 bytes: 32-byte seed ‖ 32-byte pubkey, as exported by the CDP portal.
    ENV["CDP_API_KEY_SECRET"] = Base64.strict_encode64(
      @signing_key.to_bytes + @signing_key.verify_key.to_bytes
    )
  end

  teardown do
    restore_env("CDP_API_KEY_ID", @original_key_id)
    restore_env("CDP_API_KEY_SECRET", @original_secret)
  end

  test "jwt round-trips: EdDSA-signed, verifiable with the keypair's public key" do
    token = Cdp::Auth.jwt_for(method: :post, path: "/onramp/v1/token")

    payload, header = JWT.decode(token, @signing_key.verify_key, true, algorithm: "EdDSA")

    assert_equal "EdDSA", header["alg"]
    assert_equal "JWT",   header["typ"]
    assert_equal KEY_ID,  header["kid"]
    assert_match(/\A\h{32}\z/, header["nonce"], "nonce must be 16 random bytes hex-encoded")

    assert_equal KEY_ID,          payload["sub"]
    assert_equal "cdp",           payload["iss"]
    assert_equal ["cdp_service"], payload["aud"]
    # uri claim = METHOD<space>host<path> — no scheme, no space between host and path.
    assert_equal "POST api.developer.coinbase.com/onramp/v1/token", payload["uri"]
    assert_equal 120, payload["exp"] - payload["nbf"], "2-minute max validity"
  end

  test "uri claim upcases the method and binds GET paths" do
    token = Cdp::Auth.jwt_for(method: :get, path: "/onramp/v1/buy/config")
    payload, _header = JWT.decode(token, @signing_key.verify_key, true, algorithm: "EdDSA")
    assert_equal "GET api.developer.coinbase.com/onramp/v1/buy/config", payload["uri"]
  end

  test "fresh nonce per call — tokens are never identical" do
    a = Cdp::Auth.jwt_for(method: :post, path: "/onramp/v1/token")
    b = Cdp::Auth.jwt_for(method: :post, path: "/onramp/v1/token")
    assert_not_equal a, b

    nonce = ->(t) { JWT.decode(t, @signing_key.verify_key, true, algorithm: "EdDSA").last["nonce"] }
    assert_not_equal nonce.call(a), nonce.call(b)
  end

  test "raises ConfigError when the secret does not decode to exactly 64 bytes" do
    ENV["CDP_API_KEY_SECRET"] = Base64.strict_encode64(SecureRandom.bytes(32))

    error = assert_raises(Cdp::Auth::ConfigError) do
      Cdp::Auth.jwt_for(method: :post, path: "/onramp/v1/token")
    end
    assert_match(/Invalid Ed25519 key length/, error.message)
    assert_match(/got 32/, error.message)
  end

  test "raises KeyError when env vars are missing entirely" do
    ENV.delete("CDP_API_KEY_SECRET")
    assert_raises(KeyError) { Cdp::Auth.jwt_for(method: :post, path: "/onramp/v1/token") }
  end

  private

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end
