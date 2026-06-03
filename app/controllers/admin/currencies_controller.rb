module Admin
  # On-chain currency registry admin screen (turf-vault accepted_currencies).
  #
  # register_currency / deactivate_currency / sweep_operator_revenue are all
  # 2-of-3 multisig: the bot signs server-side as `admin`; the cosigner slot is
  # left for a Phantom wallet. Rather than a synchronous direct-cosign (like the
  # pause/unpause emergency screen), these queue a PendingTransaction so the
  # operator cosigns them later from the Treasury — same flow as settlement.
  class CurrenciesController < ApplicationController
    before_action :require_admin

    # 16-slot accepted_currencies registry from VaultState. Rescues RPC errors
    # to a friendly empty state so a blip never 500s the admin page.
    def index
      vault = Solana::Vault.new
      @vault_state = vault.read_vault_state
      @currencies  = @vault_state ? @vault_state[:accepted_currencies] : []
      @treasury_authority = @vault_state && @vault_state[:treasury_authority]
      @default_cosigner   = Solana::Config::MULTISIG_COSIGNER
    rescue StandardError => e
      Rails.logger.warn("[admin/currencies] read_vault_state failed: #{e.message}")
      @vault_state = nil
      @currencies  = []
      @rpc_error   = e.message
    end

    # Build a partially-signed register_currency TX + queue it for cosign.
    def register
      rescue_and_log do
        mint = params[:mint].to_s.strip
        kind = params[:kind].to_i
        raise "Mint address required" if mint.blank?
        raise "Invalid mint pubkey" unless valid_base58_pubkey?(mint)
        raise "Kind must be 0 or 1" unless [0, 1].include?(kind)

        # Preflight against the on-chain registry so we don't queue a 2-of-3
        # cosign for a TX the program will reject (6023 already-registered /
        # 6024 registry-full).
        slots = registered_slots
        raise "Currency #{mint[0..7]}… is already registered" if slots.any? { |c| c[:mint] == mint }
        raise "Currency registry is full (all 16 slots used)" if slots.size >= 16

        vault  = Solana::Vault.new
        result = vault.build_register_currency(
          cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER,
          mint: mint,
          kind: kind
        )

        PendingTransaction.create!(
          tx_type: "register_currency",
          serialized_tx: result[:serialized_tx],
          target: nil,
          initiator_address: Solana::Keypair.admin.to_base58,
          metadata: { mint: mint, kind: kind, op_rev_ata: result[:op_rev_ata] }.to_json
        )

        redirect_to admin_pending_transactions_path,
          notice: "register_currency queued for cosign in the Treasury."
      end
    rescue StandardError => e
      redirect_to admin_currencies_path, alert: "Register failed: #{e.message}"
    end

    # Build a partially-signed deactivate_currency TX + queue it for cosign.
    def deactivate
      rescue_and_log do
        idx = params[:idx].to_i
        raise "Currency slot out of range" unless (0..15).cover?(idx)

        # Preflight: the slot must be populated AND currently active, else the
        # program reverts (6025 invalid-index / 6026 not-active) after cosign.
        slot = registered_slots.find { |c| c[:slot].to_i == idx }
        raise "Slot #{idx} is empty — nothing to deactivate" unless slot
        raise "Slot #{idx} is already inactive" unless slot[:active]  # boolean from read_vault_state

        vault  = Solana::Vault.new
        result = vault.build_deactivate_currency(
          cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER,
          currency_idx: idx
        )

        PendingTransaction.create!(
          tx_type: "deactivate_currency",
          serialized_tx: result[:serialized_tx],
          target: nil,
          initiator_address: Solana::Keypair.admin.to_base58,
          metadata: { currency_idx: idx }.to_json
        )

        redirect_to admin_pending_transactions_path,
          notice: "deactivate_currency (slot #{idx}) queued for cosign in the Treasury."
      end
    rescue StandardError => e
      redirect_to admin_currencies_path, alert: "Deactivate failed: #{e.message}"
    end

    # Build a partially-signed sweep_operator_revenue TX + queue it for cosign.
    # Preflight: the treasury ATA must exist and the op_rev ATA must hold a
    # positive balance. amount: 0 sweeps the whole op_rev ATA.
    def sweep
      rescue_and_log do
        mint = params[:mint].to_s.strip
        raise "Mint address required" if mint.blank?
        raise "Invalid mint pubkey" unless valid_base58_pubkey?(mint)

        vault = Solana::Vault.new

        treasury_ata = vault.treasury_ata_for(mint)
        info = vault.client.get_account_info(treasury_ata)
        raise "Treasury ATA does not exist for this mint (create it first)" unless info&.dig("value")

        op_rev_ata = Solana::Keypair.encode_base58(vault.op_rev_ata_pda(mint).first)
        balance = vault.client.get_token_account_balance(op_rev_ata)
        amount_raw = balance&.dig("value", "amount").to_i
        raise "Nothing to sweep — operator revenue ATA balance is 0" if amount_raw.zero?

        result = vault.build_sweep_operator_revenue(
          cosigner_pubkey: Solana::Config::MULTISIG_COSIGNER,
          currency_mint: mint,
          treasury_ata_pubkey: treasury_ata,
          amount: 0
        )

        PendingTransaction.create!(
          tx_type: "sweep_operator_revenue",
          serialized_tx: result[:serialized_tx],
          target: nil,
          initiator_address: Solana::Keypair.admin.to_base58,
          metadata: { currency_mint: mint, treasury_ata: treasury_ata, amount: 0 }.to_json
        )

        redirect_to admin_pending_transactions_path,
          notice: "sweep_operator_revenue queued for cosign in the Treasury."
      end
    rescue StandardError => e
      redirect_to admin_currencies_path, alert: "Sweep failed: #{e.message}"
    end

    private

    # Slots in VaultState.accepted_currencies that hold a real mint (registered,
    # whether active or deactivated). Reads on-chain; raises on RPC failure
    # (caught by each action's outer rescue).
    def registered_slots
      state = Solana::Vault.new.read_vault_state
      return [] unless state
      (state[:accepted_currencies] || []).select do |c|
        c[:mint].present? && c[:mint] != "11111111111111111111111111111111"
      end
    end

    def valid_base58_pubkey?(str)
      Solana::Keypair.decode_base58(str).bytesize == 32
    rescue StandardError
      false
    end
  end
end
