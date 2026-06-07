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

ActiveRecord::Schema[7.2].define(version: 2026_06_06_120000) do
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
    t.integer "season_id"
    t.boolean "chat_enabled", default: true, null: false
    t.string "game_type", default: "turf_totals", null: false
    t.datetime "concludes_at"
    t.boolean "onchain_closed", default: false, null: false
    t.boolean "onchain_cancelled", default: false, null: false
    t.index ["game_type"], name: "index_contests_on_game_type"
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
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "eliminated_round"
    t.datetime "winner_notified_at"
    t.index ["contest_id", "status"], name: "index_entries_on_contest_id_and_status"
    t.index ["contest_id"], name: "index_entries_on_contest_id"
    t.index ["onchain_tx_signature"], name: "index_entries_on_onchain_tx_signature_unique", unique: true, where: "(onchain_tx_signature IS NOT NULL)"
    t.index ["slug"], name: "index_entries_on_slug", unique: true
    t.index ["status"], name: "index_entries_on_status"
    t.index ["user_id", "contest_id", "entry_number"], name: "index_entries_on_user_contest_entry_number", unique: true, where: "(entry_number IS NOT NULL)"
    t.index ["user_id", "contest_id"], name: "index_entries_on_user_id_and_contest_id"
    t.index ["user_id"], name: "index_entries_on_user_id"
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
    t.bigint "survivor_round_id"
    t.string "advancing_team_slug"
    t.index ["away_team_slug"], name: "index_games_on_away_team_slug"
    t.index ["home_team_slug"], name: "index_games_on_home_team_slug"
    t.index ["slug"], name: "index_games_on_slug", unique: true
    t.index ["status"], name: "index_games_on_status"
    t.index ["survivor_round_id"], name: "index_games_on_survivor_round_id"
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

  create_table "landing_pages", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug"
    t.string "headline"
    t.text "subheadline"
    t.string "cta_label"
    t.bigint "contest_id"
    t.boolean "active", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "background_style", default: "gradient", null: false
    t.string "badge"
    t.index ["contest_id"], name: "index_landing_pages_on_contest_id"
    t.index ["slug"], name: "index_landing_pages_on_slug", unique: true
  end

  create_table "magic_links", force: :cascade do |t|
    t.string "token", null: false
    t.string "email", null: false
    t.string "return_to"
    t.datetime "expires_at", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_magic_links_on_expires_at"
    t.index ["token"], name: "index_magic_links_on_token", unique: true
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "contest_id", null: false
    t.bigint "user_id", null: false
    t.text "body", null: false
    t.datetime "hidden_at"
    t.bigint "hidden_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "system", default: false, null: false
    t.index ["contest_id", "created_at"], name: "index_messages_on_contest_id_and_created_at"
    t.index ["contest_id", "user_id", "system"], name: "index_messages_on_contest_user_system", where: "system"
    t.index ["hidden_by_id"], name: "index_messages_on_hidden_by_id", where: "(hidden_by_id IS NOT NULL)"
    t.index ["user_id"], name: "index_messages_on_user_id"
  end

  create_table "outbound_requests", force: :cascade do |t|
    t.string "service", null: false
    t.string "method"
    t.string "endpoint"
    t.jsonb "request_body", default: {}
    t.jsonb "response_body", default: {}
    t.integer "status_code"
    t.integer "duration_ms"
    t.string "error_class"
    t.text "error_message"
    t.string "source_type"
    t.bigint "source_id"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_outbound_requests_on_created_at"
    t.index ["error_class"], name: "index_outbound_requests_on_error_class", where: "(error_class IS NOT NULL)"
    t.index ["service", "created_at"], name: "index_outbound_requests_on_service_and_created_at"
    t.index ["source_type", "source_id"], name: "index_outbound_requests_on_source_type_and_source_id"
    t.index ["user_id"], name: "index_outbound_requests_on_user_id", where: "(user_id IS NOT NULL)"
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
    t.index ["tx_signature"], name: "index_pending_transactions_on_tx_signature_unique", unique: true, where: "(tx_signature IS NOT NULL)"
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

  create_table "reactions", force: :cascade do |t|
    t.bigint "message_id", null: false
    t.bigint "user_id", null: false
    t.string "emoji", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id", "user_id", "emoji"], name: "index_reactions_uniqueness", unique: true
    t.index ["message_id"], name: "index_reactions_on_message_id"
    t.index ["user_id"], name: "index_reactions_on_user_id"
  end

  create_table "season_configs", force: :cascade do |t|
    t.integer "current_season_id", default: 0, null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "main_contest_id"
    t.index ["main_contest_id"], name: "index_season_configs_on_main_contest_id"
    t.index ["slug"], name: "index_season_configs_on_slug", unique: true
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

  create_table "stripe_purchases", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "stripe_customer_id"
    t.string "stripe_session_id", null: false
    t.string "stripe_charge_id"
    t.integer "quantity", default: 1, null: false
    t.integer "price_cents", null: false
    t.string "status", default: "pending", null: false
    t.text "mint_tx_signatures"
    t.datetime "minted_at"
    t.datetime "refunded_at"
    t.string "refund_reason"
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_stripe_purchases_on_slug", unique: true
    t.index ["stripe_session_id"], name: "index_stripe_purchases_on_stripe_session_id", unique: true
    t.index ["user_id"], name: "index_stripe_purchases_on_user_id"
  end

  create_table "survivor_picks", force: :cascade do |t|
    t.bigint "entry_id", null: false
    t.bigint "survivor_round_id", null: false
    t.string "team_slug", null: false
    t.string "result", default: "pending", null: false
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entry_id", "survivor_round_id"], name: "index_survivor_picks_on_entry_and_round", unique: true
    t.index ["entry_id", "team_slug"], name: "index_survivor_picks_on_entry_and_team", unique: true
    t.index ["entry_id"], name: "index_survivor_picks_on_entry_id"
    t.index ["slug"], name: "index_survivor_picks_on_slug", unique: true
    t.index ["survivor_round_id"], name: "index_survivor_picks_on_survivor_round_id"
    t.index ["team_slug"], name: "index_survivor_picks_on_team_slug"
  end

  create_table "survivor_rounds", force: :cascade do |t|
    t.integer "number", null: false
    t.string "name", null: false
    t.string "stage", default: "group", null: false
    t.datetime "picks_lock_at"
    t.string "status", default: "upcoming", null: false
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["number"], name: "index_survivor_rounds_on_number", unique: true
    t.index ["slug"], name: "index_survivor_rounds_on_slug", unique: true
    t.index ["status"], name: "index_survivor_rounds_on_status"
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
    t.string "stripe_session_id"
    t.string "moonpay_tx_id"
    t.index ["moonpay_tx_id"], name: "index_transaction_logs_on_moonpay_tx_id_unique", unique: true, where: "(moonpay_tx_id IS NOT NULL)"
    t.index ["slug"], name: "index_transaction_logs_on_slug", unique: true
    t.index ["source_type", "source_id"], name: "index_transaction_logs_on_source_type_and_source_id"
    t.index ["status"], name: "index_transaction_logs_on_status"
    t.index ["stripe_session_id"], name: "index_transaction_logs_on_stripe_session_id_unique", unique: true, where: "(stripe_session_id IS NOT NULL)"
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
    t.datetime "email_verified_at"
    t.string "session_token"
    t.boolean "payment_risk_flag", default: false, null: false
    t.string "reference"
    t.datetime "frozen_at"
    t.string "frozen_reason"
    t.boolean "contest_entered", default: false, null: false
    t.integer "invitees_count", default: 0, null: false
    t.integer "invitees_in_contest_count", default: 0, null: false
    t.datetime "export_initiated_at"
    t.datetime "self_custodied_at"
    t.datetime "username_changed_at"
    t.datetime "joined_email_list_at"
    t.datetime "left_email_list_at"
    t.jsonb "ips", default: {}, null: false
    t.datetime "first_chat_message_at"
    t.index "lower((username)::text)", name: "index_users_on_lower_username", unique: true, where: "(username IS NOT NULL)"
    t.index ["contest_entered"], name: "index_users_on_contest_entered_true", where: "(contest_entered = true)"
    t.index ["email"], name: "index_users_on_email", unique: true, where: "(email IS NOT NULL)"
    t.index ["frozen_at"], name: "index_users_on_frozen_at", where: "(frozen_at IS NOT NULL)"
    t.index ["invited_by_id"], name: "index_users_on_invited_by_id"
    t.index ["ips"], name: "index_users_on_ips", using: :gin
    t.index ["joined_email_list_at"], name: "index_users_on_joined_email_list_at"
    t.index ["left_email_list_at"], name: "index_users_on_left_email_list_at"
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true, where: "(provider IS NOT NULL)"
    t.index ["reference"], name: "index_users_on_reference"
    t.index ["self_custodied_at"], name: "index_users_on_self_custodied_at"
    t.index ["session_token"], name: "index_users_on_session_token"
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
  add_foreign_key "games", "survivor_rounds"
  add_foreign_key "landing_pages", "contests", on_delete: :nullify
  add_foreign_key "messages", "contests"
  add_foreign_key "messages", "users"
  add_foreign_key "reactions", "messages"
  add_foreign_key "reactions", "users"
  add_foreign_key "season_configs", "contests", column: "main_contest_id", on_delete: :nullify
  add_foreign_key "selections", "entries"
  add_foreign_key "selections", "slate_matchups"
  add_foreign_key "slate_matchups", "slates"
  add_foreign_key "stripe_purchases", "users"
  add_foreign_key "survivor_picks", "entries"
  add_foreign_key "survivor_picks", "survivor_rounds"
  add_foreign_key "transaction_logs", "users"
  add_foreign_key "users", "users", column: "invited_by_id"
end
