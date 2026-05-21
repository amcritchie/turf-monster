require "test_helper"

class SessionContextTest < ActiveSupport::TestCase
  test "guest mode when there is no user" do
    ctx = SessionContext.new(user: nil, onchain_session: false)
    assert_equal :guest, ctx.mode
    assert ctx.guest?
    assert_not ctx.logged_in?
    assert_not ctx.phantom_linked?
    assert_nil ctx.address
  end

  test "web2 mode for a logged-in non-onchain session" do
    ctx = SessionContext.new(user: User.new(email: "x@example.com"), onchain_session: false)
    assert_equal :web2, ctx.mode
    assert ctx.web2?
    assert ctx.logged_in?
  end

  test "web3 mode for a logged-in onchain session" do
    user = User.new(web3_solana_address: "Wallet111")
    ctx = SessionContext.new(user: user, onchain_session: true)
    assert_equal :web3, ctx.mode
    assert ctx.web3?
  end

  test "phantom_linked is account-level and independent of mode" do
    # A Phantom owner logged in by email this session: web2 mode, still linked.
    phantom_user = User.new(web3_solana_address: "Wallet222")
    ctx = SessionContext.new(user: phantom_user, onchain_session: false)
    assert_equal :web2, ctx.mode
    assert ctx.phantom_linked?
  end

  test "to_h is the cheap client-store shape" do
    user = User.new(email: "y@example.com", web2_solana_address: "Managed333")
    h = SessionContext.new(user: user, onchain_session: false).to_h
    assert_equal true, h[:loggedIn]
    assert_equal :web2, h[:mode]
    assert_equal "Managed333", h[:address]
    assert_equal false, h[:phantomLinked]
  end
end
