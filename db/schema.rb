# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_05_17_160000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "contests", force: :cascade do |t|
    t.string "name", null: false
    t.string "contest_type", default: "small", null: false
    t.integer "entry_fee_cents", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.integer "max_entries"
    t.string "tagline"
    t.integer "rank"
    t.datetime "starts_at"
    t.bigint "slate_id"
    t.string "onchain_contest_id"
    t.boolean "onchain_settled", default: false, null: false
    t.string "onchain_tx_signature"
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "locks_at_date_selected"
    t.string "locks_at_time_selected"
    t.string "locks_at_timezone_selected"
    t.index ["rank"], name: "index_contests_on_rank"
    t.index ["slate_id"], name: "index_contests_on_slate_id"
    t.index ["slug"], name: "index_contests_on_slug", unique: true
    t.index ["status"], name: "index_contests_on_status"
    t.index ["user_id"], name: "index_contests_on_user_id"
  end

  create_table "entries", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "contest_id", null: false
    t.float "score", default: 0.0, null: false
    t.string "status", default: "cart", null: false
    t.integer "rank"
    t.integer "payout_cents", default: 0
    t.integer "entry_number"
    t.string "onchain_entry_id"
    t.string "onchain_tx_signature"
    t.string "payout_tx_signature"
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["contest_id", "status"], name: "index_entries_on_contest_id_and_status"
    t.index ["contest_id"], name: "index_entries_on_contest_id"
    t.index ["slug"], name: "index_entries_on_slug", unique: true
    t.index ["status"], name: "index_entries_on_status"
    t.index ["user_id", "contest_id"], name: "index_entries_on_user_id_and_contest_id"
    t.index ["user_id"], name: "index_entries_on_user_id"
  end

  create_table "entry_tokens", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "entry_id"
    t.string "status", default: "purchased", null: false
    t.string "source", null: false
    t.string "source_ref"
    t.integer "price_cents", default: 0, null: false
    t.datetime "spent_at"
    t.datetime "refunded_at"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entry_id"], name: "index_entry_tokens_on_entry_id"
    t.index ["source_ref"], name: "index_entry_tokens_on_source_ref"
    t.index ["user_id", "status"], name: "index_entry_tokens_on_user_id_and_status"
    t.index ["user_id"], name: "index_entry_tokens_on_user_id"
  end

  create_table "error_logs", force: :cascade do |t|
    t.text "message", null: false
    t.text "inspect"
    t.text "backtrace"
    t.string "target_type"
    t.bigint "target_id"
    t.string "target_name"
    t.string "parent_type"
    t.bigint "parent_id"
    t.string "parent_name"
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_error_logs_on_created_at"
    t.index ["parent_type", "parent_id"], name: "index_error_logs_on_parent_type_and_parent_id"
    t.index ["target_type", "target_id"], name: "index_error_logs_on_target_type_and_target_id"
  end

  create_table "games", force: :cascade do |t|
    t.string "slug", null: false
    t.string "home_team_slug", null: false
    t.string "away_team_slug", null: false
    t.datetime "kickoff_at"
    t.string "venue"
    t.string "status", default: "scheduled"
    t.integer "home_score"
    t.integer "away_score"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["away_team_slug"], name: "index_games_on_away_team_slug"
    t.index ["home_team_slug"], name: "index_games_on_home_team_slug"
    t.index ["slug"], name: "index_games_on_slug", unique: true
    t.index ["status"], name: "index_games_on_status"
  end

  create_table "geo_settings", force: :cascade do |t|
    t.string "app_name", null: false
    t.boolean "enabled", default: false, null: false
    t.jsonb "banned_states", default: []
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_name"], name: "index_geo_settings_on_app_name", unique: true
    t.index ["slug"], name: "index_geo_settings_on_slug", unique: true
  end

  create_table "goals", force: :cascade do |t|
    t.string "game_slug", null: false
    t.string "team_slug", null: false
    t.string "player_slug"
    t.integer "minute"
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["game_slug"], name: "index_goals_on_game_slug"
    t.index ["player_slug"], name: "index_goals_on_player_slug"
    t.index ["slug"], name: "index_goals_on_slug", unique: true
    t.index ["team_slug"], name: "index_goals_on_team_slug"
  end

  create_table "image_caches", force: :cascade do |t|
    t.string "owner_type", null: false
    t.bigint "owner_id", null: false
    t.string "purpose", null: false
    t.string "variant", null: false
    t.string "s3_key", null: false
    t.string "source_url"
    t.integer "bytes"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id", "purpose", "variant"], name: "idx_image_caches_owner_purpose_variant", unique: true
    t.index ["owner_type", "owner_id"], name: "index_image_caches_on_owner"
    t.index ["s3_key"], name: "index_image_caches_on_s3_key", unique: true
  end

  create_table "pending_transactions", force: :cascade do |t|
    t.string "tx_type", null: false
    t.text "serialized_tx", null: false
    t.string "status", default: "pending", null: false
    t.string "target_type"
    t.bigint "target_id"
    t.string "initiator_address"
    t.string "cosigner_address"
    t.string "tx_signature"
    t.jsonb "metadata", default: {}
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_pending_transactions_on_slug", unique: true
    t.index ["status"], name: "index_pending_transactions_on_status"
    t.index ["target_type", "target_id"], name: "index_pending_transactions_on_target"
  end

  create_table "players", force: :cascade do |t|
    t.string "slug", null: false
    t.string "team_slug"
    t.string "name", null: false
    t.string "position"
    t.integer "jersey_number"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_players_on_slug", unique: true
    t.index ["team_slug"], name: "index_players_on_team_slug"
  end

  create_table "selections", force: :cascade do |t|
    t.bigint "entry_id", null: false
    t.bigint "slate_matchup_id", null: false
    t.decimal "points", precision: 5, scale: 1
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entry_id", "slate_matchup_id"], name: "index_selections_on_entry_id_and_slate_matchup_id", unique: true
    t.index ["entry_id"], name: "index_selections_on_entry_id"
    t.index ["slate_matchup_id"], name: "index_selections_on_slate_matchup_id"
    t.index ["slug"], name: "index_selections_on_slug", unique: true
  end

  create_table "slate_matchups", force: :cascade do |t|
    t.bigint "slate_id", null: false
    t.string "team_slug", null: false
    t.string "opponent_team_slug"
    t.string "game_slug"
    t.integer "rank"
    t.decimal "turf_score", precision: 3, scale: 1
    t.integer "goals"
    t.string "status", default: "pending", null: false
    t.decimal "dk_goals_expectation", precision: 3, scale: 1
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["game_slug"], name: "index_slate_matchups_on_game_slug"
    t.index ["slate_id", "team_slug"], name: "index_slate_matchups_on_slate_id_and_team_slug", unique: true
    t.index ["slate_id"], name: "index_slate_matchups_on_slate_id"
    t.index ["slug"], name: "index_slate_matchups_on_slug", unique: true
    t.index ["status"], name: "index_slate_matchups_on_status"
  end

  create_table "slates", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "starts_at"
    t.float "formula_a"
    t.float "formula_line_exp"
    t.float "formula_prob_exp"
    t.float "formula_mult_base"
    t.float "formula_mult_scale"
    t.float "formula_goal_base"
    t.float "formula_goal_scale"
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_slates_on_slug", unique: true
  end

  create_table "teams", force: :cascade do |t|
    t.string "slug", null: false
    t.string "name", null: false
    t.string "short_name"
    t.string "location"
    t.string "emoji"
    t.string "color_primary"
    t.string "color_secondary"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_teams_on_slug", unique: true
  end

  create_table "theme_settings", force: :cascade do |t|
    t.string "app_name", null: false
    t.string "primary"
    t.string "accent1"
    t.string "accent2"
    t.string "warning"
    t.string "danger"
    t.string "dark"
    t.string "light"
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_name"], name: "index_theme_settings_on_app_name", unique: true
  end

  create_table "transaction_logs", force: :cascade do |t|
    t.string "transaction_type", null: false
    t.integer "amount_cents", null: false
    t.string "direction", null: false
    t.integer "balance_after_cents"
    t.bigint "user_id", null: false
    t.string "source_type"
    t.bigint "source_id"
    t.string "source_name"
    t.string "description"
    t.string "status", default: "completed", null: false
    t.string "onchain_tx"
    t.jsonb "metadata", default: {}
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_transaction_logs_on_slug", unique: true
    t.index ["source_type", "source_id"], name: "index_transaction_logs_on_source_type_and_source_id"
    t.index ["status"], name: "index_transaction_logs_on_status"
    t.index ["transaction_type"], name: "index_transaction_logs_on_transaction_type"
    t.index ["user_id", "status"], name: "index_transaction_logs_on_user_id_and_status"
    t.index ["user_id", "transaction_type"], name: "index_transaction_logs_on_user_id_and_type"
    t.index ["user_id"], name: "index_transaction_logs_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "name"
    t.string "email"
    t.string "username"
    t.string "first_name"
    t.string "last_name"
    t.date "birth_date"
    t.integer "birth_year"
    t.string "password_digest", default: "", null: false
    t.string "provider"
    t.string "uid"
    t.string "role", default: "viewer"
    t.integer "level", default: 1, null: false
    t.string "web2_solana_address"
    t.string "web3_solana_address"
    t.text "encrypted_web2_solana_private_key"
    t.bigint "invited_by_id"
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "lower((username)::text)", name: "index_users_on_lower_username", unique: true, where: "(username IS NOT NULL)"
    t.index ["email"], name: "index_users_on_email", unique: true, where: "(email IS NOT NULL)"
    t.index ["invited_by_id"], name: "index_users_on_invited_by_id"
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true, where: "(provider IS NOT NULL)"
    t.index ["slug"], name: "index_users_on_slug", unique: true
    t.index ["web2_solana_address"], name: "index_users_on_web2_solana_address", unique: true, where: "(web2_solana_address IS NOT NULL)"
    t.index ["web3_solana_address"], name: "index_users_on_web3_solana_address", unique: true, where: "(web3_solana_address IS NOT NULL)"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "contests", "slates"
  add_foreign_key "contests", "users"
  add_foreign_key "entries", "contests"
  add_foreign_key "entries", "users"
  add_foreign_key "entry_tokens", "entries"
  add_foreign_key "entry_tokens", "users"
  add_foreign_key "selections", "entries"
  add_foreign_key "selections", "slate_matchups"
  add_foreign_key "slate_matchups", "slates"
  add_foreign_key "transaction_logs", "users"
  add_foreign_key "users", "users", column: "invited_by_id"
end
