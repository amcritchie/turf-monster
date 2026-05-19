require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "display_name returns username when present" do
    user = users(:alex)
    assert_equal "alex_test", user.display_name
  end

  test "display_name returns capitalized email prefix when name is blank" do
    user = User.create!(email: "newplayer@mcritchie.studio", password: "password")
    assert_equal "Newplayer", user.display_name
  end

  test "authenticate with correct password" do
    user = users(:alex)
    assert user.authenticate("password")
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

  test "entry_token_balance reads from on-chain (SKIPPED — needs RPC mock)" do
    skip "Refactored to on-chain — needs Solana::Vault stub"
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
