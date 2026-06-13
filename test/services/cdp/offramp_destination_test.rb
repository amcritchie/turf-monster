require "test_helper"

# On-chain resolution of the offramp `to_address` ambiguity (§10 / open
# question 3) — the gate in front of EVERY offramp USDC send. Stubbed RPC via
# a canned get_account_info map (house pattern: stub at the service seam).
class Cdp::OfframpDestinationTest < ActiveSupport::TestCase
  TOKEN_PROGRAM = Cdp::OfframpDestination::TOKEN_PROGRAM_ID_B58
  SYSTEM_PROGRAM = "11111111111111111111111111111111".freeze

  class FakeRpc
    attr_reader :calls

    def initialize(infos = {})
      @infos = infos
      @calls = []
    end

    def get_account_info(address, **_opts)
      @calls << address
      { "value" => @infos[address] }
    end
  end

  def fresh_address
    Solana::Keypair.generate.address
  end

  # SPL token-account data: bytes 0..31 = mint.
  def token_account_info(mint: Solana::Config::USDC_MINT)
    mint_bytes = Solana::Keypair.decode_base58(mint)
    data = mint_bytes + ("\x00" * 133).b
    { "owner" => TOKEN_PROGRAM, "data" => [Base64.strict_encode64(data), "base64"] }
  end

  def derived_usdc_ata(owner)
    ata_bytes, _ = Solana::SplToken.find_associated_token_address(owner, Solana::Config::USDC_MINT)
    Solana::Keypair.encode_base58(ata_bytes)
  end

  test "a token-program-owned account with the USDC mint is used directly" do
    address = fresh_address
    rpc = FakeRpc.new(address => token_account_info)

    result = Cdp::OfframpDestination.resolve(address, client: rpc)

    assert_equal address, result.token_account
    assert_equal :token_account, result.kind
  end

  test "a token account for the WRONG mint fails closed" do
    address = fresh_address
    wrong_mint = Solana::Keypair.generate.address
    rpc = FakeRpc.new(address => token_account_info(mint: wrong_mint))

    error = assert_raises(Cdp::OfframpDestination::ResolutionError) do
      Cdp::OfframpDestination.resolve(address, client: rpc)
    end
    assert_match(/not USDC/, error.message)
  end

  test "a system-owned wallet address resolves to its existing USDC ATA" do
    owner = fresh_address
    ata = derived_usdc_ata(owner)
    rpc = FakeRpc.new(
      owner => { "owner" => SYSTEM_PROGRAM, "data" => ["", "base64"] },
      ata => token_account_info
    )

    result = Cdp::OfframpDestination.resolve(owner, client: rpc)

    assert_equal ata, result.token_account
    assert_equal :owner_ata, result.kind
    assert_includes rpc.calls, ata, "must verify the derived ATA exists on-chain"
  end

  test "an account absent on-chain still resolves through its existing USDC ATA" do
    owner = fresh_address
    ata = derived_usdc_ata(owner)
    rpc = FakeRpc.new(ata => token_account_info)

    result = Cdp::OfframpDestination.resolve(owner, client: rpc)
    assert_equal ata, result.token_account
    assert_equal :owner_ata, result.kind
  end

  test "raises when neither the address nor its derived ATA resolves" do
    owner = fresh_address
    rpc = FakeRpc.new # nothing exists

    error = assert_raises(Cdp::OfframpDestination::ResolutionError) do
      Cdp::OfframpDestination.resolve(owner, client: rpc)
    end
    assert_match(/refusing to send/, error.message)
  end

  test "raises on a derived ATA owned by the wrong program" do
    owner = fresh_address
    ata = derived_usdc_ata(owner)
    rpc = FakeRpc.new(
      owner => { "owner" => SYSTEM_PROGRAM },
      ata => { "owner" => SYSTEM_PROGRAM }
    )

    assert_raises(Cdp::OfframpDestination::ResolutionError) do
      Cdp::OfframpDestination.resolve(owner, client: rpc)
    end
  end

  test "raises on blank and malformed addresses without touching the RPC" do
    rpc = FakeRpc.new

    assert_raises(Cdp::OfframpDestination::ResolutionError) do
      Cdp::OfframpDestination.resolve(nil, client: rpc)
    end
    assert_raises(Cdp::OfframpDestination::ResolutionError) do
      Cdp::OfframpDestination.resolve("not-base58-0OIl", client: rpc)
    end
    assert_raises(Cdp::OfframpDestination::ResolutionError) do
      Cdp::OfframpDestination.resolve("abc", client: rpc) # valid base58, wrong length
    end
    assert_empty rpc.calls
  end
end
