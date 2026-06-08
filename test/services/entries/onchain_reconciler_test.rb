require "test_helper"

# Entries::OnchainReconciler heals on-chain-paid entries that were stranded in
# `cart` by a post-broadcast Entry#confirm! failure (incident 2026-06-08,
# entry #133). FakeVault is shared — see test/support/fake_vault.rb.
class Entries::OnchainReconcilerTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one) # paid ($19), open, standard
    # On-chain + a configured season + a FUTURE lock time (not locked).
    @contest.update!(onchain_contest_id: "onchain-reconcile", season_id: 1, starts_at: 1.day.from_now)
    SeasonConfig.set_current!(1)

    @user = users(:sam)
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedReconcile#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )

    @matchups = %i[m1 m2 m3 m4 m5 m6].map { |k| slate_matchups(k) }
  end

  def cart_entry_with_picks(**attrs)
    entry = @contest.entries.create!(user: @user, status: :cart, **attrs)
    @matchups.each { |m| entry.selections.create!(slate_matchup: m) }
    entry
  end

  # FAST path: the durable-capture write already stamped the consume signature
  # on the cart entry. The reconciler just re-runs confirm! — no RPC needed.
  test "reconciles a cart entry that already carries a consume signature" do
    entry = cart_entry_with_picks(
      onchain_tx_signature: "consume-sig-fast",
      onchain_entry_id: "epda-fast",
      entry_number: 0
    )

    outcome = Entries::OnchainReconciler.reconcile_entry(entry, vault: FakeVault.new)

    assert_equal :reconciled, outcome
    assert entry.reload.active?, "entry should converge to active"
    assert_equal "consume-sig-fast", entry.onchain_tx_signature, "the consume proof must be preserved (token not lost)"
  end

  # Idempotency: re-running must never double-enter or double-charge.
  test "is idempotent — a second run is a no-op once the entry is active" do
    entry = cart_entry_with_picks(
      onchain_tx_signature: "consume-sig-idem",
      onchain_entry_id: "epda-idem",
      entry_number: 0
    )

    assert_equal :reconciled, Entries::OnchainReconciler.reconcile_entry(entry, vault: FakeVault.new)
    fee_logs_after_first = TransactionLog.where(source: @contest, transaction_type: "entry_fee").count

    # Re-run: already active → skipped, no new fee log, still exactly one entry.
    assert_equal :skipped, Entries::OnchainReconciler.reconcile_entry(entry, vault: FakeVault.new)
    assert entry.reload.active?
    assert_equal fee_logs_after_first,
                 TransactionLog.where(source: @contest, transaction_type: "entry_fee").count,
                 "re-running must not double-charge"
    assert_equal 1, @contest.entries.where(user: @user, status: [:active, :complete]).count
  end

  # PROBE path: a LEGACY strand (e.g. #133) has no proof on the Rails row. The
  # reconciler derives the Entry PDA, confirms it exists on-chain, and recovers
  # the consume signature from getSignaturesForAddress.
  test "probes the chain for the Entry PDA + recovers the consume signature when the row has no proof" do
    entry = cart_entry_with_picks(entry_number: nil)

    wallet = @user.solana_address
    # FakeVault#entry_pda returns ["epda-<slug>-<wallet[0,4]>-<n>", 255]; with
    # encode_base58 stubbed to identity the b58 PDA IS that string.
    pda0 = "epda-#{@contest.slug}-#{wallet[0, 4]}-0"
    vault = FakeVault.new(
      account_infos: { pda0 => { "value" => { "owner" => "prog" } } },
      signatures:    { pda0 => [{ "signature" => "recovered-consume-sig", "err" => nil }] }
    )

    outcome = nil
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      outcome = Entries::OnchainReconciler.reconcile_entry(entry, vault: vault)
    end

    assert_equal :reconciled, outcome
    entry.reload
    assert entry.active?
    assert_equal "recovered-consume-sig", entry.onchain_tx_signature
    assert_equal pda0, entry.onchain_entry_id
  end

  # N1 (PR #115 review): a heal failure must record an ErrorLog that names WHICH
  # entry/contest failed to converge — not a context-free backtrace.
  test "a heal failure records an ErrorLog with entry + contest context" do
    entry = cart_entry_with_picks(
      onchain_tx_signature: "consume-sig-err",
      onchain_entry_id: "epda-err",
      entry_number: 0
    )

    outcome = nil
    entry.stub :confirm!, ->(*, **) { raise StandardError, "simulated heal failure" } do
      outcome = Entries::OnchainReconciler.reconcile_entry(entry, vault: FakeVault.new)
    end

    assert_equal :error, outcome
    log = ErrorLog.where(target: entry).order(:id).last
    assert log, "a heal failure must create an ErrorLog"
    assert_equal entry.slug, log.target_name
    assert_equal @contest, log.parent
    assert_equal @contest.slug, log.parent_name
    assert_match "simulated heal failure", log.message
  end

  test "skips an entry that is already active" do
    entry = cart_entry_with_picks(onchain_tx_signature: "sig-x", entry_number: 0)
    entry.update!(status: :active)

    assert_equal :skipped, Entries::OnchainReconciler.reconcile_entry(entry, vault: FakeVault.new)
  end

  test "skips when no on-chain Entry PDA exists for the wallet" do
    entry = cart_entry_with_picks(entry_number: nil)

    # FakeVault with empty account_infos → every probed PDA reads absent.
    vault = FakeVault.new
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      assert_equal :skipped, Entries::OnchainReconciler.reconcile_entry(entry, vault: vault)
    end
    assert entry.reload.cart?
  end

  test "never credits a probed signature already bound to another entry" do
    wallet = @user.solana_address
    pda0 = "epda-#{@contest.slug}-#{wallet[0, 4]}-0"

    # An already-healed active entry owns the consume signature (onchain_entry_id
    # left nil so the per-slot claim check can't catch it — exercises the
    # signature-uniqueness backstop specifically).
    existing = cart_entry_with_picks(onchain_tx_signature: "dup-consume-sig", entry_number: 0)
    existing.update!(status: :active)

    # A stray cart entry with no proof on the row that would probe the SAME PDA.
    stray = cart_entry_with_picks(entry_number: nil)

    vault = FakeVault.new(
      account_infos: { pda0 => { "value" => { "owner" => "prog" } } },
      signatures:    { pda0 => [{ "signature" => "dup-consume-sig", "err" => nil }] }
    )

    outcome = nil
    Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
      outcome = Entries::OnchainReconciler.reconcile_entry(stray, vault: vault)
    end

    assert_equal :skipped, outcome
    assert stray.reload.cart?, "must not credit a signature already bound to another entry"
  end
end
