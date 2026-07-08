# frozen_string_literal: true

# Model-page protocol registry (studio-engine). Declares which turf models are
# reachable at the admin-only /models/:model/:id inspector (record JSON + a
# copy/paste rails-console command, drawn into this app by Studio.routes).
# Registered in a `to_prepare` block so the engine's class-level registry is
# repopulated on every Zeitwerk code reload in development.
#
# IMPORTANT: the engine renders `record.as_json` — ALL columns. Only models whose
# full column set is safe to expose to an admin are registered here. Payment /
# wallet / transaction models (User's encrypted_web2_solana_private_key +
# session_token + PII, PaypalPurchase/StripePurchase payment IDs,
# PendingTransaction#serialized_tx, CdpRampTransaction#raw_payload,
# TransactionLog) are intentionally NOT registered until they get an as_json
# attribute filter — a deliberate follow-up. Entry/Contest/Game/Player carry only
# public on-chain identifiers, so they are safe as-is.
Rails.application.config.to_prepare do
  Studio::ModelPage.register("entry",   Entry,   lookup: :slug)
  Studio::ModelPage.register("contest", Contest, lookup: :slug)
  Studio::ModelPage.register("game",    Game,    lookup: :slug)
  Studio::ModelPage.register("player",  Player,  lookup: :slug)
end
