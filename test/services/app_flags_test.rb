require "test_helper"

class AppFlagsTest < ActiveSupport::TestCase
  # AppFlags reads ENV directly — save/restore the var around each case.
  def with_env(value)
    original = ENV["ENABLE_TEST_SCAFFOLDING"]
    set_env(value)
    yield
  ensure
    set_env(original)
  end

  def set_env(value)
    if value.nil?
      ENV.delete("ENABLE_TEST_SCAFFOLDING")
    else
      ENV["ENABLE_TEST_SCAFFOLDING"] = value
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
end
