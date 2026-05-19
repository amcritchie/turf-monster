# Local extension of Solana::Client (from solana-studio gem) to add getProgramAccounts.
# Upstream to the gem after the free-entries epic ships — see
# memory/project_turf_monster_free_entries_onchain.md.
Solana::Client.class_eval do
  # getProgramAccounts RPC — discover all program accounts, optionally filtered.
  # filters: array of memcmp/dataSize filter objects, e.g.
  #   [{ memcmp: { offset: 8, bytes: owner_base58 } }]
  # Returns array of { "pubkey" => "...", "account" => { "data" => [b64, "base64"], ... } }
  def get_program_accounts(program_id, filters: [], commitment: "confirmed", encoding: "base64")
    send(:call, "getProgramAccounts", [
      program_id,
      { encoding: encoding, commitment: commitment, filters: filters }
    ])
  end
end
