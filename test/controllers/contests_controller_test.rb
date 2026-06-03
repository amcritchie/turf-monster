require "test_helper"
require "minitest/mock"

class ContestsControllerTest < ActionDispatch::IntegrationTest
  # FakeVault is shared — see test/support/fake_vault.rb (LW1 extraction).
  setup do
    @contest = contests(:one)
    @user = users(:sam)
    @m1 = slate_matchups(:m1)
    @m2 = slate_matchups(:m2)
    @m3 = slate_matchups(:m3)
    @m4 = slate_matchups(:m4)
    @m5 = slate_matchups(:m5)
    @m6 = slate_matchups(:m6)
  end

  # --- update_banner tests ---

  test "update_banner attaches a new banner and refreshes the edit-screen preview" do
    log_in_as(users(:alex)) # admin

    assert_changes -> { @contest.reload.contest_image.attached? }, from: false, to: true do
      patch banner_contest_path(@contest),
        params: { contest: { contest_image: fixture_file_upload("banner.png", "image/png") } },
        as: :turbo_stream
    end

    assert_response :success
    assert_match "contest-banner-preview", response.body
  end

  test "update_banner rejects a non-image file and does not attach" do
    log_in_as(users(:alex)) # admin

    patch banner_contest_path(@contest),
      params: { contest: { contest_image: fixture_file_upload("not_an_image.txt", "text/plain") } },
      as: :turbo_stream

    assert_response :redirect
    assert_not @contest.reload.contest_image.attached?
  end

  test "update_banner is admin-only" do
    log_in_as(@user) # sam — not an admin

    patch banner_contest_path(@contest),
      params: { contest: { contest_image: fixture_file_upload("banner.png", "image/png") } }

    assert_response :redirect
    assert_not @contest.reload.contest_image.attached?
  end

  test "admin sees the Edit banner control on the edit screen" do
    log_in_as(users(:alex))
    get edit_contest_path(@contest)
    assert_response :success
    assert_match "Edit banner", response.body
    assert_match "contest-banner-form", response.body # the banner editor's own form
  end

  # --- toggle_selection tests ---

  test "toggle_selection creates entry and selection on first toggle" do
    log_in_as(@user)

    assert_difference ["Entry.count", "Selection.count"], 1 do
      post toggle_selection_contest_path(@contest),
        params: { matchup_id: @m1.id },
        as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal({ @m1.id.to_s => true }, json["selections"])
    assert_equal 1, json["selection_count"]
  end

  test "toggle_selection removes selection when toggled again" do
    log_in_as(@user)

    entry = @contest.entries.create!(user: @user, status: :cart)
    entry.selections.create!(slate_matchup: @m1)

    assert_difference "Selection.count", -1 do
      post toggle_selection_contest_path(@contest),
        params: { matchup_id: @m1.id },
        as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal({}, json["selections"])
    assert_equal 0, json["selection_count"]
    # Entry should be destroyed when empty
    assert_not Entry.exists?(entry.id)
  end

  test "toggle_selection requires authentication" do
    post toggle_selection_contest_path(@contest),
      params: { matchup_id: @m1.id },
      as: :json

    # JSON requests get a clean 401 (which solana_utils.authedFetch turns into
    # the login modal). Previously the engine's require_authentication did a
    # blind redirect_to login_path even on AJAX, which Rails responded to with
    # 406 Not Acceptable — silent failure for the client.
    assert_response :unauthorized
    assert_equal "unauthenticated", JSON.parse(response.body)["error"]
  end

  # --- enter (confirm) tests ---

  test "enter confirms cart entry with JSON" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(contest),
      headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert json["redirect"]
    assert entry.reload.active?
  end

  test "enter with JSON redirects when no cart entry" do
    log_in_as(@user)

    post enter_contest_path(@contest),
      headers: { "Accept" => "application/json" }

    assert_response :redirect
  end

  test "enter requires authentication" do
    post enter_contest_path(@contest)

    assert_response :redirect
    assert_redirected_to signin_path
  end

  test "enter with HTML redirects on success" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(contest)

    assert_response :redirect
    assert_redirected_to contest_path(contest)
  end

  # --- join announcement (chat) on confirmed entry ---

  test "enter posts a single join announcement to chat on first confirmed entry" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    assert_difference -> { contest.messages.system_messages.count }, 1 do
      post enter_contest_path(contest), headers: { "Accept" => "application/json" }
    end

    assert_response :success
    announcement = contest.messages.system_messages.find_by(user: @user)
    assert announcement.present?
    assert_includes announcement.body, @user.display_name
    assert_includes announcement.body, "joined the contest"
  end

  test "enter does NOT re-announce when the user already has a join announcement" do
    log_in_as(@user)
    contest = free_contest

    # Simulate the user's first confirmed entry having already announced them
    # (the fixtures only carry 6 matchups, so a second DISTINCT 6-combo — which
    # the Sybil check requires — can't be built here; pre-seeding the
    # announcement exercises the same controller idempotency boundary).
    Message.announce_join!(contest: contest, user: @user)
    assert_equal 1, contest.messages.system_messages.where(user: @user).count

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    assert_no_difference -> { contest.messages.system_messages.count } do
      post enter_contest_path(contest), headers: { "Accept" => "application/json" }
    end
    assert_response :success
    assert entry.reload.active?
  end

  test "enter posts no join announcement when chat is disabled" do
    log_in_as(@user)
    contest = free_contest
    contest.update!(chat_enabled: false)

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    assert_no_difference "Message.count" do
      post enter_contest_path(contest), headers: { "Accept" => "application/json" }
    end
    assert_response :success
    assert entry.reload.active?
  end

  # --- post_entry_seeds_payload tests ---
  #
  # The shared seeds-payload helper extracted in the R1 refactor is the
  # single place that emits the `[entry][confirmed]` log line + busts the
  # navbar seeds/USDC caches after a confirmed entry. These tests pin that
  # contract so the structured log line stays grep-able in prod and the
  # caches actually get invalidated.

  test "enter emits structured [entry][confirmed] log on success" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    captured = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(captured)
    begin
      post enter_contest_path(contest), headers: { "Accept" => "application/json" }
    ensure
      Rails.logger = original_logger
    end

    assert_response :success
    log = captured.string
    assert_match(/\[entry\]\[confirmed\] path=managed/, log)
    assert_match(/user_id=#{@user.id}/, log)
    assert_match(/entry_id=#{entry.id}/, log)
    assert_match(/contest=#{contest.slug}/, log)
    assert_match(/seeds_earned=\d+/, log)
    assert_match(/seeds_total=\d+/, log)
    assert_match(/seeds_level=\d+/, log)
    assert_match(/token_consumed=/, log)
  end

  test "enter invalidates seeds and USDC caches on success for solana-connected user" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    # Pre-populate both caches with sentinels so we can verify they got cleared.
    Rails.cache.write("user_seeds:#{@user.id}", { seeds: 999 })
    Rails.cache.write("usdc_balance:#{@user.id}", 999.0)

    post enter_contest_path(contest), headers: { "Accept" => "application/json" }

    assert_response :success
    assert_nil Rails.cache.read("user_seeds:#{@user.id}"),
               "seeds cache should be cleared after a successful entry"
    assert_nil Rails.cache.read("usdc_balance:#{@user.id}"),
               "USDC cache should be cleared after a successful entry"
  end

  # --- onchain session entry tests ---

  test "enter rejects onchain session without signature" do
    key = log_in_as_onchain(@user)

    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(@contest),
      headers: { "Accept" => "application/json" }

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/Wallet signature required/, json["error"])
    assert entry.reload.cart?
  end

  test "enter accepts onchain session with valid signature" do
    key = log_in_as_onchain(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    signed_params = sign_entry_message(key, @user, contest.name)

    post enter_contest_path(contest),
      params: signed_params,
      as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert entry.reload.active?
  end

  test "enter rejects onchain session with wrong wallet" do
    key = log_in_as_onchain(@user)

    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    # Sign with correct key but then change the user's wallet to something else
    signed_params = sign_entry_message(key, @user, @contest.name)
    @user.update!(web3_solana_address: "DifferentWalletAddress1111111111111111111111111")

    post enter_contest_path(@contest),
      params: signed_params,
      as: :json

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/Wallet mismatch/, json["error"])
    assert entry.reload.cart?
  end

  test "enter works for offchain session" do
    log_in_as(@user)
    contest = free_contest

    entry = contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(contest),
      headers: { "Accept" => "application/json" }

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"]
    assert entry.reload.active?
  end

  test "enter rejects a paid contest that is not on-chain" do
    log_in_as(@user)
    # contests(:one) is paid ($19) but has no onchain_contest_id — the exact
    # state that used to hand out a free entry. The payment gate must refuse it.
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    post enter_contest_path(@contest),
      headers: { "Accept" => "application/json" }

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/on-chain/i, json["error"])
    assert entry.reload.cart?, "an unpaid entry must never be activated"
  end

  # --- web2 / managed-wallet token spend ---

  test "enter consumes on-chain token via vault.enter_contest_with_token for managed-wallet users" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: [{ pda: "tpda_1", consumed: false }])
    Solana::Keypair.stub :from_encrypted, "fake-keypair-object" do
      Solana::Vault.stub :new, vault do
        post enter_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert json["success"], "expected entry success, got: #{json["error"]}"
    assert_equal 1, vault.enter_calls.length
    assert_equal :enter_contest_with_token, vault.enter_calls.first[:method]
    assert_equal "tpda_1", vault.enter_calls.first[:token_pda]
    assert entry.reload.active?
  end

  test "enter blocks managed-wallet user with no tokens via 'No entry tokens' error" do
    @user.update!(
      web3_solana_address: nil,
      web2_solana_address: "ManagedAddr#{SecureRandom.hex(4)}",
      encrypted_web2_solana_private_key: "ciphertext"
    )
    @contest.update!(onchain_contest_id: "onchain123", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new(tokens: [])
    Solana::Vault.stub :new, vault do
      post enter_contest_path(@contest), as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/No entry tokens/, JSON.parse(response.body)["error"])
    assert entry.reload.cart?
    assert_equal 0, vault.enter_calls.length
  end

  # --- prepare_entry tests (web3 single-signature flow) ---

  test "prepare_entry builds the TX + creates a pending PT" do
    @user.update!(web3_solana_address: "Web3PrepWallet#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_prep", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new
    assert_difference "PendingTransaction.count", 1 do
      Solana::Vault.stub :new, vault do
        post prepare_entry_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert body["serialized_tx"].start_with?("FAKE_TX_")
    assert_equal entry.id, body["entry_id"]
    assert body["entry_pda"].start_with?("epda-")
    assert body["ptx_slug"].start_with?("ptx-")

    ptx = PendingTransaction.find_by(slug: body["ptx_slug"])
    assert_equal "pending", ptx.status
    assert_equal "enter_contest", ptx.tx_type
    assert_equal entry, ptx.target
    assert_equal @user.web3_solana_address, ptx.initiator_address
  end

  test "prepare_entry rejects when the session was not Phantom-authenticated" do
    @user.update!(web3_solana_address: "Web3NotOnchain#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_x", season_id: 1)

    log_in_as @user  # email/password login — no session[:onchain]
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    assert_no_difference "PendingTransaction.count" do
      post prepare_entry_contest_path(@contest), as: :json
    end

    assert_response :forbidden
    assert_match(/Phantom session required/, JSON.parse(response.body)["error"])
  end

  test "prepare_entry rejects when there is no cart entry" do
    @user.update!(web3_solana_address: "Web3NoCart#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_y", season_id: 1)
    log_in_as_onchain(@user)

    post prepare_entry_contest_path(@contest), as: :json
    assert_response :unprocessable_entity
    assert_match(/No cart entry/, JSON.parse(response.body)["error"])
  end

  test "prepare_entry rejects when selections are incomplete" do
    @user.update!(web3_solana_address: "Web3Incomp#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_z", season_id: 1)
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2].each { |m| entry.selections.create!(slate_matchup: m) }  # only 2 of 6

    vault = FakeVault.new
    assert_no_difference "PendingTransaction.count" do
      Solana::Vault.stub :new, vault do
        post prepare_entry_contest_path(@contest), as: :json
      end
    end
    assert_response :unprocessable_entity
    assert_match(/Exactly .* selections/, JSON.parse(response.body)["error"])
  end

  # --- confirm_onchain_entry tests ---

  test "confirm_onchain_entry promotes entry to active + marks PT confirmed" do
    @user.update!(web3_solana_address: "Web3Confirm#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_conf", season_id: 1)
    SeasonConfig.set_current!(1)

    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart, entry_number: 0)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: "submitted", tx_signature: "sig-confirm-1",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { entry_pda: "epda-#{@contest.slug}-#{@user.web3_solana_address[0, 4]}-0" }.to_json
    )

    vault = FakeVault.new
    expected_pda = "epda-#{@contest.slug}-#{@user.web3_solana_address[0, 4]}-0"

    # encode_base58 here would normally turn pda bytes into a base58 string;
    # FakeVault.entry_pda returns the string already, so stub encode_base58
    # to pass it through unchanged.
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_onchain_entry_contest_path(@contest),
            params: { tx_signature: "sig-confirm-1", entry_id: entry.id, entry_pda: expected_pda },
            as: :json
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert_equal "sig-confirm-1", body["tx_signature"]
    assert entry.reload.active?
    assert_equal "sig-confirm-1", entry.onchain_tx_signature
    assert_equal "confirmed", ptx.reload.status
  end

  test "confirm_onchain_entry rejects a mismatched client-supplied entry_pda" do
    @user.update!(web3_solana_address: "Web3Mismatch#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_m", season_id: 1)
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart, entry_number: 0)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        post confirm_onchain_entry_contest_path(@contest),
          params: { tx_signature: "sig-attacker", entry_id: entry.id, entry_pda: "epda-attacker-fake" },
          as: :json
      end
    end

    assert_response :unprocessable_entity
    assert_match(/Entry PDA mismatch/, JSON.parse(response.body)["error"])
    assert entry.reload.cart?
  end

  # --- stamp_entry_signature tests ---

  test "stamp_entry_signature flips a pending PT to submitted with the signature" do
    @user.update!(web3_solana_address: "WalletStamp#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest",
      serialized_tx: "fake-stx",
      status: "pending",
      target: entry,
      initiator_address: @user.web3_solana_address
    )

    post stamp_entry_signature_contest_path(@contest),
      params: { ptx_slug: ptx.slug, tx_signature: "sig-abc-123" },
      as: :json

    assert_response :success
    assert JSON.parse(response.body)["success"]
    ptx.reload
    assert_equal "submitted", ptx.status
    assert_equal "sig-abc-123", ptx.tx_signature
  end

  test "stamp_entry_signature refuses a PT belonging to another user" do
    @user.update!(web3_solana_address: "WalletA#{SecureRandom.hex(4)}")
    other_user = users(:jordan)
    other_user.update!(web3_solana_address: "WalletB#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: other_user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest",
      serialized_tx: "fake-stx",
      status: "pending",
      target: entry,
      initiator_address: other_user.web3_solana_address
    )

    post stamp_entry_signature_contest_path(@contest),
      params: { ptx_slug: ptx.slug, tx_signature: "sig-x" },
      as: :json

    assert_response :forbidden
    assert_equal "pending", ptx.reload.status
    assert_nil ptx.tx_signature
  end

  test "stamp_entry_signature 404s when the PT is missing or already confirmed" do
    log_in_as @user

    post stamp_entry_signature_contest_path(@contest),
      params: { ptx_slug: "ptx-nope", tx_signature: "sig" },
      as: :json
    assert_response :not_found
  end

  # --- pendingRecoveryPtxSlug exposure on contest show ---
  #
  # The recovery flow only fires when load_contest_board_data populates
  # @pending_recovery_ptx and the board partial echoes its slug into the
  # board-config JSON block. These tests assert the server-to-client
  # linkage for the four scope cases — present, wrong user, wrong contest,
  # non-pending status.

  def stranded_ptx_for(user:, contest:, status: "pending")
    entry = contest.entries.find_or_create_by!(user: user, status: :cart)
    PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: status, target: entry,
      initiator_address: user.web3_solana_address
    )
  end

  test "contest show exposes pendingRecoveryPtxSlug when the current user has a pending PT here" do
    @user.update!(web3_solana_address: "Web3Show#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_show")
    log_in_as_onchain(@user)
    ptx = stranded_ptx_for(user: @user, contest: @contest)

    get contest_path(@contest)
    assert_response :success
    assert_match(/"pendingRecoveryPtxSlug":"#{ptx.slug}"/, response.body,
                 "expected the board cfg to carry the stranded PT's slug")
  end

  test "contest show does NOT expose a PT belonging to another user" do
    @user.update!(web3_solana_address: "Web3Mine#{SecureRandom.hex(4)}")
    other = users(:jordan)
    other.update!(web3_solana_address: "Web3Theirs#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_x")
    log_in_as_onchain(@user)
    stranded_ptx_for(user: other, contest: @contest)

    get contest_path(@contest)
    assert_match(/"pendingRecoveryPtxSlug":null/, response.body,
                 "another user's stranded PT must not leak into my recovery flow")
  end

  test "contest show does NOT expose a PT for a different contest" do
    @user.update!(web3_solana_address: "Web3Diff#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_a")
    other_contest = Contest.create!(
      name: "Other Onchain", contest_type: @contest.contest_type, slate: @contest.slate,
      status: :open, onchain_contest_id: "onchain_b"
    )
    log_in_as_onchain(@user)
    stranded_ptx_for(user: @user, contest: other_contest)

    get contest_path(@contest)
    assert_match(/"pendingRecoveryPtxSlug":null/, response.body,
                 "a PT on a DIFFERENT contest must not surface as recovery on this one")
  end

  test "contest show does NOT expose a PT that has already resolved (confirmed/failed)" do
    @user.update!(web3_solana_address: "Web3Done#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_done")
    log_in_as_onchain(@user)
    stranded_ptx_for(user: @user, contest: @contest, status: "confirmed")
    stranded_ptx_for(user: @user, contest: @contest, status: "failed")

    get contest_path(@contest)
    assert_match(/"pendingRecoveryPtxSlug":null/, response.body,
                 "only pending/submitted PTs are eligible for client-side recovery")
  end

  # --- recover_pending_entry tests ---

  test "recover_pending_entry returns confirmed for an already-active entry" do
    @user.update!(web3_solana_address: "WalletR1#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :active, onchain_tx_signature: "sig-was-here")
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest",
      serialized_tx: "fake-stx",
      status: "submitted",
      tx_signature: "sig-x",
      target: entry,
      initiator_address: @user.web3_solana_address
    )

    post recover_pending_entry_contest_path(@contest),
      params: { ptx_slug: ptx.slug }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "confirmed", body["status"]
    assert_equal "sig-was-here", body["tx_signature"]
    assert_equal "confirmed", ptx.reload.status
  end

  test "recover_pending_entry marks PT failed when there is no tx_signature stamped" do
    @user.update!(web3_solana_address: "WalletR2#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest",
      serialized_tx: "fake-stx",
      status: "pending",
      target: entry,
      initiator_address: @user.web3_solana_address
    )

    post recover_pending_entry_contest_path(@contest),
      params: { ptx_slug: ptx.slug }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "failed", body["status"]
    assert_match(/did not broadcast/, body["error"])
    assert_equal "failed", ptx.reload.status
  end

  test "recover_pending_entry forbids resolving another user's PT" do
    @user.update!(web3_solana_address: "WalletR3#{SecureRandom.hex(4)}")
    other = users(:jordan)
    other.update!(web3_solana_address: "WalletR4#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: other, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest",
      serialized_tx: "fake-stx",
      status: "submitted",
      tx_signature: "sig-y",
      target: entry,
      initiator_address: other.web3_solana_address
    )

    post recover_pending_entry_contest_path(@contest),
      params: { ptx_slug: ptx.slug }, as: :json

    assert_response :forbidden
    assert_equal "submitted", ptx.reload.status
  end

  test "recover_pending_entry returns missing when no PT matches" do
    @user.update!(web3_solana_address: "WalletR5#{SecureRandom.hex(4)}")
    log_in_as @user

    post recover_pending_entry_contest_path(@contest),
      params: { ptx_slug: "ptx-does-not-exist" }, as: :json

    assert_response :success
    assert_equal "missing", JSON.parse(response.body)["status"]
  end

  test "recover_pending_entry promotes entry + marks PT confirmed when RPC reports confirmed" do
    @user.update!(web3_solana_address: "WalletR6#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: "submitted", tx_signature: "sig-confirmed-1",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { entry_pda: "epda-1" }.to_json
    )

    vault = FakeVault.new(signature_statuses: {
      "sig-confirmed-1" => { "err" => nil, "confirmationStatus" => "confirmed" }
    })
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post recover_pending_entry_contest_path(@contest),
            params: { ptx_slug: ptx.slug }, as: :json
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "confirmed", body["status"]
    assert_equal "sig-confirmed-1", body["tx_signature"]
    assert_equal "confirmed", ptx.reload.status
    assert entry.reload.active?, "expected entry to be promoted to active"
    assert_equal "sig-confirmed-1", entry.onchain_tx_signature
  end

  test "recover_pending_entry rejects an unverified signature (forged/unrelated tx) and leaves entry in cart" do
    @user.update!(web3_solana_address: "WalletR9#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }
    # Attacker stamps a real-but-unrelated finalized signature and a forged
    # entry_pda in the PT metadata.
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: "submitted", tx_signature: "sig-forged-1",
      target: entry, initiator_address: @user.web3_solana_address,
      metadata: { entry_pda: "epda-attacker-controlled" }.to_json
    )

    # RPC reports the signature finalized, but semantic verification must
    # reject it — it is not an enter_contest IX writing to this user's
    # server-derived entry PDA.
    vault = FakeVault.new(signature_statuses: {
      "sig-forged-1" => { "err" => nil, "confirmationStatus" => "finalized" }
    })
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, ->(*_a, **_k) { raise Solana::TxVerifier::VerificationError, "Transaction does not contain a `enter_contest` instruction" } do
          post recover_pending_entry_contest_path(@contest),
            params: { ptx_slug: ptx.slug }, as: :json
        end
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "failed", body["status"]
    assert entry.reload.cart?, "a forged/unverified signature must NOT activate the entry"
    assert_nil entry.onchain_tx_signature
    assert_equal "failed", ptx.reload.status
  end

  test "recover_pending_entry returns processing when RPC doesn't know the signature" do
    @user.update!(web3_solana_address: "WalletR7#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: "submitted", tx_signature: "sig-unknown",
      target: entry, initiator_address: @user.web3_solana_address
    )

    vault = FakeVault.new(signature_statuses: {}) # sig not seeded → RPC returns nil
    Solana::Vault.stub :new, vault do
      post recover_pending_entry_contest_path(@contest),
        params: { ptx_slug: ptx.slug }, as: :json
    end

    assert_response :success
    assert_equal "processing", JSON.parse(response.body)["status"]
    assert_equal "submitted", ptx.reload.status, "processing should not change PT status"
  end

  test "recover_pending_entry marks PT failed when RPC reports an error" do
    @user.update!(web3_solana_address: "WalletR8#{SecureRandom.hex(4)}")
    log_in_as @user
    entry = @contest.entries.create!(user: @user, status: :cart)
    ptx = PendingTransaction.create!(
      tx_type: "enter_contest", serialized_tx: "stx",
      status: "submitted", tx_signature: "sig-errored",
      target: entry, initiator_address: @user.web3_solana_address
    )

    vault = FakeVault.new(signature_statuses: {
      "sig-errored" => { "err" => { "InstructionError" => [0, "Custom"] }, "confirmationStatus" => "confirmed" }
    })
    Solana::Vault.stub :new, vault do
      post recover_pending_entry_contest_path(@contest),
        params: { ptx_slug: ptx.slug }, as: :json
    end

    assert_response :success
    assert_equal "failed", JSON.parse(response.body)["status"]
    assert_equal "failed", ptx.reload.status
    assert entry.reload.cart?, "errored TX should leave entry in cart"
  end

  # --- page load tests ---

  test "index loads" do
    get contests_path
    assert_response :success
  end

  test "show loads" do
    get contest_path(@contest)
    assert_response :success
  end

  test "world_cup redirects to contest show" do
    get root_path
    assert_redirected_to contest_path(@contest)
  end

  test "world_cup redirects to index when no contests" do
    Contest.update_all(status: :pending)
    get root_path
    assert_redirected_to contests_path
  end

  # --- show tests (formerly lobby; merged 2026-05-17) ---

  test "show loads for guest" do
    get contest_path(@contest)
    assert_response :success
  end

  test "show loads for logged in user" do
    log_in_as(@user)
    get contest_path(@contest)
    assert_response :success
  end

  test "show renders matchup board when user not in contest" do
    log_in_as(@user)
    get contest_path(@contest)
    assert_response :success
    assert_select "section" # board renders inline
  end

  test "show shows an entries-closed state in place of Hold to Confirm once the contest is locked" do
    log_in_as(@user)
    # Derived time-lock: starts_at in the past → Contest#locked? is true.
    # update_column skips the onchain lock-time callback (test-only board).
    @contest.update_column(:starts_at, 1.minute.ago)
    assert @contest.reload.locked?, "precondition: contest should be derived-locked"

    get contest_path(@contest)
    assert_response :success
    # Specific to the picks-sidebar gate (the header's countdown also says
    # "Entries closed", so assert the unique closed-state copy instead).
    assert_match "this contest has locked", @response.body
  end

  test "show renders 'Add Nth Entry' link when user already has an entry" do
    log_in_as(@user)
    entry = @contest.entries.create!(user: @user, status: :active)
    [@m1, @m2, @m3, @m4, @m5, @m6].each { |m| entry.selections.create!(slate_matchup: m) }

    get contest_path(@contest)
    assert_response :success
    assert_select "a", text: /Add 2nd Entry/
  end

  test "show redirects for missing contest" do
    get contest_path(id: "nonexistent")
    assert_redirected_to root_path
  end

  # --- generate_bundle (provision setup bundles) ---

  test "generator page renders for admins" do
    log_in_as(users(:alex))
    get generator_contests_path
    assert_response :success
  end

  # generate_bundle is now Phantom-driven (mirrors #create): admin must have a
  # Phantom wallet to provision because their wallet signs the prize-pool USDC
  # transfer. The actual on-chain flow needs Solana RPC + Phantom — covered by
  # the ContestBundle service test for the persistence half.
  test "generate_bundle requires a Phantom wallet" do
    log_in_as(users(:alex))
    assert_no_difference ["Contest.count", "LandingPage.count"] do
      post generate_bundle_contests_path(key: "survivor")
    end
    assert_response :unprocessable_entity
    assert_match(/phantom/i, response.parsed_body["error"].to_s)
  end

  test "generate_bundle is admin-only" do
    log_in_as(@user) # users(:sam) — not an admin
    post generate_bundle_contests_path(key: "survivor")
    assert_response :redirect
    assert_not LandingPage.exists?(slug: "survivor")
  end

  test "finalize_bundle is admin-only" do
    log_in_as(@user) # not an admin
    post finalize_bundle_contests_path
    assert_response :redirect
    assert_not LandingPage.exists?(slug: "survivor")
  end

  test "finalize_bundle rejects a tampered or expired token" do
    log_in_as(users(:alex))
    post finalize_bundle_contests_path, params: { params_token: "garbage", contest_pda: "x", tx_signature: "y" }
    assert_response :unprocessable_entity
    assert_match(/invalid or expired/i, response.parsed_body["error"].to_s)
  end

  # --- admin (operator override view) tests ---

  test "admin view renders show template for admin users" do
    log_in_as(users(:alex))  # admin role per fixtures
    get admin_contest_path(@contest)
    assert_response :success
    # Same content as the regular show page — contest name appears in the header.
    assert_includes response.body, @contest.name
  end

  test "admin view redirects non-admins" do
    log_in_as(@user)  # not admin
    get admin_contest_path(@contest)
    assert_response :redirect
  end

  test "admin view requires authentication" do
    get admin_contest_path(@contest)
    assert_response :redirect
  end

  private

  # --- lock action (derived time-lock, v0.17) ---

  test "lock now sets starts_at to ~now and makes the contest derived-locked" do
    log_in_as(users(:alex))
    travel_to Time.current do
      post lock_contest_path(@contest)
      @contest.reload
      assert_in_delta Time.current.to_i, @contest.starts_at.to_i, 5
      assert @contest.locked?, "contest should read derived-locked once starts_at is now"
    end
  end

  test "lock in 30s schedules a near-future lock that is not yet locked" do
    log_in_as(users(:alex))
    travel_to Time.current do
      post lock_contest_path(@contest, in_seconds: 30)
      @contest.reload
      assert_in_delta 30.seconds.from_now.to_i, @contest.starts_at.to_i, 5
      assert_not @contest.locked?, "a 30s-out lock should not be locked yet"
    end
  end

  test "lock is admin-only" do
    log_in_as(@user) # users(:sam) — not an admin
    original = @contest.starts_at
    post lock_contest_path(@contest)
    assert_response :redirect
    assert_equal original.to_i, @contest.reload.starts_at.to_i, "non-admin must not move the lock time"
  end

  # --- prepare_lock_time / confirm_lock_time (Phantom-signed lock, v0.17) ---

  test "prepare_lock_time builds a Phantom-signable set_contest_lock_time TX" do
    admin = users(:alex)
    admin.update!(web3_solana_address: "Web3Lock#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_lock", season_id: 1)
    SeasonConfig.set_current!(1)
    log_in_as_onchain(admin)

    vault = FakeVault.new
    travel_to Time.current do
      Solana::Vault.stub :new, vault do
        post prepare_lock_time_contest_path(@contest, in_seconds: 30), as: :json
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert body["success"]
      assert body["serialized_tx"].start_with?("FAKE_TX_lock_")
      assert_in_delta 30.seconds.from_now.to_i, body["lock_timestamp"], 5
    end
    assert_equal 1, vault.lock_calls.length
    assert_equal admin.web3_solana_address, vault.lock_calls.first[:admin]
  end

  test "prepare_lock_time rejects a non-Phantom session" do
    admin = users(:alex)
    admin.update!(web3_solana_address: "Web3LockNo#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_lock2")
    log_in_as(admin) # email/password — no onchain session
    post prepare_lock_time_contest_path(@contest, in_seconds: 30), as: :json
    assert_response :forbidden
    assert_match(/Phantom session required/, JSON.parse(response.body)["error"])
  end

  test "prepare_lock_time is admin-only" do
    @user.update!(web3_solana_address: "Web3LockSam#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_lock3")
    log_in_as_onchain(@user) # users(:sam) — not an admin
    post prepare_lock_time_contest_path(@contest, in_seconds: 30)
    assert_response :redirect
  end

  test "confirm_lock_time mirrors starts_at only after verifying the on-chain TX" do
    admin = users(:alex)
    admin.update!(web3_solana_address: "Web3LockC#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_lock4")
    log_in_as_onchain(admin)

    lock_ts = 30.seconds.from_now.to_i
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_lock_time_contest_path(@contest),
            params: { tx_signature: "lock-sig-1", lock_timestamp: lock_ts }, as: :json
        end
      end
    end

    assert_response :success
    assert JSON.parse(response.body)["success"]
    assert_in_delta lock_ts, @contest.reload.starts_at.to_i, 2
  end

  # --- prepare_conclusion_time / confirm_conclusion_time (v0.18) ---

  test "prepare_conclusion_time builds a Phantom-signable set_contest_conclusion_time TX" do
    admin = users(:alex)
    admin.update!(web3_solana_address: "Web3Conc#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_conc", season_id: 1)
    SeasonConfig.set_current!(1)
    log_in_as_onchain(admin)

    vault = FakeVault.new
    travel_to Time.current do
      Solana::Vault.stub :new, vault do
        post prepare_conclusion_time_contest_path(@contest, in_seconds: 60), as: :json
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert body["success"]
      assert body["serialized_tx"].start_with?("FAKE_TX_conclude_")
      assert_in_delta 60.seconds.from_now.to_i, body["conclusion_timestamp"], 5
    end
    assert_equal 1, vault.conclusion_calls.length
  end

  test "prepare_conclusion_time rejects a non-Phantom session" do
    admin = users(:alex)
    admin.update!(web3_solana_address: "Web3ConcNo#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_conc2")
    log_in_as(admin) # email/password — no onchain session
    post prepare_conclusion_time_contest_path(@contest, in_seconds: 60), as: :json
    assert_response :forbidden
    assert_match(/Phantom session required/, JSON.parse(response.body)["error"])
  end

  test "confirm_conclusion_time mirrors concludes_at after verifying the on-chain TX" do
    admin = users(:alex)
    admin.update!(web3_solana_address: "Web3ConcC#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_conc3")
    log_in_as_onchain(admin)

    ts = 60.seconds.from_now.to_i
    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post confirm_conclusion_time_contest_path(@contest),
            params: { tx_signature: "conc-sig-1", conclusion_timestamp: ts }, as: :json
        end
      end
    end

    assert_response :success
    assert JSON.parse(response.body)["success"]
    assert_in_delta ts, @contest.reload.concludes_at.to_i, 2
  end

  # --- #live (active contest page) ---

  test "live renders for a live turf_totals contest + subscribes to the live stream" do
    @contest.update!(starts_at: 1.hour.ago) # contests(:one) — turf_totals, open → live
    get live_contest_path(@contest)
    assert_response :success
    assert_match(/turbo-cable-stream-source/, response.body)
  end

  test "live redirects to show when the contest is not yet live" do
    @contest.update!(starts_at: 1.hour.from_now)
    get live_contest_path(@contest)
    assert_redirected_to contest_path(@contest)
  end

  test "live redirects to show for a survivor contest" do
    survivor = Contest.create!(name: "Survivor Live #{SecureRandom.hex(2)}",
                               game_type: :world_cup_survivor, contest_type: "survivor_wc_free",
                               status: "open", starts_at: 1.hour.ago, rank: 8000 + rand(900))
    get live_contest_path(survivor)
    assert_redirected_to contest_path(survivor)
  end

  # --- Phantom-driven contest creation: precheck hardening + fresh-blockhash rebuild ---
  #
  # #create / #rebuild_create_tx / #finalize are admin-only AND require a Phantom
  # wallet (the creator co-signs the prize-pool USDC transfer). Use a dedicated
  # admin user with a web3 address.
  def admin_phantom
    @admin_phantom ||= User.create!(
      name: "Admin Phantom", username: "admin_phantom", role: :admin,
      email: "admin_phantom@mcritchie.studio",
      web3_solana_address: "AdMiNPhantoM1111111111111111111111111111111"
    )
  end

  # Step 1 of the Phantom create flow: POST /contests, returns the parsed JSON
  # (serialized_tx, contest_pda, slug, params_token). Uses FakeVault with a
  # balance that covers any tier's prize pool.
  def run_create_via_phantom(name:, slug:, contest_type: "tiny", slate_id: slates(:one).id)
    json = nil
    Solana::Vault.stub :new, FakeVault.new(usdc_balance: 100_000.0) do
      post contests_path,
        params: { contest: { name: name, slug: slug, slate_id: slate_id, contest_type: contest_type } },
        as: :json
      json = JSON.parse(response.body)
    end
    json
  end

  # Full Phantom create → finalize flow (steps 1 + 3; the on-chain sign/broadcast
  # in between is the client's job). Returns { create_json:, contest: } where
  # contest is the persisted record. Solana verification is stubbed.
  def create_contest_via_phantom(name:, slug:, contest_type: "tiny", slate_id: slates(:one).id)
    create_json = run_create_via_phantom(name: name, slug: slug, contest_type: contest_type, slate_id: slate_id)
    assert_equal true, create_json["success"], "create step failed: #{create_json.inspect}"

    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post finalize_contests_path, params: {
            params_token: create_json["params_token"],
            contest_pda:  create_json["contest_pda"],
            tx_signature: "sig-#{slug}-#{SecureRandom.hex(2)}"
          }, as: :json
        end
      end
    end
    assert_response :success
    finalize_json = JSON.parse(response.body)
    assert_equal true, finalize_json["success"], "finalize step failed: #{finalize_json.inspect}"

    { create_json: create_json, contest: Contest.find_by!(slug: finalize_json["slug"]) }
  end

  test "create blocks when the USDC balance read fails (RPC exception is a HARD BLOCK, not a $0 pass)" do
    log_in_as(admin_phantom)
    vault = FakeVault.new(usdc_balance_raises: true)

    Solana::Vault.stub :new, vault do
      post contests_path,
        params: { contest: { name: "Blockhash Cup A", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal false, json["success"]
    assert_match(/couldn't verify your USDC balance/i, json["error"])
    # Never reached the TX build — a failed read must short-circuit.
    assert_empty vault.create_contest_calls
  end

  test "create blocks when the USDC balance read returns nil (unreadable response is a HARD BLOCK)" do
    log_in_as(admin_phantom)
    vault = FakeVault.new(usdc_balance: nil) # get_token_account_balance → nil

    Solana::Vault.stub :new, vault do
      post contests_path,
        params: { contest: { name: "Blockhash Cup B", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/couldn't verify your USDC balance/i, json["error"])
    assert_empty vault.create_contest_calls
  end

  test "create blocks with insufficient-USDC message when a readable balance is below the prize pool" do
    log_in_as(admin_phantom)
    vault = FakeVault.new(usdc_balance: 1.0) # $1 readable, tiny needs $45

    Solana::Vault.stub :new, vault do
      post contests_path,
        params: { contest: { name: "Blockhash Cup C", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/Insufficient USDC/i, json["error"])
    assert_empty vault.create_contest_calls
  end

  test "create builds the partial-signed TX when a readable balance covers the prize pool" do
    log_in_as(admin_phantom)
    vault = FakeVault.new(usdc_balance: 100.0) # $100 covers tiny's $45

    Solana::Vault.stub :new, vault do
      post contests_path,
        params: { contest: { name: "Blockhash Cup D", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_equal "FAKE_TX_create_blockhash-cup-d", json["serialized_tx"]
    assert json["params_token"].present?, "create must issue a params_token for rebuild + finalize"
    assert_equal 1, vault.create_contest_calls.length
  end

  # ── name/slug decouple (epic Part A) — create path keys off the manual slug ──

  # THE KEY CASE: two contests with the SAME name but DIFFERENT manual slugs both
  # create successfully through the full Phantom create → finalize flow, and the
  # on-chain contest_id / PDA + serialized_tx derive from the MANUAL slug (not the
  # name). Proves duplicate names no longer collide on slug or on the PDA.
  test "two contests with the same name but different slugs both create; PDA derives from the manual slug" do
    log_in_as(admin_phantom)

    first  = create_contest_via_phantom(name: "World Cup Group A", slug: "wc-group-a-morning", contest_type: "tiny")
    second = create_contest_via_phantom(name: "World Cup Group A", slug: "wc-group-a-evening", contest_type: "tiny")

    # Both persisted, same name, distinct slugs.
    assert first[:contest].persisted?
    assert second[:contest].persisted?
    assert_equal "World Cup Group A", first[:contest].name
    assert_equal "World Cup Group A", second[:contest].name
    assert_equal "wc-group-a-morning", first[:contest].slug
    assert_equal "wc-group-a-evening", second[:contest].slug

    # The on-chain leg keyed off the MANUAL slug, not the (shared) name:
    #   build_create_contest was called with the slug, and the contest_pda /
    #   serialized_tx the client signs both derive from it.
    assert_equal "wc-group-a-morning", first[:create_json]["slug"]
    assert_equal "cpda-wc-group-a-morning", first[:create_json]["contest_pda"]
    assert_equal "FAKE_TX_create_wc-group-a-morning", first[:create_json]["serialized_tx"]
    assert_equal "cpda-wc-group-a-evening", second[:create_json]["contest_pda"]

    # The persisted on-chain id mirrors the slug-derived PDA the TX created.
    assert_equal "cpda-wc-group-a-morning", first[:contest].onchain_contest_id
    assert_equal "cpda-wc-group-a-evening", second[:contest].onchain_contest_id
  end

  test "create blocks a second contest reusing an existing slug (different name)" do
    log_in_as(admin_phantom)
    create_contest_via_phantom(name: "Original", slug: "dup-slug-x", contest_type: "tiny")

    # Same slug, DIFFERENT name → the precheck must refuse before a Phantom
    # signature is burned. The user-facing error keys off the slug, not the name.
    second = run_create_via_phantom(name: "Different Name", slug: "dup-slug-x", contest_type: "tiny")

    assert_response :unprocessable_entity
    assert_equal false, second["success"]
    # Rejected on the slug (the model's uniqueness check fires first), never the
    # name — proving the dup-name guard moved onto the slug.
    assert_match(/slug.*(already|taken)/i, second["error"])
    assert_no_match(/name/i, second["error"])
    assert_nil second["params_token"], "a blocked create must not issue a finalize token"
  end

  # Bundle provisioning (generate_bundle → finalize_bundle) keys the on-chain
  # contest_id/PDA off the bundle spec's EXPLICIT slug, not a name-derived one.
  # The "survivor" bundle has slug "world-cup-survivor-free-roll" but a name of
  # "World Cup Survivor Free Roll" — proving the PDA derives from the slug
  # (FakeVault returns cpda-<slug>), the round-trip persists, and finalize stores
  # that slug-derived PDA as onchain_contest_id.
  test "generate_bundle/finalize_bundle derive the PDA from the bundle's explicit slug" do
    log_in_as(admin_phantom)
    bundle_slug = ContestBundle::ALL["survivor"][:contest][:slug]
    assert_equal "world-cup-survivor-free-roll", bundle_slug

    # Step 1: generate_bundle builds the partially-signed create TX. The
    # contest_pda + serialized_tx + returned slug all derive from the explicit
    # bundle slug (FakeVault: cpda-<slug> / FAKE_TX_create_<slug>).
    gen = nil
    Solana::Vault.stub :new, FakeVault.new(usdc_balance: 100_000.0) do
      post generate_bundle_contests_path(key: "survivor")
      gen = JSON.parse(response.body)
    end
    assert_response :success
    assert_equal true, gen["success"], gen.inspect
    assert_equal bundle_slug, gen["slug"]
    assert_equal "cpda-#{bundle_slug}", gen["contest_pda"]
    assert_equal "FAKE_TX_create_#{bundle_slug}", gen["serialized_tx"]
    assert gen["params_token"].present?

    # Step 3: finalize_bundle persists the Contest + LandingPage. The PDA it
    # verifies + stores is re-derived server-side from the SAME slug (identity
    # encode_base58 stub → cpda-<slug>), so onchain_contest_id matches.
    fin = nil
    Solana::Vault.stub :new, FakeVault.new do
      Solana::Keypair.stub :encode_base58, ->(s) { s.is_a?(String) ? s : s.to_s } do
        Solana::TxVerifier.stub :verify!, true do
          post finalize_bundle_contests_path, params: {
            params_token: gen["params_token"],
            contest_pda:  gen["contest_pda"],
            tx_signature: "sig-bundle-#{SecureRandom.hex(2)}"
          }
        end
      end
    end
    assert_response :success
    fin = JSON.parse(response.body)
    assert_equal true, fin["success"], fin.inspect

    contest = Contest.find_by!(slug: bundle_slug)
    assert_equal bundle_slug, contest.slug
    assert_equal "World Cup Survivor Free Roll", contest.name # slug != parameterized name path; explicit
    assert_equal "cpda-#{bundle_slug}", contest.onchain_contest_id
    assert LandingPage.exists?(slug: "survivor")
  end

  test "rebuild_create_tx re-issues a fresh partial-signed TX from the create params_token" do
    log_in_as(admin_phantom)
    token = nil
    build_vault = FakeVault.new(usdc_balance: 100.0)

    Solana::Vault.stub :new, build_vault do
      post contests_path,
        params: { contest: { name: "Blockhash Cup E", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
      token = JSON.parse(response.body)["params_token"]
    end
    assert token.present?

    # The rebuild call must NOT re-run the precheck (no balance read) — it
    # only re-issues the admin-cosigned TX over a fresh blockhash. A vault with
    # NO balance configured (would block in precheck) still succeeds here.
    rebuild_vault = FakeVault.new
    Solana::Vault.stub :new, rebuild_vault do
      post rebuild_create_tx_contests_path, params: { params_token: token }, as: :json
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal true, json["success"]
    assert_equal "FAKE_TX_create_blockhash-cup-e", json["serialized_tx"]
    assert_equal 1, rebuild_vault.create_contest_calls.length
  end

  test "rebuild_create_tx rejects a token issued to a different user" do
    log_in_as(admin_phantom)
    token = nil
    Solana::Vault.stub :new, FakeVault.new(usdc_balance: 100.0) do
      post contests_path,
        params: { contest: { name: "Blockhash Cup F", slate_id: slates(:one).id, contest_type: "tiny" } },
        as: :json
      token = JSON.parse(response.body)["params_token"]
    end

    # Re-issue as a different admin+phantom user — the token's user_id won't match.
    other = User.create!(name: "Other", username: "other_phantom", role: :admin,
                         email: "other_phantom@mcritchie.studio",
                         web3_solana_address: "9aBcD3FgHjKmNpQrStUvWxYz1234567890aBcDeFgH12")
    log_in_as(other)
    Solana::Vault.stub :new, FakeVault.new do
      post rebuild_create_tx_contests_path, params: { params_token: token }, as: :json
    end

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_match(/User mismatch/i, json["error"])
  end

  # A free, off-chain contest — the only kind a successful #enter can be
  # exercised against without a Solana RPC mock (paid entries need a real
  # on-chain token consume / vault transfer). Free entries skip the payment gate.
  def free_contest
    Contest.create!(
      name: "Free Plumbing Contest",
      slate: slates(:one),
      contest_type: "standard",
      entry_fee_cents: 0,
      max_entries: 29,
      status: :open,
      starts_at: 2.weeks.from_now
    )
  end
end
