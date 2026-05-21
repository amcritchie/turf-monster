# Canonical, single source of truth for the current viewer's auth + wallet state.
#
# `mode` is the 3-way value the entire UI branches on:
#   :guest — not logged in
#   :web2  — logged in with a custodial/managed wallet this session (email or
#            Google login, or a Phantom account that did NOT authenticate via a
#            wallet signature this session)
#   :web3  — logged in AND authenticated via a live Phantom wallet signature
#            this session (onchain_session?) — i.e. can sign on-chain txs now
#
# Mode is decided by the SESSION, not by account identity: a Phantom owner who
# logs in by email is :web2 for that session. `phantom_linked?` exposes the
# account-level fact separately, so the UI can still offer "Connect Phantom".
#
# Built once per request by ApplicationController#wallet_context, serialised
# into the page, and mirrored client-side by Alpine.store('session').
# See docs/AUTH.md.
class SessionContext
  MODES = %i[guest web2 web3].freeze

  attr_reader :user

  def initialize(user:, onchain_session:)
    @user = user
    @onchain_session = onchain_session
  end

  # The canonical 3-way. Session-based — see class comment.
  def mode
    return :guest unless user
    @onchain_session ? :web3 : :web2
  end

  def guest?
    mode == :guest
  end

  def web2?
    mode == :web2
  end

  def web3?
    mode == :web3
  end

  def logged_in?
    !guest?
  end

  # Account-level fact, independent of `mode`: the account holds a self-custody
  # (Phantom) wallet. A :web2-mode session can still be phantom_linked — that is
  # exactly the "Phantom owner logged in by email" case.
  def phantom_linked?
    user&.phantom_wallet? || false
  end

  def user_id
    user&.id
  end

  # Primary wallet address (web3 preferred), or nil when logged out.
  def address
    user&.solana_address
  end

  # Shape consumed by the client Alpine.store('session'). Kept deliberately
  # cheap — DB/session columns only, never an on-chain RPC call.
  def to_h
    {
      loggedIn:      logged_in?,
      mode:          mode,
      phantomLinked: phantom_linked?,
      userId:        user_id,
      address:       address.to_s
    }
  end

  def as_json(*)
    to_h
  end
end
