class AddAgeAttestation < ActiveRecord::Migration[7.2]
  def change
    # Underwriting compliance (2026-06): every NEW account must attest legal
    # age at signup (18+ in most states; 19+ in AL/NE; 21+ in IA/MA/VA).
    # Enforcement is at the controller boundary of each account-creation flow
    # (magic link / Google OAuth / Solana wallet / legacy POST /signup), NOT a
    # model validation — existing users grandfather with a NULL timestamp and
    # seeds/fixtures/admin tooling are unaffected.
    add_column :users, :age_attested_at, :datetime

    # The email magic-link flow attests at REQUEST time (the checkbox on the
    # auth card), but the account is created at CONSUME time (clicking the
    # emailed link) — so the attestation rides inside the single-use link row.
    add_column :magic_links, :age_attested, :boolean, default: false, null: false
  end
end
