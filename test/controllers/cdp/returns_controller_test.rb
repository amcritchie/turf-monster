require "test_helper"

class Cdp::ReturnsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:jordan)
  end

  def with_cdp_ramp(value = "true")
    original = ENV["ENABLE_CDP_RAMP"]
    value.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = original
  end

  def create_ramp(direction: "onramp", status: "token_minted", user: @user, **attrs)
    CdpRampTransaction.create!({
      user: user,
      direction: direction,
      wallet_address: "Wallet#{SecureRandom.hex(4)}",
      wallet_mode: "web2",
      status: status
    }.merge(attrs))
  end

  test "404s when the flag is off" do
    with_cdp_ramp(nil) do
      get cdp_onramp_return_path
      assert_response :not_found
    end
  end

  test "requires authentication (HTML redirect to signin)" do
    with_cdp_ramp do
      get cdp_onramp_return_path
      assert_redirected_to signin_path
    end
  end

  test "onramp return marks the row returned and schedules the onramp poll" do
    with_cdp_ramp do
      ramp = create_ramp
      log_in_as @user

      get cdp_onramp_return_path
      assert_response :success

      ramp.reload
      assert ramp.returned?
      assert ramp.returned_at.present?

      job = enqueued_jobs.find { |j| j[:job] == Cdp::OnrampPollJob }
      assert job, "expected Cdp::OnrampPollJob to be enqueued"
      assert_equal ramp.id, job[:args].first["ramp_id"]
      assert job[:at].present?, "first poll must be delayed (never poll immediately)"

      # The page carries the data attributes + the JSON config that deep-links
      # the viewer back into the cdp-ramp modal at the row's current step.
      assert_select "#cdp-return[data-partner-user-ref=?]", ramp.partner_user_ref
      assert_select "#cdp-return[data-direction=?]", "onramp"
      assert_select "script#cdp-return-config", count: 1
      config = JSON.parse(css_select("script#cdp-return-config").first.text)
      assert_equal "buy", config["flow"]
      assert_equal "waiting", config["step"]
      assert_equal ramp.partner_user_ref, config["partnerUserRef"]
      assert_equal "web2", config["walletMode"]
    end
  end

  test "offramp return schedules the offramp poll" do
    with_cdp_ramp do
      ramp = create_ramp(direction: "offramp")
      log_in_as @user

      get cdp_offramp_return_path
      assert_response :success

      assert ramp.reload.returned?
      job = enqueued_jobs.find { |j| j[:job] == Cdp::OfframpPollJob }
      assert job, "expected Cdp::OfframpPollJob to be enqueued"
      assert_equal ramp.id, job[:args].first["ramp_id"]
    end
  end

  test "return picks the viewer's most recent ACTIVE row of that direction" do
    with_cdp_ramp do
      create_ramp(status: "success") # terminal — must be skipped
      stale  = create_ramp(created_at: 1.hour.ago)
      latest = create_ramp
      create_ramp(direction: "offramp") # wrong direction
      log_in_as @user

      get cdp_onramp_return_path
      assert_response :success
      assert latest.reload.returned?
      assert stale.reload.token_minted?, "only the newest active row is marked"
    end
  end

  test "return does not downgrade a row that already progressed (UX signal only)" do
    with_cdp_ramp do
      ramp = create_ramp(direction: "offramp", status: "cdp_created")
      log_in_as @user

      get cdp_offramp_return_path
      assert_response :success

      ramp.reload
      assert ramp.cdp_created?, "a return hit must never rewind the lifecycle"
      assert ramp.returned_at.present?
    end
  end

  test "return with no pending session redirects to the wallet" do
    with_cdp_ramp do
      log_in_as @user
      get cdp_onramp_return_path
      assert_redirected_to wallet_path
      assert_match(/couldn't find a pending/, flash[:alert])
    end
  end

  test "status returns the local row state as JSON" do
    with_cdp_ramp do
      ramp = create_ramp(
        direction: "offramp", status: "cdp_created",
        to_address: "CoinbaseAddr111",
        sell_amount_value: BigDecimal("12.34"), sell_amount_currency: "USDC",
        cashout_deadline_at: 25.minutes.from_now
      )
      log_in_as @user

      get cdp_ramp_status_path(partner_user_ref: ramp.partner_user_ref)
      assert_response :success

      json = JSON.parse(response.body)
      assert_equal ramp.partner_user_ref, json["partner_user_ref"]
      assert_equal "offramp", json["direction"]
      assert_equal "web2", json["wallet_mode"]
      assert_equal "cdp_created", json["status"]
      assert_equal false, json["terminal"]
      assert_equal "CoinbaseAddr111", json["to_address"]
      assert_equal "12.34", json["sell_amount"]
      assert json["cashout_deadline_at"].present?
    end
  end

  test "status flags terminal rows so the page poller stops" do
    with_cdp_ramp do
      ramp = create_ramp(status: "success")
      log_in_as @user
      get cdp_ramp_status_path(partner_user_ref: ramp.partner_user_ref)
      assert_equal true, JSON.parse(response.body)["terminal"]
    end
  end

  test "status is scoped to the viewer — another user's ref 404s" do
    with_cdp_ramp do
      other = create_ramp(user: users(:sam))
      log_in_as @user
      get cdp_ramp_status_path(partner_user_ref: other.partner_user_ref)
      assert_response :not_found
    end
  end
end
