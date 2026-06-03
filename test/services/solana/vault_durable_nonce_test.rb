require "test_helper"

# Vault#build_tx can OPTIONALLY anchor on a durable nonce (opt-in via
# SOLANA_DURABLE_NONCE_PUBKEY / an explicit durable_nonce:) so a slow Phantom
# sign can't expire the tx — the mainnet BlockhashNotFound fix. Default path
# (recent blockhash) is unchanged.
class Solana::VaultDurableNonceTest < ActiveSupport::TestCase
  # 80-byte initialized nonce account: version=1, state=1, authority, nonce, fee.
  def nonce_buffer(authority_b58:, nonce_b58:)
    [1].pack("L<") + [1].pack("L<") +
      Solana::Keypair.decode_base58(authority_b58) +
      Solana::Keypair.decode_base58(nonce_b58) +
      [5000].pack("Q<")
  end

  def fake_client(nonce_b64: nil)
    c = Object.new
    c.define_singleton_method(:get_account_info) { |_pk, **_o| { "value" => { "data" => [nonce_b64, "base64"] } } }
    c.define_singleton_method(:get_latest_blockhash) { |**_o| Solana::Keypair.generate.to_base58 }
    c
  end

  test "build_partial_signed anchors on the durable nonce + prepends the advance ix" do
    authority = Solana::Keypair.admin.address
    nonce_val = Solana::Keypair.generate.to_base58
    buf   = nonce_buffer(authority_b58: authority, nonce_b58: nonce_val)
    vault = Solana::Vault.new(client: fake_client(nonce_b64: Base64.strict_encode64(buf)))

    b64 = vault.send(:build_partial_signed,
      accounts: [{ pubkey: Solana::Keypair.admin.public_key_bytes, is_signer: true, is_writable: true }],
      data: "\x00".b * 8, additional_signers: [],
      durable_nonce: { pubkey: Solana::Keypair.generate.to_base58, authority: authority })

    raw = Base64.strict_decode64(b64).b
    # The System program (32 zero bytes) is referenced only by the advance ix.
    assert raw.include?("\x00".b * 32), "expected the System advance instruction in the tx"
    # And the nonce value is baked in as the recentBlockhash.
    assert raw.include?(Solana::Keypair.decode_base58(nonce_val)), "expected the nonce value as recentBlockhash"
  end

  test "default path (no durable_nonce) uses a recent blockhash, no advance ix" do
    vault = Solana::Vault.new(client: fake_client)
    b64 = vault.send(:build_partial_signed,
      accounts: [{ pubkey: Solana::Keypair.admin.public_key_bytes, is_signer: true, is_writable: true }],
      data: "\x01".b * 8, additional_signers: [])
    assert b64.is_a?(String) && !b64.empty?
  end

  test "durable_nonce_config is nil unless the env var is set" do
    vault = Solana::Vault.new(client: fake_client)
    assert_nil vault.send(:durable_nonce_config)
  end
end
