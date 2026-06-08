# Immutable audit trail of admin "act as user" impersonation (OPSEC-046).
# One row per enter + one per exit, written by Admin::ImpersonationsController
# (and SessionsController#destroy when an impersonating admin logs out).
#
# Matches the OutboundRequest audit convention: created_at only (no updated_at),
# no slug. The retention story is the same — append-only, never mutated.
#
#   - `admin`       — the real admin who initiated the impersonation
#   - `target_user` — the user being acted as
#   - `action`      — enter (started) / exit (returned)
#   - `reason`      — optional context (e.g. "logout" when an impersonating
#                     admin logs out instead of explicitly returning)
class ImpersonationLog < ApplicationRecord
  self.record_timestamps = false # created_at managed manually, no updated_at

  belongs_to :admin,       class_name: "User"
  belongs_to :target_user, class_name: "User"

  enum :action, { enter: 0, exit: 1 }

  scope :recent, -> { order(created_at: :desc) }

  before_create :ensure_created_at

  private

  def ensure_created_at
    self.created_at ||= Time.current
  end
end
