require "test_helper"

# Render smoke for the cdp-ramp additions to the admin modal gallery:
#   - /admin/modals lists the "CDP ramp (Coinbase)" variant group
#   - /admin/modals/preview/cdp-ramp renders through the modal_preview
#     layout (which now ships shared/_alpine_factories so cdpRampFlow —
#     inline-only, no importmap duplicate — exists in the iframe).
class CdpPreviewSmokeTest < ActionDispatch::IntegrationTest
  test "admin modal gallery lists the CDP ramp group" do
    log_in_as users(:alex)
    get admin_modals_path
    assert_response :success
    assert_includes response.body, "CDP ramp (Coinbase)"
    assert_includes response.body, "modals/_cdp_ramp.html.erb"
  end

  test "cdp-ramp preview renders via the modal_preview layout with the factory inline" do
    log_in_as users(:alex)
    get admin_modal_preview_path(
      modal_id: "cdp-ramp",
      props: { flow: "sell", step: "send", walletMode: "web2", demoCountdownMinutes: 27 }.to_json
    )
    assert_response :success
    assert_includes response.body, "window.cdpRampFlow"
    assert_includes response.body, "Send your USDC to Coinbase"
  end
end
