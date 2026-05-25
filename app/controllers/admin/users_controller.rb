module Admin
  class UsersController < ApplicationController
    before_action :require_admin

    def index
      # All three referral metrics live on the users table now (see
      # AddReferralCachesToUsers migration). Sort by invitees-in-contest
      # desc — that's the "most valuable referrer" signal.
      @users = User
                 .includes(:inviter)
                 .order(invitees_in_contest_count: :desc,
                        invitees_count:            :desc,
                        created_at:                :desc)
    end
  end
end
