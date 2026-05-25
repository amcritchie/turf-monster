# Centralized referral-cache mutations. Two paths call into here:
#
#   1. Entry#after_commit on status transition to active/complete →
#      mark_entered!(entry.user). First time only — flips the user's
#      contest_entered flag, bumps the inviter's invitees_in_contest_count,
#      and queues InviterNotificationJob to email the nudge.
#
#   2. User#after_save when invited_by_id changes →
#      bump_invitees_count!(user). Tracks invitee_count on whichever
#      inviter the user is currently attributed to.
#
# Idempotency: mark_entered! returns early when contest_entered is
# already true, so callers don't need to guard. The email therefore fires
# at most once per invitee.
class ReferralProgress
  def self.mark_entered!(user)
    return if user.contest_entered?

    User.transaction do
      user.update!(contest_entered: true)
      inviter_id = user.invited_by_id
      if inviter_id
        User.increment_counter(:invitees_in_contest_count, inviter_id)
        InviterNotificationJob.perform_later(invitee_id: user.id)
      end
    end
  end

  # User#after_save callback target — keeps invitees_count in sync when
  # the invited_by_id column is set (or moves between inviters).
  def self.sync_invitee_attribution!(user)
    return unless user.saved_change_to_invited_by_id?

    previous_id, current_id = user.saved_change_to_invited_by_id
    User.decrement_counter(:invitees_count, previous_id) if previous_id
    User.increment_counter(:invitees_count, current_id)  if current_id

    # If this user has already entered a contest, the in-contest counter
    # on the new inviter also needs to follow the attribution.
    return unless user.contest_entered?

    User.decrement_counter(:invitees_in_contest_count, previous_id) if previous_id
    User.increment_counter(:invitees_in_contest_count, current_id)  if current_id
  end
end
