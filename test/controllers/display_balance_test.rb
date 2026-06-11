require "test_helper"
require "minitest/mock"

# ApplicationController#display_balance — the navbar pill is USDC + USDT
# COMBINED (USDT entries, 2026-06-10): nil counts as 0 in the sum, but the
# result is nil only when BOTH sides are nil (preserves the cache-cold
# "loading" state), and 0 stays the definitive guest/non-wallet answer.
#
# Unit-style on a bare controller instance with current_user pinned. The
# cache-backed branch needs a real store — the test env runs :null_store
# (reads always nil), so Rails.cache is stubbed to a MemoryStore per the
# injected-store pattern (see CLAUDE.md "Test DB" note).
class DisplayBalanceTest < ActiveSupport::TestCase
  setup do
    @user = users(:sam) # web3_solana_address fixture → solana_connected?
  end

  def controller_for(user, wallet_balances: :none)
    ApplicationController.new.tap do |c|
      c.instance_variable_set(:@wallet_balances, wallet_balances) unless wallet_balances == :none
      c.define_singleton_method(:current_user) { user }
    end
  end

  def with_memory_cache(&block)
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new, &block)
  end

  test "cache cold on both sides → nil (loading state preserved)" do
    with_memory_cache do
      assert_nil controller_for(@user).send(:display_balance)
    end
  end

  test "usdc 5 + usdt nil → 5 (nil counts as 0 in the sum)" do
    with_memory_cache do
      Rails.cache.write("usdc_balance:#{@user.id}", 5.0)
      assert_equal 5.0, controller_for(@user).send(:display_balance)
    end
  end

  test "usdc 5 + usdt 3 → 8 (combined)" do
    with_memory_cache do
      Rails.cache.write("usdc_balance:#{@user.id}", 5.0)
      Rails.cache.write("usdt_balance:#{@user.id}", 3.0)
      assert_equal 8.0, controller_for(@user).send(:display_balance)
    end
  end

  test "usdc nil + usdt 3 → 3" do
    with_memory_cache do
      Rails.cache.write("usdt_balance:#{@user.id}", 3.0)
      assert_equal 3.0, controller_for(@user).send(:display_balance)
    end
  end

  test "guest → definitive 0" do
    with_memory_cache do
      assert_equal 0, controller_for(nil).send(:display_balance)
    end
  end

  test "page-preloaded @wallet_balances combine usdc + usdt" do
    c = controller_for(@user, wallet_balances: { usdc: 5.0, usdt: 3.25, sol: 0.1 })
    assert_equal 8.25, c.send(:display_balance)
  end

  test "page-preloaded balances that flaked to nils stay a definitive 0 (preload branch)" do
    c = controller_for(@user, wallet_balances: { usdc: nil, usdt: nil })
    assert_equal 0, c.send(:display_balance)
  end
end
