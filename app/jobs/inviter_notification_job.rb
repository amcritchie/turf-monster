# Enqueued by ReferralProgress.mark_entered! the first time an invitee
# lands a confirmed (active or complete) contest entry. Sends a one-shot
# nudge email to the inviter via InviterMailer#friend_joined_contest.
#
# Idempotency lives at the caller: contest_entered is a one-way ratchet
# on User, so mark_entered! exits early on subsequent calls and this job
# enqueues exactly once per invitee. If the job itself retries (Sidekiq
# pulls it twice), the worst case is a duplicate email — acceptable
# given the low-stakes content.
class InviterNotificationJob < ApplicationJob
  queue_as :default

  def perform(invitee_id:)
    invitee = User.find_by(id: invitee_id)
    return unless invitee
    return unless invitee.inviter && invitee.inviter.email.present?

    InviterMailer.friend_joined_contest(invitee: invitee).deliver_now
  end
end
