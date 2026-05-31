require "test_helper"

# v0.17 added `lock_timestamp: i64` and v0.18 added `conclusion_timestamp: i64`
# to the on-chain Contest (both carved out of _reserved, after `bump`).
# read_contest decodes byte-by-byte with hardcoded offsets, so this round-trips
# a hand-built Contest buffer to guard against offset drift — the named risk
# when the account layout bumps.
class Solana::VaultReadContestLockTest < ActiveSupport::TestCase
  # Build a Borsh Contest account buffer matching the v0.18 field order.
  def build_contest_buffer(lock_timestamp:, conclusion_timestamp: 0, status: 0)
    disc       = "\x00".b * 8                                  # anchor discriminator
    contest_id = "\x01".b * 32
    admin      = "\x02".b * 32
    creator    = "\x03".b * 32
    season_id  = [1].pack("L<")                                # u32
    prize_pool = [1_000_000].pack("Q<")                        # u64
    fee_by_cur = ([19_000_000] + [0] * 15).pack("Q<*")         # [u64;16]
    fees       = ([0] * 16).pack("Q<*")                        # [u64;16]
    max_e      = [29].pack("L<")                               # u32
    cur_e      = [3].pack("L<")                                # u32
    st         = [status].pack("C")                            # u8
    payouts    = [2].pack("L<") + [300_000_000, 50_000_000].pack("Q<*") # Vec<u64>
    bump       = [254].pack("C")                               # u8
    lock       = [lock_timestamp].pack("q<")                   # i64
    conclusion = [conclusion_timestamp].pack("q<")             # i64 (v0.18)
    reserved   = "\x00".b * 16                                 # [u8;16]
    disc + contest_id + admin + creator + season_id + prize_pool +
      fee_by_cur + fees + max_e + cur_e + st + payouts + bump + lock + conclusion + reserved
  end

  def vault_returning(buf)
    b64 = Base64.strict_encode64(buf)
    client = Object.new
    client.define_singleton_method(:get_account_info) do |_pda, commitment: nil|
      { "value" => { "data" => [b64, "base64"] } }
    end
    Solana::Vault.new(client: client)
  end

  test "decodes a non-zero lock_timestamp into lock_timestamp + locks_at" do
    lock_ts = 1_900_000_000
    result  = vault_returning(build_contest_buffer(lock_timestamp: lock_ts)).read_contest("any-slug")

    assert_equal lock_ts, result[:lock_timestamp]
    assert_equal Time.at(lock_ts).utc, result[:locks_at]
    # Offset-drift guard: fields after lock_timestamp's neighbours still decode.
    assert_equal "Open", result[:status]
    assert_equal 3, result[:current_entries]
    assert_equal 29, result[:max_entries]
  end

  test "maps lock_timestamp 0 to a nil locks_at (no scheduled lock)" do
    result = vault_returning(build_contest_buffer(lock_timestamp: 0)).read_contest("any-slug")

    assert_equal 0, result[:lock_timestamp]
    assert_nil result[:locks_at]
  end

  test "decodes conclusion_timestamp into conclusion_timestamp + concludes_at" do
    lock_ts = 1_900_000_000
    conc_ts = 1_900_500_000
    result  = vault_returning(build_contest_buffer(lock_timestamp: lock_ts, conclusion_timestamp: conc_ts)).read_contest("any-slug")

    assert_equal lock_ts, result[:lock_timestamp]
    assert_equal conc_ts, result[:conclusion_timestamp]
    assert_equal Time.at(conc_ts).utc, result[:concludes_at]
    # lock still decodes correctly with the conclusion field between it + reserved.
    assert_equal Time.at(lock_ts).utc, result[:locks_at]
  end

  test "maps conclusion_timestamp 0 to a nil concludes_at" do
    result = vault_returning(build_contest_buffer(lock_timestamp: 1_900_000_000, conclusion_timestamp: 0)).read_contest("any-slug")

    assert_equal 0, result[:conclusion_timestamp]
    assert_nil result[:concludes_at]
  end
end
