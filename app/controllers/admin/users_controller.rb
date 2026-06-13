module Admin
  class UsersController < ApplicationController
    before_action :require_admin

    # Sort pill label → query value. Default is "active" (last request) — the
    # recently-active users are the interesting ones.
    SORTS = {
      "active"     => "Last active",
      "seeds"      => "Seeds",
      "name"       => "Name",
      "created"    => "Created",
      "last_entry" => "Last entry"
    }.freeze

    def index
      @sort = SORTS.key?(params[:sort]) ? params[:sort] : "active"
      base  = User.includes(:inviter)

      @users =
        case @sort
        when "active"
          base.by_recent_session
        when "seeds"
          base.order(seeds: :desc, created_at: :desc)
        when "name"
          base.order(Arel.sql("LOWER(COALESCE(NULLIF(users.username, ''), NULLIF(users.name, ''), users.email)) ASC"))
        when "created"
          base.order(created_at: :desc)
        when "last_entry"
          base.left_joins(:entries).group("users.id")
              .order(Arel.sql("MAX(entries.created_at) DESC NULLS LAST"))
        end
    end
  end
end
