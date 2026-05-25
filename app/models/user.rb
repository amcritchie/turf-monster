class User < ApplicationRecord
  include Sluggable

  has_secure_password validations: false
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
  validates :password, length: { minimum: 6 }, if: -> { password.present? }
  validates :password, confirmation: true, if: -> { password_confirmation.present? }
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
      password: SecureRandom.hex(16),
      email_verified_at: Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    # Race condition: another request created the user between our find_by and create
    find_by(email: auth.info.email) || find_by(provider: auth.provider, uid: auth.uid)
  end

  def self.from_solana_wallet(address)
    find_by(web3_solana_address: address)
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

  def google_connected?
    provider == "google_oauth2" && uid.present?
  end

  def has_password?
    password_digest.present? && password_digest != ""
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
  # that should invalidate other live sessions (password change today;
  # consider hooking on email change + 2FA disable later). Returns the
  # new token so callers can update session[:session_token] in step.
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

  # Per-request memoized — views call this from the navbar, the entry-token
  # badge, and the action body all in the same render. The User instance is
  # the same `current_user` reference across the request, so the memo holds.
  # Write paths that consume/mint tokens should also `user.instance_variable_set(:@entry_token_balance, nil)`
  # if the count needs to refresh mid-request (no current callers do this).
  def entry_token_balance
    @entry_token_balance ||= if solana_connected?
      begin
        Solana::Vault.new.list_entry_tokens(solana_address).count { |t| !t[:consumed] }
      rescue => e
        Rails.logger.warn "entry_token_balance fetch failed for user=#{id}: #{e.message}"
        0
      end
    else
      0
    end
  end

  # Returns the first unconsumed EntryTokenAccount PDA for this user, or nil.
  # Used by ContestsController#enter to decide between USDC-funded and token-funded entry paths.
  def next_unconsumed_entry_token
    return nil unless solana_connected?
    Solana::Vault.new.list_entry_tokens(solana_address).find { |t| !t[:consumed] }
  rescue => e
    Rails.logger.warn "next_unconsumed_entry_token fetch failed for user=#{id}: #{e.message}"
    nil
  end

  private

  # Every account gets an auto-generated username — signup never has a
  # "pick a username" step (the username's master record is on-chain).
  def ensure_username
    self.username ||= Studio::UsernameGenerator.generate
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
