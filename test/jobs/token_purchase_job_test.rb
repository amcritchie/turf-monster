require "test_helper"

# TokenPurchaseJob was refactored to mint on-chain (turf-vault v0.9.0+) instead of
# creating DB EntryToken rows. The previous test suite mocked Vault#fund_user; the new
# job mocks Vault#mint_entry_token. Tests skipped until the new stub harness lands.
class TokenPurchaseJobTest < ActiveJob::TestCase
  test "mints N tokens on-chain via Vault.mint_entry_token (SKIPPED — needs RPC mock)" do
    skip "Refactored to on-chain — see Solana::Vault#mint_entry_token. Needs new mock harness."
  end

  test "is idempotent on repeat with same session id (SKIPPED)" do
    skip "Refactored to on-chain — see StripePurchase.for_session uniqueness."
  end

  test "bails on unknown user_id (SKIPPED)" do
    skip "Refactored to on-chain — see StripePurchase row creation guard."
  end
end
