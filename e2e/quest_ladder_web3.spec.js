// Quest ladder — web3 (Phantom) user, driven on the contest page.
//
// The quest card (contests/_quest_card) is a client-side step machine:
// username -> chat -> newsletter -> invite. Each step is a stacked grid cell
// that crossfades to the next (x-show + x-transition); the advance is fired by
// window.completeQuest -> a delayed `quest-advance` event (no page reload). The
// card only renders for ENTERED users (@has_entry), and the username modal's
// rename form only unlocks once can_change_username? (solana_connected? &&
// contest_entered?) — so each spec creates an :active entry first.
//
// CHAINLESS NOTE: e2e contests are off-chain (skip_onchain_callback in
// e2e/seed.rb), so the on-chain SEED GRANTS behind the username / chat / newsletter
// quests never fire. We stub those three endpoints (stubQuestEndpoints — same
// page.route pattern as e2e/rpc-mock.js) to return the success payload the server
// emits AFTER a confirmed grant, so the REAL client orchestration runs (crossfade
// advance, the chat arrow idle->spinner->checkmark, the web3 add-email capture).
// We assert UI flow only — NOT on-chain seed totals (that's devnet-smoke.spec.js).

const { test, expect } = require("@playwright/test");
const {
  loginViaPhantom,
  setupPhantomMock,
  reseed,
  createActiveEntry,
  setQuestState,
  stubQuestEndpoints,
} = require("./helpers");

const CONTEST_SLUG = "world-cup-2026";
const CONTEST_PATH = `/contests/${CONTEST_SLUG}`;

test.beforeEach(async ({ request }) => await reseed(request));

test("web3 user climbs the full quest ladder on the contest page", async ({ page }) => {
  // The chained ~2s crossfade advances + login push this past the 30s default.
  test.setTimeout(60_000);

  // seed byte 2 = a wallet NOT in the seed → loginViaPhantom creates a fresh
  // web3 user: no email on file (so the newsletter add-email field shows later),
  // an auto-generated username (first_username_change? true), no chat, not
  // subscribed → quest_step starts at :username.
  await setupPhantomMock(page, { seedByte: 2 });
  await loginViaPhantom(page);

  // :active entry → @has_entry (renders the quest card) + unlocks the rename.
  await createActiveEntry(page, CONTEST_SLUG);
  await stubQuestEndpoints(page);
  await page.goto(CONTEST_PATH);

  const dialog = page.getByRole("dialog");

  // --- Mission 1: change username -----------------------------------------
  await expect(page.getByText("Change Your Username")).toBeVisible(); // quest card, step 1
  await page.getByRole("button", { name: "Change Username" }).click(); // -> opens the username modal
  await dialog.getByPlaceholder("username").fill("quest-hero-77");
  await dialog.getByRole("button", { name: "Save" }).click();

  // --- Mission 2: send first chat message (card crossfaded username -> chat) -
  await expect(page.getByText("Send Your First Message")).toBeVisible();
  const chatInput = page.locator("#contest-chat-input");
  await chatInput.fill("Hello contest 👋");
  await chatInput.press("Control+Enter"); // Ctrl/⌘+Enter sends (see _chat_panel)
  // The quest arrow runs idle -> spinner (in flight) -> checkmark (seeds earned).
  await expect(page.locator(".quest-arrow-spinner")).toBeVisible();
  await expect(page.locator('[aria-label="Sent"]')).toBeVisible();

  // --- Mission 3: join newsletter (card crossfaded chat -> newsletter) ------
  await expect(page.getByText("Join the Newsletter")).toBeVisible(); // quest card, step 3
  await page.getByRole("button", { name: "Subscribe" }).click();
  // web3 (no email) -> the email-capture modal opens BEFORE the join POST.
  await expect(dialog.getByText("One more thing")).toBeVisible();
  await dialog.getByPlaceholder("you@example.com").fill("web3-quester@example.com");
  await dialog.getByRole("button", { name: /Join.*Claim 25 Seeds/ }).click();

  // --- Mission 4: invite (card crossfaded newsletter -> invite, terminal) ---
  await expect(page.getByRole("button", { name: "Copy Link" })).toBeVisible();
});

test("quest ladder skips an already-completed step (dedup)", async ({ page }) => {
  test.setTimeout(60_000);

  await setupPhantomMock(page, { seedByte: 2 });
  await loginViaPhantom(page);
  await createActiveEntry(page, CONTEST_SLUG);

  // Mark the newsletter quest already done. quest_step is still :username
  // (username + chat not done), so the card starts at username, but the card's
  // `done` map carries newsletter:true — so when the chat step finishes,
  // questCard._nextUndone('newsletter') skips the done newsletter step and
  // lands on invite. This is the ladder-dedup contract.
  await setQuestState(page, { subscribed: true });
  await stubQuestEndpoints(page);
  await page.goto(CONTEST_PATH);

  const dialog = page.getByRole("dialog");

  // Mission 1: username -> chat
  await page.getByRole("button", { name: "Change Username" }).click();
  await dialog.getByPlaceholder("username").fill("dedup-hero-5");
  await dialog.getByRole("button", { name: "Save" }).click();
  await expect(page.getByText("Send Your First Message")).toBeVisible();

  // Mission 2: chat -> (skip newsletter) -> invite
  const chatInput = page.locator("#contest-chat-input");
  await chatInput.fill("gm 👋");
  await chatInput.press("Control+Enter");
  await expect(page.locator('[aria-label="Sent"]')).toBeVisible();

  // Lands on invite, NOT the (already-done) newsletter step.
  await expect(page.getByRole("button", { name: "Copy Link" })).toBeVisible();
  await expect(page.getByText("Join the Newsletter")).not.toBeVisible();
});
