// Quests via the navbar gear "Next: …" pointer — web3 (Phantom, no email) user.
//
// The gear menu (components/_admin_dropdown) renders a dynamic "Next: …" row
// from User#next_quest. The username + newsletter steps open their modals
// straight from the menu (the same modals the /account buttons open); join /
// chat / invite link to the contest. This spec drives the two MODAL-opening
// steps and confirms the web3 add-email field on the newsletter one.
//
// quest_step is staged server-side (setQuestState) rather than driven through
// the on-chain username/chat quests, so the gear renders the exact "Next: …"
// row we want. We only OPEN the modals here (no submit), so no endpoint stubs
// are needed.

const { test, expect } = require("@playwright/test");
const {
  loginViaPhantom,
  setupPhantomMock,
  reseed,
  createActiveEntry,
  setQuestState,
} = require("./helpers");

const CONTEST_SLUG = "world-cup-2026";

test.beforeEach(async ({ request }) => await reseed(request));

// Non-admin users get the gear titled "Settings"; open the visible (desktop)
// one. There can be a duplicate gear in the mobile sub-navbar (hidden at the
// default desktop viewport), so scope to :visible.
async function openGear(page) {
  await page.locator('button[title="Settings"]:visible').first().click();
}

test("gear 'Pick a username' opens the username modal", async ({ page }) => {
  await setupPhantomMock(page, { seedByte: 2 });
  await loginViaPhantom(page);
  // With an entry, next_quest advances from :join to :username (fresh user).
  await createActiveEntry(page, CONTEST_SLUG);
  await page.goto("/account");

  await openGear(page);
  await page.locator('button:has-text("Pick a username"):visible').first().click();

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("Change Username")).toBeVisible();
  await expect(dialog.getByPlaceholder("username")).toBeVisible();
});

test("gear 'Join newsletter' opens the newsletter modal with the add-email field", async ({ page }) => {
  await setupPhantomMock(page, { seedByte: 2 });
  await loginViaPhantom(page);
  await createActiveEntry(page, CONTEST_SLUG);
  // Stage past username + chat so next_quest === :newsletter (the gear row that
  // opens the newsletter-subscribe modal). Reload so the server re-renders the
  // gear with the new pointer.
  await setQuestState(page, { username_changed: true, chat_sent: true });
  await page.goto("/account");

  await openGear(page);
  await page.locator('button:has-text("Join newsletter"):visible').first().click();

  const dialog = page.getByRole("dialog");
  await expect(dialog.getByText("Join the Newsletter")).toBeVisible();
  // web3 (no email on file) -> the add-email capture field is present.
  await expect(dialog.getByPlaceholder("you@example.com")).toBeVisible();
});
