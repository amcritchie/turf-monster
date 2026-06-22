require "minitest/autorun"
require_relative "../../../lib/turf_monster/host_config"

class TurfMonster::HostConfigTest < Minitest::Test
  def test_aliases_strips_blanks_and_ignores_empty_entries
    aliases = TurfMonster::HostConfig.aliases(" app.turfmonster.media, ,www.turfmonster.media ")

    assert_equal [ "app.turfmonster.media", "www.turfmonster.media" ], aliases
  end

  def test_public_hosts_keeps_canonical_host_first_and_removes_duplicates
    hosts = TurfMonster::HostConfig.public_hosts(
      app_host: "turfmonster.media",
      aliases: [ "app.turfmonster.media", "turfmonster.media" ]
    )

    assert_equal [ "turfmonster.media", "app.turfmonster.media" ], hosts
  end

  def test_allowed_https_origins_matches_exact_https_origins
    origins = TurfMonster::HostConfig.allowed_https_origins([
      "turfmonster.media",
      "app.turfmonster.media"
    ])

    assert origins.any? { |origin| origin.match?("https://turfmonster.media") }
    assert origins.any? { |origin| origin.match?("https://app.turfmonster.media") }
    assert origins.none? { |origin| origin.match?("http://turfmonster.media") }
    assert origins.none? { |origin| origin.match?("https://evil-turfmonster.media") }
  end
end
