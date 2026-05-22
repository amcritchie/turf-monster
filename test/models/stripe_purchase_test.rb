require "test_helper"
require "minitest/mock"

class StripePurchaseTest < ActiveSupport::TestCase
  test "PACKS resolves price + quantity by string id" do
    assert_equal 19_00, StripePurchase.pack_price_cents("single")
    assert_equal 1,     StripePurchase.pack_quantity("single")
    assert_equal 49_00, StripePurchase.pack_price_cents("trio")
    assert_equal 3,     StripePurchase.pack_quantity("trio")
  end

  test "test_trio is the $5 / 3-token scaffolding bundle" do
    assert_equal 5_00, StripePurchase.pack_price_cents("test_trio")
    assert_equal 3,    StripePurchase.pack_quantity("test_trio")
  end

  test "per_token_cents divides pack price by quantity" do
    assert_equal 19_00, StripePurchase.per_token_cents("single")
    assert_equal 1633,  StripePurchase.per_token_cents("trio")       # 4900 / 3
    assert_equal 166,   StripePurchase.per_token_cents("test_trio")  # 500 / 3
  end

  test "pack raises KeyError for an unknown id" do
    assert_raises(KeyError) { StripePurchase.pack("nope") }
  end

  test "available_packs hides test_trio unless test scaffolding is on" do
    AppFlags.stub :test_scaffolding?, false do
      assert_not StripePurchase.available_packs.key?("test_trio")
      assert StripePurchase.available_packs.key?("single")
      assert StripePurchase.available_packs.key?("trio")
    end
    AppFlags.stub :test_scaffolding?, true do
      assert StripePurchase.available_packs.key?("test_trio")
    end
  end
end
