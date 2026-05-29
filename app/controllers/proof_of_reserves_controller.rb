class ProofOfReservesController < ApplicationController
  skip_before_action :require_authentication

  def show
    @contests = Contest.where(status: [:open, :settled])
                       .where.not(onchain_contest_id: nil)
                       .order(created_at: :desc)

    vault = Solana::Vault.new
    vault_usdc_bytes, _bump = vault.vault_usdc_pda
    @vault_usdc_pubkey = Solana::Keypair.encode_base58(vault_usdc_bytes)

    @page_config = {
      rpc_url:           Solana::Config::RPC_URL,
      program_id:        Solana::Config::PROGRAM_ID,
      usdc_mint:         Solana::Config::USDC_MINT,
      vault_usdc_pubkey: @vault_usdc_pubkey,
      network:           Solana::Config::NETWORK,
      contests:          @contests.map { |c| contest_payload(c) }
    }
  end

  private

  def contest_payload(c)
    {
      slug:                 c.slug,
      name:                 c.name,
      contest_pda:          c.onchain_contest_id,
      create_tx_signature:  c.onchain_tx_signature,
      created_label:        c.created_at.strftime("%B %Y")
    }
  end
end
