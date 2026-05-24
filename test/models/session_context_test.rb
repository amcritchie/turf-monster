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

  test "to_h for guest has the same keys as for a logged-in user" do
    guest = SessionContext.new(user: nil, onchain_session: false).to_h
    logged_in = SessionContext.new(user: User.new(email: "x@example.com"), onchain_session: false).to_h
    assert_equal logged_in.keys.sort, guest.keys.sort,
                 "guest + logged-in must share the same to_h shape so the client store hydrates identically"
    assert_equal false, guest[:loggedIn]
    assert_equal :guest, guest[:mode]
    assert_nil guest[:userId]
    assert_equal "", guest[:address], "address coerces to '' (not nil) so the JSON shape stays stable"
    assert_equal false, guest[:phantomLinked]
  end

  test "to_h for a web3 session carries the phantom address" do
    user = User.new(id: 42, email: "z@example.com", web3_solana_address: "PhantomAddr444")
    h = SessionContext.new(user: user, onchain_session: true).to_h
    assert_equal :web3, h[:mode]
    assert_equal 42, h[:userId]
    assert_equal "PhantomAddr444", h[:address]
    assert_equal true, h[:phantomLinked]
  end

  test "address prefers web3 over web2 (User#solana_address fallback chain)" do
    # A user who has both a Phantom wallet AND a managed wallet — web3 wins.
    user = User.new(
      email: "dual@example.com",
      web3_solana_address: "WinningPhantom",
      web2_solana_address: "FallbackManaged"
    )
    ctx = SessionContext.new(user: user, onchain_session: true)
    assert_equal "WinningPhantom", ctx.address
  end

  test "user_id is nil for guest, integer for logged-in" do
    assert_nil SessionContext.new(user: nil, onchain_session: false).user_id
    assert_equal 7, SessionContext.new(user: User.new(id: 7), onchain_session: false).user_id
  end

  test "as_json mirrors to_h exactly (so Rails JSON serialization stays in lockstep)" do
    user = User.new(id: 1, email: "a@example.com")
    ctx = SessionContext.new(user: user, onchain_session: false)
    assert_equal ctx.to_h, ctx.as_json
  end

  test "MODES constant is the canonical 3-way (frozen)" do
    assert_equal %i[guest web2 web3], SessionContext::MODES
    assert SessionContext::MODES.frozen?, "MODES must be frozen to prevent runtime mutation"
  end

  test "phantom_linked? is false when there is no user (guest never has a wallet)" do
    assert_not SessionContext.new(user: nil, onchain_session: false).phantom_linked?
    assert_not SessionContext.new(user: nil, onchain_session: true).phantom_linked?,
               "guest with stray onchain_session flag still has no account-level wallet"
  end

  test "logged_in? is the negation of guest? across all combinations" do
    [
      SessionContext.new(user: nil, onchain_session: false),
      SessionContext.new(user: nil, onchain_session: true),
      SessionContext.new(user: User.new, onchain_session: false),
      SessionContext.new(user: User.new, onchain_session: true)
    ].each do |ctx|
      assert_equal !ctx.guest?, ctx.logged_in?,
                   "logged_in?/guest? invariant failed for mode=#{ctx.mode}"
    end
  end
end
