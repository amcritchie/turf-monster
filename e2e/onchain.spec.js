const { test, expect } = require("@playwright/test");
const {
  login,
  loginViaPhantom,
  setupPhantomMock,
  setupOnchainMocks,
} = require("./helpers");

const CONTEST_PATH = "/contests/world-cup-2026";

// ---------------------------------------------------------------------------
// Helper: select 6 matchup cards on the contest show page
// ---------------------------------------------------------------------------

async function selectMatchups(page) {
  // role="checkbox" is the matchup-card semantic (set in _matchup_card.html.erb).
  // Scope to the active selectionBoard and exclude locked matchups (already-
  // kicked games render with `disabled`). The previous `button.bg-surface`
  // selector drifted out of uniqueness AND scope AND ignored lock state.
  const cards = page.locator('[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])');

  for (let i = 0; i < 6; i++) {
    // Dismiss blur overlay if it appears (after 5th selection)
    const blurOverlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
    if (await blurOverlay.isVisible({ timeout: 300 }).catch(() => false)) {
      await blurOverlay.click();
    }

    await cards.nth(i).click();
    await expect(page.locator("body")).toContainText(`${i + 1}/6`);
  }
}

// ---------------------------------------------------------------------------
// Test 1: Phantom sign-in (existing user)
// ---------------------------------------------------------------------------

test("phantom sign-in with existing user", async ({ page }) => {
  await setupPhantomMock(page); // seed byte 1 = matches alex's solana_address

  await loginViaPhantom(page);

  // Alex's username should appear in the nav (nav shows username, not display name)
  await expect(page.locator('a[href="/account"]').first()).toContainText("alex");

  // "Log in" link should NOT be visible (proves we're authenticated)
  await expect(page.locator('a[href="/login"]').first()).not.toBeVisible();
});

// ---------------------------------------------------------------------------
// Test 2: Phantom sign-in (new user — different keypair)
// ---------------------------------------------------------------------------

test("phantom sign-in creates new user", async ({ page }) => {
  // Seed byte 2 = pubkey 8pM1DN3RiT8vbom5u1sNryaNT1nyL8CTTW3b5PwWXRBH
  // Not in DB — server creates a new user
  await setupPhantomMock(page, { seedByte: 2 });

  await loginViaPhantom(page);

  // "Log in" link should NOT be visible (proves we're authenticated)
  await expect(page.locator('a[href="/login"]')).not.toBeVisible();

  // Profile modal should auto-open for new users (after 300ms delay)
  await expect(page.locator("#profile-modal-form")).toBeVisible({
    timeout: 3000,
  });
});

// ---------------------------------------------------------------------------
// Test 3: Standard contest entry (mack, no wallet)
// ---------------------------------------------------------------------------

test("standard entry with balance deduction", async ({ page }) => {
  await login(page, "mack@mcritchie.studio", "password");

  // Navigate to the contest show page (matchup board)
  await page.goto(CONTEST_PATH);
  await page.waitForLoadState("networkidle");

  // Select 5 matchups
  await selectMatchups(page);

  // Confirm entry via direct POST (same pattern as smoke.spec.js)
  await page.evaluate(async (contestPath) => {
    const csrfToken = document.querySelector(
      'meta[name="csrf-token"]'
    )?.content;
    await fetch(`${contestPath}/enter`, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken, Accept: "application/json" },
    });
  }, CONTEST_PATH);

  // Reload the contest show page — Mack should be on the leaderboard
  await page.goto(CONTEST_PATH);
  await expect(page.locator("body")).toContainText("mack");
});

// ---------------------------------------------------------------------------
// Test 4: Onchain contest entry (alex, Phantom + mocked devnet)
// ---------------------------------------------------------------------------

test("onchain entry via Phantom with mocked devnet", async ({ page }) => {
  await setupPhantomMock(page);
  await setupOnchainMocks(page);

  await loginViaPhantom(page);

  // Navigate to the contest show page
  await page.goto(CONTEST_PATH);
  await page.waitForLoadState("networkidle");

  // Clear any stale selections from prior tests
  await page.evaluate(async (contestPath) => {
    const csrfToken = document.querySelector(
      'meta[name="csrf-token"]'
    )?.content;
    await fetch(`${contestPath}/clear_picks`, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken },
    });
  }, CONTEST_PATH);
  await page.reload();
  await page.waitForLoadState("networkidle");

  // Select 5 matchups
  await selectMatchups(page);

  // Trigger confirmEntry() directly via Alpine (avoids hold-button timing)
  await page.evaluate(async () => {
    const els = document.querySelectorAll("[x-data]");
    for (const el of els) {
      const data = Alpine.$data(el);
      if (typeof data.confirmEntry === "function") {
        await data.confirmEntry();
        return;
      }
    }
    throw new Error("confirmEntry() not found on any Alpine component");
  });

  // Modal should show success with seeds earned
  await expect(page.locator("body")).toContainText("Entry submitted onchain", {
    timeout: 15000,
  });
  await expect(page.locator("body")).toContainText("+65");

  // Close modal → triggers redirect to contest page
  await page.evaluate(() => Alpine.store("solanaModal").close());
  await page.waitForURL(/\/contests\//, { timeout: 10000 });

  // Contest show page should load
  await expect(page.locator("body")).toContainText("World Cup 2026");
});

// ---------------------------------------------------------------------------
// Test 5: Contest creation (admin, mocked onchain)
// ---------------------------------------------------------------------------

test("admin creates onchain contest", async ({ page }) => {
  await setupPhantomMock(page);
  await setupOnchainMocks(page);

  await loginViaPhantom(page);

  await page.goto("/contests/new");

  // Fill the form with unique name
  const contestName = `E2E Contest ${Date.now().toString(36)}`;
  await page.fill("#contest_name", contestName);
  await page.selectOption("#contest_slate_id", { label: "World Cup 2026" });

  // Click "Create Contest" (inside x-if="hasWallet" — mock makes it visible)
  await page.getByRole("button", { name: "Create Contest" }).click();

  // The inline JS orchestrates: DB create → prepare (mocked) → sign → RPC (mocked)
  // → confirm_onchain_contest (real server) → success modal → countdown redirect

  // Success modal shows countdown then redirects to the new contest page
  await expect(page.locator("body")).toContainText("Redirecting in", {
    timeout: 15000,
  });

  // Auto-redirect after 3s countdown
  await page.waitForURL(/\/contests\/(?!new)/, { timeout: 10000 });

  // Contest show page should display the new contest
  await expect(page.locator("body")).toContainText(contestName);
});
