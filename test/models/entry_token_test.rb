require "test_helper"

class EntryTokenTest < ActiveSupport::TestCase
  setup do
    @user = users(:alex)
  end

  test "valid token persists" do
    token = EntryToken.new(user: @user, status: "purchased", source: "dev", price_cents: 19_00)
    assert token.valid?, token.errors.full_messages.join(", ")
  end

  test "invalid status rejected" do
    token = EntryToken.new(user: @user, status: "bogus", source: "dev")
    assert_not token.valid?
  end

  test "invalid source rejected" do
    token = EntryToken.new(user: @user, status: "purchased", source: "bitcoin")
    assert_not token.valid?
  end

  test "PACKS has 1 and 3 pack pricing" do
    assert_equal 19_00, EntryToken.pack_price_cents(1)
    assert_equal 49_00, EntryToken.pack_price_cents(3)
  end

  test "per_token_cents reflects bulk discount" do
    assert_equal 19_00, EntryToken.per_token_cents(1)
    assert_equal 16_33, EntryToken.per_token_cents(3)
  end

  test "pack_price_cents raises on unknown quantity" do
    assert_raises(ArgumentError) { EntryToken.pack_price_cents(2) }
  end

  test "purchase! creates N rows tagged with source_ref" do
    tokens = EntryToken.purchase!(user: @user, quantity: 3, source: "stripe", source_ref: "cs_test_abc")
    assert_equal 3, tokens.size
    assert tokens.all? { |t| t.status == "purchased" && t.source == "stripe" && t.source_ref == "cs_test_abc" }
    assert_equal 3, EntryToken.for_source_ref("cs_test_abc").count
  end

  test "spend! marks token spent and attaches entry" do
    token = EntryToken.create!(user: @user, status: "purchased", source: "dev", price_cents: 19_00)
    entry = entries(:one)
    token.spend!(entry: entry)
    assert_equal "spent", token.reload.status
    assert_equal entry.id, token.entry_id
    assert_not_nil token.spent_at
  end

  test "spend! on already-spent token raises" do
    token = EntryToken.create!(user: @user, status: "spent", source: "dev", price_cents: 19_00, spent_at: Time.current)
    assert_raises(RuntimeError) { token.spend!(entry: entries(:one)) }
  end
end
