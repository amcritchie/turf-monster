require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "display_name returns username when present" do
    user = users(:alex)
    assert_equal "alex_test", user.display_name
  end

  test "display_name falls back to capitalized email prefix when username and name are blank" do
    user = User.create!(email: "newplayer@mcritchie.studio", password: "password")
    user.update_column(:username, nil) # usernames auto-generate; clear it to exercise the fallback
    assert_equal "Newplayer", user.display_name
  end

  test "every new account is auto-assigned a username" do
    user = User.create!(email: "auto@mcritchie.studio", password: "password")
    assert user.username.present?, "signup should auto-generate a username"
    assert_match(/\A[a-zA-Z0-9_-]+\z/, user.username)
  end

  test "an explicitly provided username is kept" do
    user = User.create!(email: "explicit@mcritchie.studio", password: "password", username: "chosen-name")
    assert_equal "chosen-name", user.username
  end

  test "authenticate with correct password" do
    user = users(:alex)
    assert user.authenticate("password")
  end

  # H1 (Stage 2 audit): DB-level uniqueness on LOWER(username) closes the
  # signup TOCTOU window. Rails' validation runs in Ruby — two concurrent
  # signups can both pass and both INSERT with the same username. The
  # partial unique index on LOWER(username) makes the second INSERT fail.
  test "username DB unique index rejects case-insensitive duplicate (bypassing Rails validations)" do
    User.create!(email: "h1a@example.com", password: "password", username: "RaceWinner")

    err = assert_raises(ActiveRecord::RecordNotUnique) do
      # Skip validations to simulate a race: pretend two threads both passed
      # the Ruby-level uniqueness check and tried to INSERT at the same time.
      dup = User.new(email: "h1b@example.com", password: "password", username: "racewinner")
      dup.save(validate: false)
    end
    assert_match(/index_users_on_lower_username/, err.message)
  end

  test "username DB index permits multiple NULLs (partial WHERE username IS NOT NULL)" do
    # Wallet-only / pre-profile-completion users have nil usernames; the
    # partial WHERE clause must let many of them coexist.
    u1 = User.new(email: "h1c@example.com", password: "password", username: nil)
    u2 = User.new(email: "h1d@example.com", password: "password", username: nil)
    assert u1.save(validate: false)
    assert u2.save(validate: false)
  end

  test "authenticate with wrong password" do
    user = users(:alex)
    assert_not user.authenticate("wrong")
  end

  test "email-only user valid without wallet" do
    user = User.new(email: "test@example.com", password: "password")
    assert user.valid?, user.errors.full_messages.join(", ")
  end

  test "user invalid with no auth methods" do
    user = User.new(password: "password")
    assert_not user.valid?
    assert user.errors[:base].any? { |e| e.include?("Must have") }
  end

  test "has_password? returns true for password users" do
    assert users(:alex).has_password?
  end

  test "has_email? returns true for email users" do
    assert users(:alex).has_email?
  end

  # entry tokens — refactored to on-chain in turf-vault v0.9.0+. See Solana::Vault#list_entry_tokens.
  # Tests for entry_token_balance now require RPC mocks; skipping until we add VCR/mock harness.

  test "entry_token_balance returns count of unconsumed tokens via Solana::Vault" do
    user = users(:sam) # web3 wallet per fixture
    vault = FakeVault.new(tokens: [
      { pda: "tpda1", consumed: false },
      { pda: "tpda2", consumed: true },
      { pda: "tpda3", consumed: false }
    ])
    Solana::Vault.stub :new, vault do
      assert_equal 2, user.entry_token_balance
    end
  end

  test "entry_token_balance returns 0 for users without a wallet (short-circuit)" do
    user = users(:jordan)
    assert_equal 0, user.entry_token_balance
  end

  test "entry_token_balance returns 0 if Solana::Vault raises" do
    user = users(:sam)
    crashing_vault = Object.new
    def crashing_vault.list_entry_tokens(*); raise "RPC down"; end
    Solana::Vault.stub :new, crashing_vault do
      assert_equal 0, user.entry_token_balance
    end
  end

  # from_omniauth tests

  def google_auth(email: "newgoogle@example.com", name: "Google User", uid: "123456")
    OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: { email: email, name: name }
    )
  end

  test "from_omniauth creates new user when no match" do
    auth = google_auth

    assert_difference "User.count", 1 do
      user = User.from_omniauth(auth, email_verified: true)
      assert_equal "newgoogle@example.com", user.email
      assert_equal "Google User", user.name
      assert_equal "google_oauth2", user.provider
      assert_equal "123456", user.uid
      assert user.persisted?
      # OPSEC-005: fresh Google signup auto-marks email_verified_at since
      # Google itself asserted the email.
      assert user.email_verified_at.present?
    end
  end

  test "from_omniauth links existing password user by email when verified" do
    alex = users(:alex)
    alex.update!(email_verified_at: Time.current)  # OPSEC-005 precondition
    auth = google_auth(email: alex.email, uid: "99999")

    assert_no_difference "User.count" do
      user = User.from_omniauth(auth, email_verified: true)
      assert_equal alex.id, user.id
      assert_equal "google_oauth2", user.provider
      assert_equal "99999", user.uid
    end
  end

  test "from_omniauth refuses silent link when existing user is unverified (OPSEC-005)" do
    alex = users(:alex)
    alex.update!(email_verified_at: nil)
    auth = google_auth(email: alex.email, uid: "99999")

    assert_no_difference "User.count" do
      result = User.from_omniauth(auth, email_verified: true)
      assert_equal :requires_verification, result
    end
  end

  test "from_omniauth refuses when caller says Google didn't verify the email (OPSEC-005)" do
    auth = google_auth(uid: "888")
    assert_no_difference "User.count" do
      result = User.from_omniauth(auth, email_verified: false)
      assert_equal :email_not_verified, result
    end
  end

  test "from_omniauth returns existing OAuth user" do
    auth = google_auth(email: "oauth@example.com", uid: "55555")
    original = User.from_omniauth(auth, email_verified: true)

    assert_no_difference "User.count" do
      returning = User.from_omniauth(auth, email_verified: true)
      assert_equal original.id, returning.id
    end
  end

  test "slug is set on save" do
    user = users(:alex)
    user.save!
    assert user.slug.present?
  end

  # --- Seeds (class methods, no DB) ---

  test "level_for returns 1 for 0 seeds" do
    assert_equal 1, User.level_for(0)
  end

  test "level_for returns correct level" do
    assert_equal 1, User.level_for(50)
    assert_equal 2, User.level_for(100)
    assert_equal 4, User.level_for(350)
  end

  test "seeds_toward_next_level returns modulo" do
    assert_equal 0, User.seeds_toward_next_level(0)
    assert_equal 50, User.seeds_toward_next_level(50)
    assert_equal 75, User.seeds_toward_next_level(175)
  end

  test "seeds_progress_percent returns percentage" do
    assert_equal 0, User.seeds_progress_percent(0)
    assert_equal 50, User.seeds_progress_percent(50)
    assert_equal 25, User.seeds_progress_percent(25)
  end

  # --- update_level_from_seeds! ---

  test "update_level_from_seeds! updates level when crossing boundary" do
    user = users(:alex)
    assert_equal 1, user.level
    result = user.update_level_from_seeds!(100)
    assert_equal 2, result
    assert_equal 2, user.reload.level
  end

  test "update_level_from_seeds! returns nil when level unchanged" do
    user = users(:alex)
    assert_equal 1, user.level
    result = user.update_level_from_seeds!(50)
    assert_nil result
    assert_equal 1, user.reload.level
  end

  test "update_level_from_seeds! handles zero seeds" do
    user = users(:alex)
    assert_nil user.update_level_from_seeds!(0)
    assert_equal 1, user.reload.level
  end
end
