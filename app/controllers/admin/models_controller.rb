module Admin
  class ModelsController < ApplicationController
    before_action :require_admin

    include Studio::AdminModels

    MODELS = {
      "users" => {
        label: "Users",
        description: "Accounts, auth methods, wallets, and risk flags"
      },
      "teams" => {
        label: "Teams",
        description: "Sports teams, league metadata, and home arena links"
      },
      "arenas" => {
        label: "Arenas",
        description: "Venues seeded for teams and schedule QA"
      },
      "games" => {
        label: "Games",
        description: "Matchups, kickoff times, venues, and live scores"
      },
      "entries" => {
        label: "Entries",
        description: "User contest submissions, scoring, payouts, and on-chain state"
      }
    }.freeze

    private

    def admin_model_scope_for(key)
      case key
      when "users"
        User.with_attached_avatar.order(created_at: :desc)
      when "teams"
        Team.includes(:home_arena).order(team_sort_order)
      when "arenas"
        Arena.includes(:home_teams).order(:name)
      when "games"
        Game.includes(:home_team, :away_team).order(Arel.sql("kickoff_at DESC NULLS LAST"))
      when "entries"
        Entry.includes(:user, :contest).order(created_at: :desc)
      else
        raise ArgumentError, "Unknown admin model key: #{key.inspect}"
      end
    end
  end
end
