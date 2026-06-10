require "test_helper"

class GeoSettingTest < ActiveSupport::TestCase
  test "DEFAULT_BANNED_STATES includes CA (2025 CA AG opinion) alongside the DFS-prohibited set" do
    %w[WA ID MT LA AZ HI NV CA].each do |code|
      assert_includes GeoSetting::DEFAULT_BANNED_STATES, code
    end
  end

  test "effective_banned_states falls back to the defaults when no row is provisioned" do
    assert_not GeoSetting.current.persisted?, "precondition: no GeoSetting fixture"
    assert_equal GeoSetting::DEFAULT_BANNED_STATES.sort, GeoSetting.effective_banned_states
  end

  test "effective_banned_states reads the persisted row — published policy tracks enforcement" do
    GeoSetting.create!(app_name: Studio.app_name, enabled: true, banned_states: %w[NY CA NY])
    assert_equal %w[CA NY], GeoSetting.effective_banned_states, "sorted + deduped row list"
  end

  test "blocked? enforces the persisted row" do
    GeoSetting.create!(app_name: Studio.app_name, enabled: true, banned_states: %w[CA])
    assert GeoSetting.blocked?("CA")
    assert_not GeoSetting.blocked?("CO")
  end
end
