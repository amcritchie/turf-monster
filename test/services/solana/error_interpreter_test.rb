require "test_helper"

class Solana::ErrorInterpreterTest < ActiveSupport::TestCase
  def interp(msg, contest: nil)
    Solana::ErrorInterpreter.interpret(msg, contest: contest)
  end

  test "user rejection returns toast, no blocker" do
    r = interp("User rejected the request")
    assert_equal "Transaction canceled.", r[:message]
    assert_nil r[:blocker]
    assert r[:toast]
  end

  test "no entry tokens maps to web2 no_tokens blocker" do
    r = interp("No entry tokens. Buy at /tokens/buy")
    assert_equal "no_tokens", r[:blocker][:reason]
    assert_equal "web2", r[:blocker][:mode]
  end

  test "0x1772 maps to web3 insufficient_balance with neededCents from contest" do
    contest = Struct.new(:entry_fee_cents).new(1900)
    r = interp("Transaction simulation failed: custom program error: 0x1772", contest: contest)
    assert_equal "insufficient_balance", r[:blocker][:reason]
    assert_equal "web3",                  r[:blocker][:mode]
    assert_equal 1900,                    r[:blocker][:data][:neededCents]
  end

  test "InsufficientBalance Anchor name also maps to insufficient_balance" do
    r = interp("Error: InsufficientBalance")
    assert_equal "insufficient_balance", r[:blocker][:reason]
  end

  test "0x1773 maps to contest_locked" do
    r = interp("custom program error: 0x1773")
    assert_equal "contest_locked", r[:blocker][:reason]
  end

  test "0x1774 maps to contest_full" do
    r = interp("custom program error: 0x1774")
    assert_equal "contest_full", r[:blocker][:reason]
  end

  test "0xbbb AccountDidNotDeserialize: log flag, no blocker" do
    r = interp("custom program error: 0xbbb")
    assert_nil r[:blocker]
    assert r[:log]
  end

  test "network errors return toast, no blocker" do
    r = interp("blockhash not found")
    assert_nil r[:blocker]
    assert r[:toast]
  end

  test "0x1789 InvalidCurrencyIndex maps to currency_unavailable blocker" do
    r = interp("custom program error: 0x1789")
    assert_equal "currency_unavailable", r[:blocker][:reason]
    assert_nil r[:blocker][:mode]
  end

  test "CurrencyNotActive Anchor name maps to currency_unavailable blocker" do
    r = interp("Error: CurrencyNotActive")
    assert_equal "currency_unavailable", r[:blocker][:reason]
    assert_match(/no longer accepted/i, r[:message])
  end

  test "0x178b EntryFeeNotSet maps to currency_unavailable blocker" do
    r = interp("custom program error: 0x178b")
    assert_equal "currency_unavailable", r[:blocker][:reason]
    assert_match(/doesn't accept/i, r[:message])
  end

  test "operator-only codes set log:true with no blocker" do
    [
      ["0x1787", /already registered/i],     # 6023 CurrencyAlreadyRegistered
      ["0x1788", /registry is full/i],       # 6024 CurrencyRegistryFull
      ["0x178c", /not locked/i],             # 6028 ContestNotLocked
      ["0x178d", /cannot be cancelled/i],    # 6029 ContestNotCancellable
      ["0x178e", /still has tokens/i],       # 6030 PrizePoolNotEmpty
      ["0x178f", /revenue account is empty/i], # 6031 EmptyRevenueAccount
      ["0x1790", /pinned treasury authority/i], # 6032 TreasuryAuthorityMismatch
      ["0x1791", /at least one entry fee/i]    # 6033 FeeAndPrizeBothZero
    ].each do |code, msg_pattern|
      r = interp("custom program error: #{code}")
      assert_nil r[:blocker], "#{code} should not have a blocker"
      assert r[:log], "#{code} should set log:true"
      assert_match msg_pattern, r[:message], "#{code} message: #{r[:message]}"
    end
  end

  test "username codes 6020-6022 set log:true with a friendly /account message" do
    [
      ["0x1784", /reserved word/i],             # 6020 UsernameReserved
      ["0x1785", /unsupported characters/i],    # 6021 UsernameInvalidChars
      ["0x1786", /too short/i]                  # 6022 UsernameTooShort
    ].each do |code, msg_pattern|
      r = interp("custom program error: #{code}")
      assert_nil r[:blocker], "#{code} should not have a blocker"
      assert r[:log], "#{code} should set log:true (Rails mirror drift signal)"
      assert_match msg_pattern, r[:message], "#{code} message: #{r[:message]}"
      assert_match %r{/account}, r[:message], "#{code} should point the user at /account"
    end
  end

  test "username codes match decimal and Anchor-name forms too" do
    assert_match(/reserved word/i,          interp("AnchorError ... Error Code: UsernameReserved. Error Number: 6020.")[:message])
    assert_match(/unsupported characters/i, interp("Error: UsernameInvalidChars")[:message])
    assert_match(/too short/i,              interp("custom program error 6022")[:message])
  end

  test "unknown errors pass through the message with no blocker" do
    r = interp("Something unrecognized")
    assert_equal "Something unrecognized", r[:message]
    assert_nil r[:blocker]
  end

  test "exception instances are accepted" do
    r = interp(StandardError.new("No entry tokens. Buy at /tokens/buy"))
    assert_equal "no_tokens", r[:blocker][:reason]
  end
end
