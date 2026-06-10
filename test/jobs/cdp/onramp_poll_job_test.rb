require "test_helper"

class Cdp::OnrampPollJobTest < ActiveJob::TestCase
  setup do
    @ramp = CdpRampTransaction.create!(
      user: users(:jordan),
      direction: "onramp",
      wallet_address: "Wallet#{SecureRandom.hex(4)}",
      wallet_mode: "web2",
      status: "returned",
      returned_at: Time.current
    )
    @path = "/onramp/v1/buy/user/#{@ramp.partner_user_ref}/transactions"
  end

  def perform_with(client, attempt: 0)
    Cdp::Client.stub :new, client do
      Cdp::OnrampPollJob.perform_now(ramp_id: @ramp.id, attempt: attempt)
    end
  end

  def reenqueued_job
    enqueued_jobs.find { |j| j[:job] == Cdp::OnrampPollJob }
  end

  test "polls with page_size 50 (server default is 1) and re-enqueues on IN_PROGRESS" do
    tx = { "transaction_id" => "cb-tx-1", "status" => "ONRAMP_TRANSACTION_STATUS_IN_PROGRESS" }
    client = FakeCdpClient.new({ @path => { "transactions" => [tx] } })

    perform_with(client)

    path, params = client.calls.first
    assert_equal @path, path
    assert_equal 50, params[:page_size]

    @ramp.reload
    assert_equal "cb-tx-1", @ramp.coinbase_transaction_id
    assert_equal "ONRAMP_TRANSACTION_STATUS_IN_PROGRESS", @ramp.cdp_status
    assert @ramp.returned?, "local lifecycle unchanged while CDP is in progress"

    job = reenqueued_job
    assert job, "expected the poll loop to continue"
    assert_equal @ramp.id, job[:args].first["ramp_id"]
    assert_equal 1, job[:args].first["attempt"]
    # Backoff step 1 = 30s.
    assert_in_delta 30.seconds.from_now.to_f, job[:at], 5
  end

  test "backoff clamps to the 5-minute ceiling on later attempts" do
    tx = { "transaction_id" => "cb-tx-1", "status" => "ONRAMP_TRANSACTION_STATUS_IN_PROGRESS" }
    client = FakeCdpClient.new({ @path => { "transactions" => [tx] } })

    perform_with(client, attempt: 17)

    job = reenqueued_job
    assert_equal 18, job[:args].first["attempt"]
    assert_in_delta 5.minutes.from_now.to_f, job[:at], 5
  end

  test "an empty transactions list keeps polling" do
    client = FakeCdpClient.new({ @path => { "transactions" => [] } })
    perform_with(client)
    assert reenqueued_job
    assert @ramp.reload.returned?
  end

  test "unwraps a data-nested response (open question 8)" do
    tx = { "transaction_id" => "cb-tx-9", "status" => "ONRAMP_TRANSACTION_STATUS_IN_PROGRESS" }
    client = FakeCdpClient.new({ @path => { "data" => { "transactions" => [tx] } } })
    perform_with(client)
    assert_equal "cb-tx-9", @ramp.reload.coinbase_transaction_id
  end

  test "SUCCESS marks the row success with tx_hash and stops the loop" do
    tx = {
      "transaction_id" => "cb-tx-1",
      "status" => "ONRAMP_TRANSACTION_STATUS_SUCCESS",
      "tx_hash" => "5ig" + ("a" * 20),
      "payment_method" => "CARD"
    }
    client = FakeCdpClient.new({ @path => { "transactions" => [tx] } })

    perform_with(client)

    @ramp.reload
    assert @ramp.success?
    assert_equal tx["tx_hash"], @ramp.tx_hash
    assert_equal "CARD", @ramp.payment_method
    assert_equal tx, @ramp.raw_payload
    assert_nil reenqueued_job, "terminal state must stop the poll loop"
  end

  test "FAILED marks the row failed and stops" do
    tx = { "transaction_id" => "cb-tx-1", "status" => "ONRAMP_TRANSACTION_STATUS_FAILED" }
    client = FakeCdpClient.new({ @path => { "transactions" => [tx] } })
    perform_with(client)
    assert @ramp.reload.failed?
    assert_nil reenqueued_job
  end

  test "an unknown CDP status is stored verbatim and polling continues (defensive)" do
    tx = { "transaction_id" => "cb-tx-1", "status" => "ONRAMP_TRANSACTION_STATUS_SOMETHING_NEW" }
    client = FakeCdpClient.new({ @path => { "transactions" => [tx] } })

    perform_with(client)

    @ramp.reload
    assert_equal "ONRAMP_TRANSACTION_STATUS_SOMETHING_NEW", @ramp.cdp_status
    assert @ramp.returned?, "unknown statuses never move the local lifecycle"
    assert reenqueued_job
  end

  test "a terminal row stops immediately — no API call, no re-enqueue" do
    @ramp.update!(status: "success")
    client = FakeCdpClient.new
    perform_with(client)
    assert_empty client.calls
    assert_nil reenqueued_job
  end

  test "a deleted row stops the loop quietly" do
    ramp_id = @ramp.id
    @ramp.destroy!
    client = FakeCdpClient.new
    Cdp::Client.stub :new, client do
      Cdp::OnrampPollJob.perform_now(ramp_id: ramp_id)
    end
    assert_empty client.calls
    assert_nil reenqueued_job
  end

  test "deadline + grace with nothing at CDP expires the session and stops" do
    @ramp.update!(returned_at: 2.hours.ago)
    client = FakeCdpClient.new

    perform_with(client)

    assert @ramp.reload.expired?
    assert_empty client.calls, "no API call after the window closes"
    assert_nil reenqueued_job
  end

  test "a CDP API error is captured to ErrorLog and the cadence continues" do
    client = FakeCdpClient.new({}, raise_error: Cdp::Client::ApiError.new("CDP 503: flaky"))

    assert_difference "ErrorLog.count", 1 do
      perform_with(client)
    end

    log = ErrorLog.last
    assert_equal "CdpRampTransaction", log.target_type
    assert_equal @ramp.id, log.target_id
    assert_equal "User", log.parent_type
    assert reenqueued_job, "a flaky CDP response must not kill the poll loop"
  end

  test "an unexpected fault is captured to ErrorLog before the retry machinery takes over" do
    client = FakeCdpClient.new({}, raise_error: RuntimeError.new("bug"))
    assert_difference "ErrorLog.count", 1 do
      perform_with(client)
    end
    assert_equal "CdpRampTransaction", ErrorLog.last.target_type
  end
end
