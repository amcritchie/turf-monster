require "test_helper"

class AppFlagsTest < ActiveSupport::TestCase
  # AppFlags reads ENV directly — save/restore the var around each case.
  def with_env(value, var: "ENABLE_TEST_SCAFFOLDING")
    original = ENV[var]
    set_env(value, var)
    yield
  ensure
    set_env(original, var)
  end

  def set_env(value, var = "ENABLE_TEST_SCAFFOLDING")
    if value.nil?
      ENV.delete(var)
    else
      ENV[var] = value
    end
  end

  test "test_scaffolding? is false when the env var is unset" do
    with_env(nil) { assert_not AppFlags.test_scaffolding? }
  end

  test "test_scaffolding? is true only for a 'true' value" do
    with_env("true")   { assert AppFlags.test_scaffolding? }
    with_env("TRUE")   { assert AppFlags.test_scaffolding? }
    with_env(" true ") { assert AppFlags.test_scaffolding? }
    with_env("false")  { assert_not AppFlags.test_scaffolding? }
    with_env("1")      { assert_not AppFlags.test_scaffolding? }
    with_env("")       { assert_not AppFlags.test_scaffolding? }
  end

  test "cdp_ramp? is false when the env var is unset (kill-switch default)" do
    with_env(nil, var: "ENABLE_CDP_RAMP") { assert_not AppFlags.cdp_ramp? }
  end

  test "cdp_ramp? is true only for a 'true' value" do
    with_env("true", var: "ENABLE_CDP_RAMP")   { assert AppFlags.cdp_ramp? }
    with_env("TRUE", var: "ENABLE_CDP_RAMP")   { assert AppFlags.cdp_ramp? }
    with_env(" true ", var: "ENABLE_CDP_RAMP") { assert AppFlags.cdp_ramp? }
    with_env("false", var: "ENABLE_CDP_RAMP")  { assert_not AppFlags.cdp_ramp? }
    with_env("1", var: "ENABLE_CDP_RAMP")      { assert_not AppFlags.cdp_ramp? }
    with_env("", var: "ENABLE_CDP_RAMP")       { assert_not AppFlags.cdp_ramp? }
  end
end
