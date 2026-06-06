class User < ApplicationRecord
  include Sluggable

  # Passwordless: email auth is magic-link only (MagicLink service / MagicLinksController).
  # has_secure_password was removed in the passwordless re-auth refactor (closes Lazarus
  # audit #4 — the password re-auth → wallet-key-theft chain). The password_digest column
  # is kept dormant (no migration) but there is no longer a password= setter or #authenticate.
  has_one_attached :avatar
  has_many :entries, dependent: :destroy
  has_many :transaction_logs, dependent: :destroy
  has_many :stripe_purchases, dependent: :destroy
  belongs_to :inviter, class_name: "User", optional: true, foreign_key: :invited_by_id
  has_many :invitees, class_name: "User", foreign_key: :invited_by_id

  validates :email, uniqueness: true, allow_nil: true
  validates :web2_solana_address, uniqueness: true, allow_nil: true
  validates :web3_solana_address, uniqueness: true, allow_nil: true
  validates :username, length: { in: 3..30 }, format: { with: /\A[a-zA-Z0-9_-]+\z/, message: "only letters, numbers, hyphens, and underscores" }, uniqueness: { case_sensitive: false }, allow_nil: true
  validate :has_authentication_method

  before_validation :ensure_username, on: :create
  before_save :set_name_parts, if: -> { name_changed? }
  before_create :set_initial_session_token  # OPSEC-045
  after_create :generate_managed_wallet!
  # The username's master record lives on-chain — create the UserAccount PDA
  # (with the username) right after signup. after_commit so the managed wallet
  # + username are committed before the job runs.
  after_commit :enqueue_onchain_account_setup, on: :create

  # Referral cache: keep the inviter's invitees_count + (if this user has
  # already entered a contest) invitees_in_contest_count in sync when
  # invited_by_id is set/changed. ReferralProgress.sync_invitee_attribution!
  # is a no-op when invited_by_id didn't change.
  after_save { ReferralProgress.sync_invitee_attribution!(self) }

  # Newsletter subscribers = joined at least once and not since unsubscribed.
  scope :subscribed_to_newsletter, -> {
    where.not(joined_email_list_at: nil)
         .where("users.left_email_list_at IS NULL OR users.left_email_list_at < users.joined_email_list_at")
  }

  # --- Class methods ---

  # OPSEC-005: from_omniauth now refuses to silently link a freshly-arrived
  # Google identity to an unverified-email password user. Caller must pass
  # `email_verified: true` (set by GoogleOauthValidator after re-checking
  # Google's tokeninfo endpoint) for any linking to occur. If the existing
  # user hasn't proven they own the email (email_verified_at present), we
  # refuse the link and return :requires_verification — the controller
  # surfaces an explicit "this email already has an account; verify it
  # first" flow rather than auto-merging.
  #
  # Return values:
  #   - User instance         — happy path (returning Google user, or fresh signup)
  #   - :requires_verification — collision with an unverified existing user
  #   - :email_not_verified   — Google didn't verify the email (caller refused)
  def self.from_omniauth(auth, email_verified: false)
    # Returning Google user — already linked by (provider, uid)
    user = find_by(provider: auth.provider, uid: auth.uid)
    return user if user

    return :email_not_verified unless email_verified

    # Existing user with matching email — only auto-link if THEY also
    # proved ownership of this email at some point. Otherwise refuse: the
    # incoming Google identity has proven the email, but the existing
    # account hasn't, so we don't know they're the same human.
    existing = find_by(email: auth.info.email)
    if existing
      return :requires_verification if existing.email_verified_at.blank?
      existing.update!(
        provider: auth.provider,
        uid: auth.uid,
        email_verified_at: existing.email_verified_at || Time.current
      )
      return existing
    end

    # Brand new user via Google — email is verified by Google itself, so
    # mark verified at create-time.
    create!(
      email: auth.info.email,
      name: auth.info.name,
      provider: auth.provider,
      uid: auth.uid,
      email_verified_at: Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    # Race condition: another request created the user between our find_by and create
    find_by(email: auth.info.email) || find_by(provider: auth.provider, uid: auth.uid)
  end

  def self.from_solana_wallet(address)
    find_by(web3_solana_address: address)
  end

  # The "Turf Monster" house account (seeded admin, tied to the agent.turf.solana
  # wallet). It's the display author for system chat announcements — e.g. the
  # "<name> joined the contest" line, which is posted as a reactable bubble FROM
  # Turf Monster. Returns nil only in an unseeded DB (callers fall back). Not
  # memoized: the test suite recreates users, so a process-level cache would go
  # stale; the lookup is on the unique `username` index and only fires for the
  # handful of system messages in a chat render.
  def self.turf
    find_by(username: "turf")
  end

  def admin?
    role == "admin"
  end

  def inviter_slug=(slug)
    self.inviter = User.find_by(slug: slug) if slug.present?
  end

  # --- Display ---

  def display_name
    username.presence || name.presence || (email.present? ? email.split("@").first.capitalize : nil) || truncated_solana || "anon"
  end

  def avatar_initials
    (username.presence || name.presence || "?").first.upcase
  end

  AVATAR_COLORS = %w[#EF4444 #F97316 #EAB308 #22C55E #06B6D4 #3B82F6 #8B5CF6 #EC4899].freeze

  def avatar_color
    key = username.presence || name.presence || email.presence || id.to_s
    AVATAR_COLORS[Digest::MD5.hexdigest(key).hex % AVATAR_COLORS.size]
  end

  def profile_complete?
    username.present?
  end

  # Username changes are on-chain instructions against the UserAccount PDA,
  # so we need a connected wallet. We ALSO gate on contest_entered? — the
  # auto-generated kebab-case slug stays locked until the user has played
  # at least one contest, so accounts can't be created and immediately
  # renamed (anti-squatting + a small earn-it incentive).
  def can_change_username?
    solana_connected? && contest_entered?
  end

  def truncated_solana
    return nil unless solana_address.present?
    "#{solana_address[0..3]}...#{solana_address[-4..]}"
  end

  # --- Slate Progress ---

  def completed_slate_ids
    Entry.where(user: self, status: [:active, :complete])
         .joins(:contest)
         .where.not(contests: { slate_id: nil })
         .distinct
         .pluck("contests.slate_id")
  end

  def slate_progress(group_slates)
    completed = completed_slate_ids
    {
      completed_count: group_slates.count { |s| completed.include?(s.id) },
      total_count: group_slates.size,
      completed_slate_ids: completed,
      all_complete: group_slates.all? { |s| completed.include?(s.id) },
      slates: group_slates.map { |s| { id: s.id, name: s.name, starts_at: s.starts_at, completed: completed.include?(s.id) } }
    }
  end

  # --- Predicates ---

  def solana_connected?
    web2_solana_address.present? || web3_solana_address.present?
  end

  def managed_wallet?
    web2_solana_address.present?
  end

  def phantom_wallet?
    web3_solana_address.present?
  end

  # Canonical wallet identity — which kind of wallet this account holds,
  # independent of how the current session authenticated (see SessionContext).
  #   :phantom — has a self-custody web3 wallet (a managed wallet may also exist)
  #   :managed — custodial wallet only
  #   :none    — no wallet at all (e.g. an admin who has not linked Phantom)
  def wallet_kind
    return :phantom if phantom_wallet?
    return :managed if managed_wallet?
    :none
  end

  # --- Newsletter / quest ---

  # Subscribed = joined at least once and not since unsubscribed. Mirrors the
  # subscribed_to_newsletter scope.
  def subscribed_to_newsletter?
    joined_email_list_at.present? &&
      (left_email_list_at.nil? || left_email_list_at < joined_email_list_at)
  end

  # The 35-seed bonus fires on the user's FIRST manual username change only.
  # Every account gets an auto adjective-noun name at signup (before_validation
  # :ensure_username), so "has changed it" is tracked explicitly via
  # username_changed_at, never inferred from the current name.
  def first_username_change?
    username_changed_at.nil?
  end

  # Which quest mission the contest card shows: username -> newsletter -> invite
  # (terminal). Only meaningful once the user has entered a contest (the card is
  # gated on @has_entry upstream; can_change_username? already requires it).
  def quest_step
    return :username   if first_username_change?
    return :newsletter unless subscribed_to_newsletter?
    :invite
  end

  # Append the request IP to the per-user `ips` audit set (admin abuse review).
  # Shape: { "1.2.3.4" => { "first" => iso8601, "last" => iso8601, "count" => N } }.
  # Skips the write when the IP is already known and was seen within the last day,
  # so we don't write the users row on every request.
  def record_ip!(ip)
    ip = ip.to_s
    return if ip.blank?

    now = Time.current
    if (entry = ips[ip])
      last_seen = Time.iso8601(entry["last"]) rescue nil
      return if last_seen && last_seen > now - 1.day
      entry["count"] = entry["count"].to_i + 1
      entry["last"]  = now.iso8601
    else
      ips[ip] = { "first" => now.iso8601, "last" => now.iso8601, "count" => 1 }
    end
    update_column(:ips, ips) # audit append — skip validations/callbacks
  end

  def google_connected?
    provider == "google_oauth2" && uid.present?
  end

  # The user has completed the self-custody export flow: they've been
  # shown their encrypted_web2_solana_private_key, copied it into a wallet
  # they control, and clicked through the prove-custody confirmation. From
  # this moment the server stops auto-signing on their behalf — every
  # managed-path call site (ContestsController#enter token path,
  # Solana::Vault#build_enter_contest_with_token, etc.) MUST check this
  # predicate first and refuse to sign if true.
  #
  # We do NOT yet delete the encrypted_web2_solana_private_key (decision
  # deferred — see docs/SELF_CUSTODY.md). The column is the behavior
  # gate; the key stays as an operator-side backup until a future sweep.
  def self_custodied?
    self_custodied_at.present?
  end

  # Web2 managed-withdraw eligibility — the single source of truth shared
  # between WalletsController#withdraw, the inline /wallet card, and the
  # /account "Cash out" shortcut button.
  #
  # The flow lets the server sign an SPL transfer from the user's
  # managed-wallet ATA → off-ramp provider (Stripe / Bridge / etc.). That
  # requires three things:
  #   - managed_wallet?    — there's an encrypted key the server can sign with
  #   - !self_custodied?   — the user hasn't taken custody; we still sign
  #   - !phantom_wallet?   — Phantom users cash out from their own wallet app;
  #                          no need to route them through our queue
  def can_use_managed_withdraw?
    managed_wallet? && !self_custodied? && !phantom_wallet?
  end

  # B4 / OPSEC-048: account freeze for chargeback / dispute / refund. While
  # frozen, the user can't enter contests, buy tokens, or withdraw. Existing
  # on-chain tokens stay where they are (irreversible) but become unspendable
  # via this app. Unfreezing for v1 = rails console: `user.unfreeze!`.
  def frozen?
    frozen_at.present?
  end

  def freeze_for_payment_risk!(reason:)
    return if frozen?
    update_columns(frozen_at: Time.current, frozen_reason: reason.to_s.first(255))
    Rails.logger.error "[opsec-048] user.frozen user_id=#{id} reason=#{reason}"
  end

  def unfreeze!
    update_columns(frozen_at: nil, frozen_reason: nil)
    Rails.logger.info "[opsec-048] user.unfrozen user_id=#{id}"
  end

  # OPSEC-045: rotate the session-binding token. Call after any action
  # that should invalidate other live sessions (email change today;
  # consider hooking on 2FA disable later). Returns the new token so
  # callers can update session[:session_token] in step.
  def regenerate_session_token!
    new_token = SecureRandom.hex(32)
    update_column(:session_token, new_token)
    new_token
  end

  def set_initial_session_token
    self.session_token ||= SecureRandom.hex(32)
  end

  def has_email?
    email.present?
  end

  # --- Solana wallet ---

  # Convenience — returns "primary" address (web3 preferred, fallback web2)
  def solana_address
    web3_solana_address || web2_solana_address
  end

  def solana_keypair
    return nil unless encrypted_web2_solana_private_key.present?
    Solana::Keypair.from_encrypted(encrypted_web2_solana_private_key)
  end

  def generate_managed_wallet!
    return if web2_solana_address.present?
    # OPSEC-044: admins go web3-only. Server should never hold custodial keys
    # for accounts with elevated privileges — a managed wallet for an admin
    # combines the highest-value account with the largest decryption surface.
    # Admins link Phantom via the standard flow; if they need on-chain access
    # before linking, they have none until they do.
    return if admin?
    keypair = Solana::Keypair.generate
    update!(
      web2_solana_address: keypair.to_base58,
      encrypted_web2_solana_private_key: keypair.encrypt
    )
    # OPSEC-044: removed proactive EnsureAtaJob.perform_later(keypair.to_base58).
    # Pre-creating an ATA at signup spends admin SOL rent on every signup —
    # a sybil farm via solana_sessions#verify could drain admin SOL on
    # accounts that never deposit. ATAs are now created lazily by the code
    # paths that actually need them (Vault#fund_user, #transfer_from_user,
    # #transfer_spl all call ensure_ata internally before use).
    keypair
  end

  # --- Seeds (on-chain) ---
  # Seeds live on the UserAccount PDA (on-chain). 25 seeds per contest entry.
  # Level = (seeds / 100) + 1. UI-derived, no DB column.

  # SEEDS_PER_ENTRY removed in 2026-05-18 entry-tokens-onchain epic — seeds are now
  # awarded per the on-chain Season's seed_schedule. Use Solana::Vault#seeds_for_entry.
  SEEDS_PER_LEVEL = 100

  def self.level_for(seeds)
    (seeds / SEEDS_PER_LEVEL) + 1
  end

  def self.seeds_toward_next_level(seeds)
    seeds % SEEDS_PER_LEVEL
  end

  def self.seeds_progress_percent(seeds)
    (seeds_toward_next_level(seeds).to_f / SEEDS_PER_LEVEL * 100).round
  end

  def update_level_from_seeds!(seeds_total)
    computed_level = self.class.level_for(seeds_total)
    return nil if computed_level == level
    update!(level: computed_level)
    computed_level
  end

  # --- Entry tokens (on-chain EntryTokenAccount PDAs, turf-vault v0.9.0+) ---
  # Balance comes from on-chain RPC; consumption happens atomically inside the
  # enter_contest_with_token Anchor instruction (no spend_entry_token! needed).
  #
  # 60s Rails.cache layer wraps the getProgramAccounts RPC because public
  # devnet rate-limits it to ~1/sec/IP and the navbar+modal+badge can all
  # request it in the same pageview. Cache key includes the deployed
  # program ID so a program-redeploy implicitly invalidates. Writers
  # (TokenPurchaseJob mint, enter_contest_with_token consume) should call
  # `User#bust_entry_tokens_cache!` after the chain TX confirms.

  def entry_tokens_cache_key
    "entry_tokens/v1/#{Solana::Config::PROGRAM_ID[0, 8]}/#{solana_address}"
  end

  # Per-request memoized AND Rails-cached for 60s. Returns the full list
  # (including consumed) so both #entry_token_balance and
  # #next_unconsumed_entry_token can derive from one RPC call.
  def cached_entry_tokens
    return @cached_entry_tokens if defined?(@cached_entry_tokens)

    @cached_entry_tokens =
      if solana_connected?
        Rails.cache.fetch(entry_tokens_cache_key, expires_in: 60.seconds) do
          Solana::Vault.new.list_entry_tokens(solana_address)
        end
      else
        []
      end
  rescue => e
    Rails.logger.warn "cached_entry_tokens fetch failed for user=#{id}: #{e.message}"
    @cached_entry_tokens = []
  end

  def bust_entry_tokens_cache!
    Rails.cache.delete(entry_tokens_cache_key)
    remove_instance_variable(:@cached_entry_tokens) if defined?(@cached_entry_tokens)
    remove_instance_variable(:@entry_token_balance) if defined?(@entry_token_balance)
  end

  # Per-request memoized — views call this from the navbar, the entry-token
  # badge, and the action body all in the same render. The User instance is
  # the same `current_user` reference across the request, so the memo holds.
  def entry_token_balance
    @entry_token_balance ||= cached_entry_tokens.count { |t| !t[:consumed] }
  end

  # Returns the first unconsumed EntryTokenAccount PDA for this user, or nil.
  # Used by ContestsController#enter to decide between USDC-funded and token-funded entry paths.
  def next_unconsumed_entry_token
    cached_entry_tokens.find { |t| !t[:consumed] }
  end

  private

  # Every account gets an auto-generated username — signup never has a
  # "pick a username" step (the username's master record is on-chain).
  def ensure_username
    return if username.present?
    # Studio::UsernameGenerator emits "fruit-animal(-animal)" names that can
    # exceed the model's 30-char limit (length: { in: 3..30 }) — which
    # intermittently broke signups + CI (a generated name happened to be >30).
    # Prefer an in-range draw; truncate as a deterministic backstop so a
    # create never raises on username length.
    candidate = (1..5).lazy.map { Studio::UsernameGenerator.generate.to_s }
                      .find { |n| n.length.between?(3, 30) }
    self.username = (candidate || Studio::UsernameGenerator.generate.to_s)[0, 30]
  end

  # Eager on-chain UserAccount creation at signup — see CreateOnchainUserAccountJob.
  def enqueue_onchain_account_setup
    CreateOnchainUserAccountJob.perform_later(id)
  end

  def has_authentication_method
    return if email.present? || web3_solana_address.present? || (provider.present? && uid.present?)
    errors.add(:base, "Must have email, Solana address, or linked social account")
  end

  def set_name_parts
    parts = name.to_s.strip.split(" ")
    self.first_name = parts.first
    self.last_name = parts.last if parts.size > 1
  end

  def name_slug
    base = username.presence || name.presence || email.presence || solana_address.presence || "user"
    "#{base}-#{id}".downcase.gsub(/\s+/, "-")
  end
end
