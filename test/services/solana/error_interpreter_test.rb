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
