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

  # OPSEC-039: getGenesisHash RPC — returns the configured cluster's genesis
  # block hash. We compare against pinned mainnet/devnet hashes at boot to
  # detect SOLANA_RPC_URL ↔ SOLANA_NETWORK ↔ SOLANA_PROGRAM_ID misalignment
  # (e.g., a mainnet-shaped program ID + devnet RPC URL would silently boot
  # otherwise). See config/initializers/solana_network_alignment.rb.
  def get_genesis_hash
    send(:call, "getGenesisHash", [])
  end
end
