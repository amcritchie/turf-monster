class CollapseContestLockedStatus < ActiveRecord::Migration[7.2]
  # v0.17: locking is now DERIVED from the on-chain lock_timestamp (mirrored to
  # starts_at), not a Contest status. The `locked` status value is retired —
  # a contest stays `open` right up to `settled`. Normalize any existing
  # `locked` rows to `open` so they keep validating against the collapsed enum.
  #
  # No schema change (status is a plain string column); this is a data fix.
  # See the squash/deployed-app trap: this must run before the enum no longer
  # accepts "locked", which it already doesn't in app code — so deploy this
  # migration together with the enum change.
  def up
    execute "UPDATE contests SET status = 'open' WHERE status = 'locked'"
  end

  def down
    # Irreversible: we can't tell which `open` contests were formerly `locked`.
    # No-op so a rollback doesn't fail.
  end
end
