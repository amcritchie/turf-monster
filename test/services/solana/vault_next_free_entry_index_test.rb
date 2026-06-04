require "test_helper"

# Guards the orphaned-PDA fix: Vault#next_free_entry_index must pick the lowest
# entry slot whose on-chain Entry PDA isn't already allocated (a contest Reset
# leaves Entry accounts behind), skipping any indices the caller already knows
# are claimed. See Entry#assign_onchain_entry_number!.
class Solana::VaultNextFreeEntryIndexTest < ActiveSupport::TestCase
  CONTEST = "test-contest"
  WALLET  = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr"

  # Fake RPC client: get_account_info returns a non-null value only for PDAs in
  # `existing` (mimics allocated Entry accounts); null otherwise (free slot).
  def vault_with(existing = [])
    set = existing.to_set
    client = Object.new
    client.define_singleton_method(:get_account_info) do |pda, **_opts|
      set.include?(pda) ? { "value" => { "owner" => "prog" } } : { "value" => nil }
    end
    Solana::Vault.new(client: client)
  end

  def pda(vault, n)
    Solana::Keypair.encode_base58(vault.entry_pda(CONTEST, WALLET, n).first)
  end

  test "returns 0 when no slot is allocated" do
    v = vault_with
    assert_equal 0, v.next_free_entry_index(CONTEST, WALLET, max: 3)
  end

  test "skips an allocated slot 0 (orphaned PDA) and returns 1" do
    occupied = pda(vault_with, 0)
    v = vault_with([occupied])
    assert_equal 1, v.next_free_entry_index(CONTEST, WALLET, max: 3)
  end

  test "skips indices in the skip list even when their PDA is free" do
    v = vault_with
    assert_equal 1, v.next_free_entry_index(CONTEST, WALLET, max: 3, skip: [0])
  end

  test "combines on-chain + skip: slot 0 allocated and 1 skipped -> 2" do
    base = vault_with
    v = vault_with([pda(base, 0)])
    assert_equal 2, v.next_free_entry_index(CONTEST, WALLET, max: 3, skip: [1])
  end

  test "returns nil when every slot is taken" do
    base = vault_with
    all = (0...3).map { |n| pda(base, n) }
    v = vault_with(all)
    assert_nil v.next_free_entry_index(CONTEST, WALLET, max: 3)
  end
end
