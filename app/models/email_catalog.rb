# The app's email registry — every email Turf Monster sends, with its type
# (transactional / marketing) and a preview builder (sample data → a Mail).
# Powers the admin email manager (Admin::EmailsController). This registry is the
# thing that moves into the shared studio-engine email framework in Phase 2.
module EmailCatalog
  Item = Struct.new(:key, :name, :type, :description, :builder, keyword_init: true)

  def self.sample_user
    User.where.not(email: nil).first || User.new(email: "you@example.com", username: "turf-fan")
  end

  def self.entries
    u = sample_user
    tok = "preview-token-not-real"
    [
      Item.new(key: "newsletter_welcome", name: "Newsletter welcome", type: :transactional,
               description: "Sent on a user's first newsletter subscribe (the 25-seed quest).",
               builder: -> { NewsletterMailer.welcome(u) }),
      Item.new(key: "magic_link", name: "Magic-link sign-in", type: :transactional,
               description: "Passwordless create-or-login link.",
               builder: -> { UserMailer.magic_link(u.email, tok) }),
      Item.new(key: "email_verification", name: "Email verification", type: :transactional,
               description: "Verify the email address on an account.",
               builder: -> { UserMailer.email_verification(u, tok) }),
      Item.new(key: "wallet_export", name: "Wallet export", type: :transactional,
               description: "Self-custody wallet export reveal link.",
               builder: -> { UserMailer.wallet_export(u, tok) }),
      Item.new(key: "email_change_notification", name: "Email change — notify old address", type: :transactional,
               description: "Heads-up to the OLD address when an email change is requested.",
               builder: -> { UserMailer.email_change_notification(u, "old@example.com", "new@example.com") }),
      Item.new(key: "email_change_confirmation", name: "Email change — confirm new address", type: :transactional,
               description: "Confirm link sent to the NEW address for an email change.",
               builder: -> { UserMailer.email_change_confirmation(u, u.email, "new@example.com", tok) }),
      Item.new(key: "friend_joined_contest", name: "Friend joined contest", type: :transactional,
               description: "Referral notification when an invitee joins a contest.",
               builder: lambda {
                 inviter = User.where.not(email: nil).first
                 invitee = User.where.not(email: nil).where.not(id: inviter&.id).first || u
                 invitee.inviter = inviter # in-memory, preview only
                 InviterMailer.friend_joined_contest(invitee: invitee)
               }),
      Item.new(key: "contest_winnings", name: "Contest winnings", type: :transactional,
               description: "Payout notification when a user wins a contest.",
               builder: -> { ContestMailer.winnings(::Entry.where("payout_cents > 0").where.not(rank: nil).first || ::Entry.where.not(rank: nil).first || ::Entry.first) }),
    ]
  end

  def self.find(key)
    entries.find { |e| e.key == key }
  end
end
