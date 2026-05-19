class AddSessionTokenToUsers < ActiveRecord::Migration[7.2]
  # OPSEC-045: a per-user session token rotated on password change so an
  # attacker holding a stolen session cookie loses access when the legit
  # user changes their password. ApplicationController's before_action
  # checks `session[:session_token] == current_user.session_token` on
  # every request; mismatch → clear_app_session + redirect to login.
  #
  # Existing users get a session_token in the up-backfill below. Their
  # existing sessions don't carry a session_token cookie, so they'll be
  # forced through one re-login (acceptable per the OPSEC-042 pattern).
  def change
    add_column :users, :session_token, :string

    reversible do |dir|
      dir.up do
        # Backfill existing users with unique tokens.
        User.reset_column_information
        User.find_each do |u|
          u.update_column(:session_token, SecureRandom.hex(32))
        end
      end
    end

    add_index :users, :session_token
  end
end
