require "test_helper"

# Allow-list semantics for the IDL hash pin (audit OPSEC-014). EXPECTED_IDL_HASH
# is a comma-separated set so bin/deploy can widen it to {old,new} across a
# release boundary and tighten back to {new} with no unverified window. These
# guard the single comparison primitive every caller (verify_idl!, the rakes,
# bin/deploy mirrored in bash) shares.
class Solana::ConfigIdlHashTest < ActiveSupport::TestCase
  test "expected_idl_hashes parses a single hash" do
    assert_equal ["abc123"], Solana::Config.expected_idl_hashes("abc123")
  end

  test "expected_idl_hashes parses a comma set, trimming whitespace + blanks" do
    assert_equal %w[aaa bbb], Solana::Config.expected_idl_hashes(" aaa , bbb ,,")
  end

  test "expected_idl_hashes returns [] for blank / nil" do
    assert_equal [], Solana::Config.expected_idl_hashes("")
    assert_equal [], Solana::Config.expected_idl_hashes("   ")
    assert_equal [], Solana::Config.expected_idl_hashes(nil)
  end

  test "idl_hash_acceptable? matches any member of the set" do
    Solana::Config.stub(:expected_idl_hashes, %w[aaa bbb]) do
      assert Solana::Config.idl_hash_acceptable?("aaa"), "old hash should pass during the widen window"
      assert Solana::Config.idl_hash_acceptable?("bbb"), "new hash should pass during the widen window"
      refute Solana::Config.idl_hash_acceptable?("ccc"), "a third (poisoned) IDL must NOT pass"
    end
  end

  test "idl_hash_acceptable? is false for blank / nil regardless of set" do
    Solana::Config.stub(:expected_idl_hashes, %w[aaa]) do
      refute Solana::Config.idl_hash_acceptable?("")
      refute Solana::Config.idl_hash_acceptable?(nil)
    end
  end

  test "idl_hash_acceptable? is false when the set is empty (unset pin)" do
    Solana::Config.stub(:expected_idl_hashes, []) do
      refute Solana::Config.idl_hash_acceptable?("anything")
    end
  end
end
