class EntriesController < ApplicationController
  include Solana::SessionAuth

  before_action :require_authentication
  before_action :require_geo_allowed
  before_action :require_unfrozen_account

  # Replace the picks on an existing active entry. DB-only — the on-chain
  # ContestEntry PDA is a pure ticket (no pick hash), so changes here don't
  # need a co-signed transaction. Contest must still be open; lock checks
  # mirror Entry#confirm! on the changed slots only.
  def update
    entry = current_user.entries.find_by(slug: params[:slug])
    return render json: { error: "Entry not found" }, status: :not_found unless entry
    return render json: { error: "Wrong contest" }, status: :not_found unless entry.contest.slug == params[:contest_id]
    return render json: { error: "Only active entries can be edited" }, status: :unprocessable_entity unless entry.active?

    matchup_ids = Array(params[:matchup_ids]).map(&:to_i)

    rescue_and_log(target: entry, parent: entry.contest) do
      entry.update_picks!(matchup_ids)
      render json: { success: true, redirect: contest_path(entry.contest) }
    end
  rescue StandardError => e
    render json: { success: false, error: e.message }, status: :unprocessable_entity
  end
end
