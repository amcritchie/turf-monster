require "test_helper"

class Solana::VaultEnsureProgramIdLiveTest < ActiveSupport::TestCase
  setup { Rails.cache.clear }

  test "raises StaleEnvError when getAccountInfo returns null value" do
    fake_client = Object.new
    def fake_client.get_account_info(_)
      { "value" => nil }
    end

    err = assert_raises(Solana::Vault::StaleEnvError) do
      Solana::Vault.ensure_program_id_live!(client: fake_client)
    end
    assert_match(/PROGRAM_ID=/, err.message)
    assert_match(/does not exist on RPC/, err.message)
  end

  test "returns silently and caches when the program exists" do
    # Test env defaults Rails.cache to :null_store; swap in a real memory
    # store so we can verify the cache actually short-circuits the 2nd call.
    real_cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new

    fake_client = Object.new
    fake_client.instance_variable_set(:@calls, 0)
    def fake_client.calls = @calls
    def fake_client.get_account_info(_)
      @calls += 1
      { "value" => { "executable" => true, "owner" => "BPFLoaderUpgradeab1e11111111111111111111111" } }
    end

    assert_nothing_raised { Solana::Vault.ensure_program_id_live!(client: fake_client) }
    assert_equal 1, fake_client.calls

    # Second call must NOT hit the RPC — cache should short-circuit.
    assert_nothing_raised { Solana::Vault.ensure_program_id_live!(client: fake_client) }
    assert_equal 1, fake_client.calls
  ensure
    Rails.cache = real_cache if real_cache
  end

  test "transient RPC errors are warned-and-swallowed, NOT raised" do
    fake_client = Object.new
    def fake_client.get_account_info(_)
      raise Solana::Client::RpcError.new("Too many requests for a specific RPC call")
    end

    assert_nothing_raised { Solana::Vault.ensure_program_id_live!(client: fake_client) }
  end
end
