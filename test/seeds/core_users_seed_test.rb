require "test_helper"

class CoreUsersSeedTest < ActiveSupport::TestCase
  ALEX_WALLET = "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr".freeze

  test "core user seed adopts an existing wallet-created parked identity row" do
    users(:alex).update!(email: "fixture-admin@example.com")
    wallet_user = User.create!(username: "mcritchie", web3_solana_address: ALEX_WALLET)

    silence_warnings { load Rails.root.join("db/seeds/users.rb") }
    seeded = seed_core_users!.fetch("mcritchie")

    assert_equal wallet_user.id, seeded.id
    seeded.reload
    assert_equal "admin", seeded.role
    assert_equal "alex@mcritchie.studio", seeded.email
    assert_equal "Mr. McRitchie", seeded.name
    assert_equal ALEX_WALLET, seeded.web3_solana_address
  end
end
