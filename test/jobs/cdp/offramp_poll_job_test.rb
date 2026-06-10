require "test_helper"

class Cdp::OfframpPollJobTest < ActiveJob::TestCase
  setup do
    @ramp = CdpRampTransaction.create!(
      user: users(:jordan),
      direction: "offramp",
      wallet_address: "Wallet#{SecureRandom.hex(4)}",
      wallet_mode: "web2",
      status: "returned",
      returned_at: Time.current
    )
    @path = "/onramp/v1/sell/user/#{@ramp.partner_user_ref}/transactions"
  end

  def perform_with(client, attempt: 0)
    Cdp::Client.stub :new, client do
      Cdp::OfframpPollJob.perform_now(ramp_id: @ramp.id, attempt: attempt)
    end
  end

  def reenqueued_job
    enqueued_jobs.find { |j| j[:job] == Cdp::OfframpPollJob }
  end

  def created_tx(overrides = {})
    {
      "transaction_id" => "cb-sell-1",
      "status" => "TRANSACTION_STATUS_CREATED",
      "to_address" => "CoinbaseManagedAddr111",
      "sell_amount" => { "value" => "12.34", "currency" => "USDC" },
      "network" => "solana",
      "created_at" => "2026-06-09T15:00:00Z"
    }.merge(overrides)
  end

  test "polls the sell endpoint with page_size 50" do
    client = FakeCdpClient.new({ @path => { "transactions" => [] } })
    perform_with(client)
    path, params = client.calls.first
    assert_equal @path, path
    assert_equal 50, params[:page_size]
    assert reenqueued_job
  end

  test "first CREATED row persists to_address / sell_amount / network and starts the 30-minute window (§10 discovery)" do
    client = FakeCdpClient.new({ @path => { "transactions" => [created_tx] } })

    perform_with(client)

    @ramp.reload
    assert @ramp.cdp_created?
    assert_equal "cb-sell-1", @ramp.coinbase_transaction_id
    assert_equal "CoinbaseManagedAddr111", @ramp.to_address
    assert_equal BigDecimal("12.34"), @ramp.sell_amount
    assert_kind_of BigDecimal, @ramp.sell_amount
    assert_equal "USDC", @ramp.sell_amount_currency
    assert_equal "solana", @ramp.network
    assert_equal Time.zone.parse("2026-06-09T15:00:00Z") + 30.minutes, @ramp.cashout_deadline_at
    assert reenqueued_job, "cdp_created is not terminal — keep polling for settlement"
  end

  test "discovery is idempotent — a second CREATED poll never rewrites the bound values" do
    @ramp.update!(
      status: "cdp_created",
      coinbase_transaction_id: "cb-sell-1",
      to_address: "OriginalAddr",
      sell_amount_value: BigDecimal("12.34"),
      sell_amount_currency: "USDC",
      cashout_deadline_at: 10.minutes.from_now
    )
    original_deadline = @ramp.cashout_deadline_at
    client = FakeCdpClient.new({ @path => { "transactions" => [created_tx("to_address" => "DifferentAddr")] } })

    perform_with(client)

    @ramp.reload
    assert_equal "OriginalAddr", @ramp.to_address
    assert_in_delta original_deadline.to_f, @ramp.cashout_deadline_at.to_f, 1
  end

  test "discovery still runs when the first poll already sees STARTED" do
    client = FakeCdpClient.new({ @path => { "transactions" => [created_tx("status" => "TRANSACTION_STATUS_STARTED")] } })

    perform_with(client)

    @ramp.reload
    assert_equal "CoinbaseManagedAddr111", @ramp.to_address
    assert @ramp.cashout_deadline_at.present?
    assert @ramp.returned?, "STARTED does not advance the local lifecycle (send flow owns sending/sent)"
    assert reenqueued_job
  end

  test "a CREATED row missing created_at falls back to now for the deadline" do
    client = FakeCdpClient.new({ @path => { "transactions" => [created_tx("created_at" => nil)] } })
    perform_with(client)
    assert_in_delta 30.minutes.from_now.to_f, @ramp.reload.cashout_deadline_at.to_f, 10
  end

  test "SUCCESS marks the row success and stops" do
    client = FakeCdpClient.new({ @path => { "transactions" => [created_tx("status" => "TRANSACTION_STATUS_SUCCESS", "tx_hash" => "abc123")] } })
    perform_with(client)
    @ramp.reload
    assert @ramp.success?
    assert_equal "abc123", @ramp.tx_hash
    assert_nil reenqueued_job
  end

  test "FAILED (incl. late sends) marks the row failed and stops" do
    client = FakeCdpClient.new({ @path => { "transactions" => [created_tx("status" => "TRANSACTION_STATUS_FAILED")] } })
    perform_with(client)
    assert @ramp.reload.failed?
    assert_nil reenqueued_job
  end

  test "EXPIRED marks the row expired and stops" do
    client = FakeCdpClient.new({ @path => { "transactions" => [created_tx("status" => "TRANSACTION_STATUS_EXPIRED")] } })
    perform_with(client)
    assert @ramp.reload.expired?
    assert_nil reenqueued_job
  end

  test "an unknown status is stored verbatim and polling continues (the enum conflicts across doc pages)" do
    client = FakeCdpClient.new({ @path => { "transactions" => [created_tx("status" => "TRANSACTION_STATUS_BRAND_NEW")] } })
    perform_with(client)
    @ramp.reload
    assert_equal "TRANSACTION_STATUS_BRAND_NEW", @ramp.cdp_status
    assert reenqueued_job
  end

  test "a row carrying a DIFFERENT transaction_id than the bound one is ignored" do
    @ramp.update!(coinbase_transaction_id: "cb-sell-1", status: "cdp_created", to_address: "OriginalAddr")
    client = FakeCdpClient.new({ @path => {
      "transactions" => [created_tx("transaction_id" => "cb-sell-OTHER", "status" => "TRANSACTION_STATUS_SUCCESS")]
    } })

    perform_with(client)

    @ramp.reload
    assert @ramp.cdp_created?, "a mismatched row must not flip our lifecycle"
    assert_equal "cb-sell-1", @ramp.coinbase_transaction_id
    assert reenqueued_job
  end

  test "past cashout deadline + grace in cdp_created: stop polling but leave the status for the sweep" do
    @ramp.update!(status: "cdp_created", to_address: "Addr", cashout_deadline_at: 1.hour.ago)
    client = FakeCdpClient.new

    perform_with(client)

    assert @ramp.reload.cdp_created?, "never auto-expire a row CDP knows about — funds may be in flight"
    assert_empty client.calls
    assert_nil reenqueued_job
  end

  test "past deadline + grace with nothing at CDP expires the session" do
    @ramp.update!(returned_at: 2.hours.ago)
    client = FakeCdpClient.new
    perform_with(client)
    assert @ramp.reload.expired?
    assert_nil reenqueued_job
  end
end
