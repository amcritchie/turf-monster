namespace :wc do
  # Prep a slate for REAL scoring: wipe simulated game results off the shared
  # fixtures while preserving (freezing) one or more alpha/test contests so their
  # leaderboards survive. Games are shared across every contest on a slate, so a
  # naive wipe would re-zero the frozen contest too — hence the explicit freeze.
  #
  #   bin/rails wc:reset_results SLATE_ID=1 FREEZE=2 CONFIRM=1
  #
  #   SLATE_ID  required — the slate whose games get wiped clean.
  #   FREEZE    comma-separated contest ids to settle + rank-snapshot (scores
  #             frozen, excluded from re-scoring since only OPEN contests re-score).
  #   CONFIRM=1 required — guard, since this DELETES Goal records.
  #
  # After this: frozen contests show their final leaderboard (rank + payout filled
  # in from the format's payout table); all other open contests on the slate are
  # zeroed; games are back to `scheduled` with no scores. Real goals recorded via
  # /admin/scoring then score the remaining open contests live.
  desc "Wipe a slate's simulated results for real scoring; FREEZE=<ids> preserves alpha leaderboards"
  task reset_results: :environment do
    abort "Refusing to run without CONFIRM=1 (this deletes Goal records)." unless ENV["CONFIRM"] == "1"
    slate = Slate.find(Integer(ENV.fetch("SLATE_ID")))
    freeze_ids = ENV.fetch("FREEZE", "").split(",").map { |s| Integer(s.strip) }

    ActiveRecord::Base.transaction do
      # 1) Freeze the snapshot contests: rank by score, fill payouts from the
      #    format table, settle (so future goal events skip them — re-scoring only
      #    touches OPEN contests). Direct column writes: no on-chain, no payouts.
      freeze_ids.each do |cid|
        c = Contest.find(cid)
        c.entries.where(status: %i[active complete]).order(score: :desc, id: :asc).each_with_index do |e, i|
          rank = i + 1
          e.update_columns(rank: rank, payout_cents: c.payouts[rank].to_i)
        end
        c.update!(status: :settled)
        puts "  froze ##{cid} #{c.slug} → settled (#{c.entries.count} entries ranked + paid out on paper)"
      end

      # 2) Wipe the slate's games: delete simulated goals, null scores → scheduled,
      #    null matchup goals → pending. delete_all skips the Goal destroy callback
      #    (we reset the derived columns directly right here).
      game_slugs = SlateMatchup.where(slate_id: slate.id).where.not(game_slug: nil).distinct.pluck(:game_slug)
      n_goals    = Goal.where(game_slug: game_slugs).delete_all
      n_games    = Game.where(slug: game_slugs).update_all(home_score: nil, away_score: nil, status: "scheduled")
      n_matchups = SlateMatchup.where(slate_id: slate.id).update_all(goals: nil, status: "pending")
      puts "  wiped #{n_games} games · deleted #{n_goals} goals · reset #{n_matchups} matchups"

      # 3) Zero the remaining OPEN contests on this slate for a clean start
      #    (clearing goals doesn't clear cached points — compute_points! no-ops on
      #    nil goals — so reset points + score explicitly).
      Contest.where(slate_id: slate.id, status: :open).where.not(id: freeze_ids).find_each do |c|
        entry_ids = c.entries.pluck(:id)
        Selection.where(entry_id: entry_ids).update_all(points: nil)
        c.entries.update_all(score: 0.0, rank: nil)
        c.touch
        puts "  zeroed open ##{c.id} #{c.slug} (#{entry_ids.size} entries)"
      end
    end

    puts "wc:reset_results done for slate #{slate.id}."
  end
end
