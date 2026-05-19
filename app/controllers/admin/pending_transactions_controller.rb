module Admin
  class PendingTransactionsController < ApplicationController
    before_action :require_admin
    before_action :set_pending_transaction, only: [:show, :confirm, :rebuild]

    def index
      @pending = PendingTransaction.order(created_at: :desc)
      @pending_count = PendingTransaction.pending.count
    end

    def show
    end

    def confirm
      rescue_and_log(target: @tx) do
        raise "Transaction is #{@tx.status}, not pending" unless @tx.pending?

        # OPSEC-010 / OPSEC-011: semantic-verify the on-chain TX before
        # flipping DB state. Previously this endpoint accepted any string
        # as tx_signature and marked a contest settled without checking
        # what (if anything) actually landed on-chain. Now we:
        #   1. Confirm cosigner is in the multisig signer set
        #   2. Resolve the instruction + writable PDA from tx_type/target
        #   3. Assert the on-chain TX matches all of (program, instruction,
        #      cosigner-as-signer, target PDA writable)
        cosigner = params[:cosigner_address]
        raise "Cosigner address required" if cosigner.blank?
        raise "Cosigner not in multisig set" unless Solana::Config::MULTISIG_SIGNERS.include?(cosigner)

        instruction_name = instruction_for_tx_type(@tx.tx_type)
        writable_pubkey  = writable_for_target(@tx.target)

        Solana::TxVerifier.verify!(
          signature: params[:tx_signature],
          instruction_name: instruction_name,
          signer_pubkey: cosigner,
          writable_pubkey: writable_pubkey
        )

        @tx.update!(
          status: "confirmed",
          cosigner_address: cosigner,
          tx_signature: params[:tx_signature]
        )

        # Mark contest as settled onchain if target is a Contest
        if @tx.target.is_a?(Contest)
          @tx.target.update!(onchain_settled: true)
        end

        respond_to do |format|
          format.json { render json: { status: "confirmed", tx_signature: @tx.tx_signature } }
          format.html { redirect_to admin_pending_transactions_path, notice: "Transaction confirmed." }
        end
      end
    rescue Solana::TxVerifier::VerificationError => e
      respond_to do |format|
        format.json { render json: { error: e.message }, status: :unprocessable_entity }
        format.html { redirect_to admin_pending_transactions_path, alert: "Verification failed: #{e.message}" }
      end
    rescue StandardError => e
      respond_to do |format|
        format.json { render json: { error: e.message }, status: :unprocessable_entity }
        format.html { redirect_to admin_pending_transactions_path, alert: "Confirmation failed: #{e.message}" }
      end
    end

    def rebuild
      rescue_and_log(target: @tx) do
        raise "Transaction is #{@tx.status}, cannot rebuild" unless @tx.pending?

        settlements = JSON.parse(@tx.metadata)["settlements"].map(&:symbolize_keys)
        vault = Solana::Vault.new
        cosigner = Solana::Config::MULTISIG_COSIGNER
        result = vault.build_settle_contest(@tx.target.slug, settlements, cosigner_pubkey: cosigner)
        @tx.update!(serialized_tx: result[:serialized_tx], status: "pending")

        respond_to do |format|
          format.json { render json: { status: "rebuilt", serialized_tx: result[:serialized_tx] } }
          format.html { redirect_to admin_pending_transactions_path, notice: "Transaction rebuilt with fresh blockhash." }
        end
      end
    rescue StandardError => e
      respond_to do |format|
        format.json { render json: { error: e.message }, status: :unprocessable_entity }
        format.html { redirect_to admin_pending_transactions_path, alert: "Rebuild failed: #{e.message}" }
      end
    end

    private

    def set_pending_transaction
      @tx = PendingTransaction.find_by(slug: params[:slug])
      return redirect_to admin_pending_transactions_path, alert: "Transaction not found" unless @tx
    end

    # Map PendingTransaction#tx_type → Anchor instruction name. Today only
    # settle_contest is used; add cases here as new pending-tx types ship.
    def instruction_for_tx_type(tx_type)
      case tx_type
      when "settle_contest" then "settle_contest"
      else
        raise "Unsupported tx_type for verification: #{tx_type}"
      end
    end

    # Resolve the writable PDA that the TX is expected to mutate. Based on the
    # polymorphic target. For Contest, that's the on-chain contest PDA.
    def writable_for_target(target)
      case target
      when Contest
        target.onchain_contest_id.presence ||
          Solana::Keypair.encode_base58(Solana::Vault.new.contest_pda(target.slug).first)
      else
        nil
      end
    end
  end
end
