require "test_helper"

class ContestCreateJsTest < ActiveSupport::TestCase
  test "contest create serializes Phantom partial signature for server cosign" do
    source = File.read(Rails.root.join("app/views/contests/new.html.erb"))

    refute_includes source, "signedTx.serialize().length"
    assert_includes source, "signedTx.serialize({ requireAllSignatures: false, verifySignatures: false })"
  end
end
