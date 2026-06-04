const { test, expect } = require("@playwright/test");
const { login } = require("./helpers");

// ---------------------------------------------------------------------------
// Index page
// ---------------------------------------------------------------------------

test("index page loads with contest and matchup cards", async ({ page }) => {
  await page.goto("/");
  // / redirects to /contests/:slug; the inline matchup board renders for guests
  await expect(page.locator("body")).toContainText("Your Picks");
  // Matchup cards rendered as buttons with team names
  const matchupCards = page.locator("button.bg-surface");
  await expect(matchupCards.first()).toBeVisible();
  // Should show multiplier values
  await expect(page.locator("body")).toContainText("/ Goal");
});

// ---------------------------------------------------------------------------
// Guest selection toggling
// ---------------------------------------------------------------------------

test("guest clicking matchup card does not crash the page", async ({ page }) => {
  await page.goto("/");
  const firstCard = page.locator("button.bg-surface").first();
  await firstCard.click();

  // Toggle is an Alpine.js fetch — guest gets a 302/auth error but page stays.
  await expect(page.locator("body")).toContainText("Your Picks");
});

// ---------------------------------------------------------------------------
// Login flow
// ---------------------------------------------------------------------------

test("login with valid credentials", async ({ page }) => {
  await login(page, "alex@mcritchie.studio", "password");
  // Username should appear in header nav. The human operator's username is
  // `mcritchie` after the 2026-06-02 naming flip (the bare `alex` username now
  // belongs to the server bot). .filter({ hasText: "mcritchie" }) skips the
  // dropdown's "Account" link (same href, different text) so the assertion
  // isn't sensitive to nav DOM ordering between the dropdown and the chip.
  await expect(
    page.locator('a[href="/account"]').filter({ hasText: "mcritchie" }).first()
  ).toBeVisible();
});

test("requesting a magic link confirms the email was sent", async ({ page }) => {
  // Passwordless: there are no invalid credentials — any well-formed email
  // gets a one-tap link. Submitting the email form opens the "check your inbox"
  // modal in place (staying on /signin).
  await page.goto("/signin");
  await page.fill('input[name="email"]', "someone@example.com");
  await page.getByRole("button", { name: "Email Link" }).click();
  await page.waitForURL((url) => url.pathname.startsWith("/signin"));
  await expect(page.locator("body")).toContainText(/inbox|sign-in link/i);
});

// ---------------------------------------------------------------------------
// Logged-in selection toggling
// ---------------------------------------------------------------------------

test("logged-in user can toggle selection and see cart update", async ({ page }) => {
  await login(page, "alex@mcritchie.studio", "password");

  // Clear stale selections from prior tests
  await page.evaluate(async () => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch("/contests/world-cup-2026/clear_picks", {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken, "Accept": "application/json" },
    });
  });
  await page.goto("/");
  await page.waitForLoadState("networkidle");

  const firstCard = page.locator("button.bg-surface").first();
  await firstCard.click();

  // Cart should show 1 selection
  await expect(page.locator("body")).toContainText("1 / 6");

  // Click same card again to deselect
  await firstCard.click();
  // Selection count should go back to 0 — the Unselect chip disappears at 0 picks
  await expect(page.getByRole("button", { name: "Unselect all picks" })).not.toBeVisible();
});

// ---------------------------------------------------------------------------
// Selection persists on reload (server-rendered from cart entry)
// ---------------------------------------------------------------------------

test("selection persists after page reload", async ({ page }) => {
  await login(page, "mason@mcritchie.studio", "password");

  // Clear stale selections
  await page.evaluate(async () => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch("/contests/world-cup-2026/clear_picks", {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken, "Accept": "application/json" },
    });
  });
  await page.goto("/");
  await page.waitForLoadState("networkidle");

  const firstCard = page.locator("button.bg-surface").first();

  // Click and wait for the toggle_selection response to ensure server persists
  const [toggleResponse] = await Promise.all([
    page.waitForResponse(resp => resp.url().includes("toggle_selection")),
    firstCard.click(),
  ]);
  await expect(page.locator("body")).toContainText("1 / 6");

  // Reload
  await page.reload();

  // The selection should still be there (Alpine reads from server-rendered data)
  await expect(page.locator("body")).toContainText("1 / 6");
});

// ---------------------------------------------------------------------------
// Six selections shows confirm button
// ---------------------------------------------------------------------------

test("selecting 6 matchups shows Hold to Confirm button", async ({ page }) => {
  await login(page, "alex@mcritchie.studio", "password");

  // Clear stale selections from prior tests
  await page.evaluate(async () => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch("/contests/world-cup-2026/clear_picks", {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken, "Accept": "application/json" },
    });
  });
  await page.goto("/");
  await page.waitForLoadState("networkidle");

  const cards = page.locator("button.bg-surface");

  await cards.nth(0).click();
  await expect(page.locator("body")).toContainText("1 / 6");

  await cards.nth(1).click();
  await expect(page.locator("body")).toContainText("2 / 6");

  await cards.nth(2).click();
  await expect(page.locator("body")).toContainText("3 / 6");

  await cards.nth(3).click();
  await expect(page.locator("body")).toContainText("4 / 6");

  // Dismiss blur overlay before clicking 5th
  const blurOverlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
  if (await blurOverlay.isVisible({ timeout: 500 }).catch(() => false)) {
    await blurOverlay.click();
  }

  await cards.nth(4).click();
  await expect(page.locator("body")).toContainText("5 / 6");

  // Dismiss blur overlay before clicking 6th
  if (await blurOverlay.isVisible({ timeout: 500 }).catch(() => false)) {
    await blurOverlay.click();
  }

  await cards.nth(5).click();
  await expect(page.locator("body")).toContainText("6 / 6");

  // Hold to Confirm button should be visible (desktop + mobile = 2 elements, use first)
  await expect(page.getByText("Hold to Confirm").first()).toBeVisible();
});

// ---------------------------------------------------------------------------
// Second entry after confirming
// ---------------------------------------------------------------------------

test("user can start a second entry after confirming the first", async ({ page }) => {
  // Use mack (clean state — no selections from other tests)
  await login(page, "mack@mcritchie.studio", "password");

  // Clear any existing cart first
  const contestPath = "/contests/world-cup-2026";
  await page.evaluate(async (cp) => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch(`${cp}/clear_picks`, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken, "Accept": "application/json" },
    });
  }, contestPath);
  // Navigate directly to the target contest — / redirects to the most recent
  // contest, which may be a partial contest left by other tests (e.g. the
  // onchain admin-creates-contest test).
  await page.goto(contestPath);
  await page.waitForLoadState("networkidle");

  // Select 6 matchups
  const cards = page.locator("button.bg-surface");
  for (let i = 0; i < 6; i++) {
    const blurOverlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
    if (await blurOverlay.isVisible({ timeout: 300 }).catch(() => false)) {
      await blurOverlay.click();
    }
    await cards.nth(i).click();
    await expect(page.locator("body")).toContainText(`${i + 1} / 6`);
  }

  // Confirm entry via POST
  await page.evaluate(async (cp) => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch(`${cp}/enter`, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken, "Accept": "application/json" },
    });
  }, contestPath);

  // Clear stale cart after confirming so the new entry starts fresh
  await page.evaluate(async (cp) => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch(`${cp}/clear_picks`, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken, "Accept": "application/json" },
    });
  }, contestPath);

  // Reload to get fresh page state after confirm — target world-cup-2026 directly
  await page.goto(contestPath);
  await page.waitForLoadState("networkidle");

  // Dismiss blur overlay if present
  const overlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
  if (await overlay.isVisible({ timeout: 1000 }).catch(() => false)) {
    await overlay.click();
  }

  // Click a matchup card to start a new entry
  await cards.first().click();

  // Should see the selection registered in the cart (1/6)
  await expect(page.locator("body")).toContainText("1 / 6");
});

// ---------------------------------------------------------------------------
// Contest show page
// ---------------------------------------------------------------------------

test("contest show page loads with leaderboard section", async ({ page }) => {
  await page.goto("/");
  await page.click("text=View Contest Details");

  await expect(page.locator("body")).toContainText("World Cup 2026");
  // Contest details should be visible
  await expect(page.locator("body")).toContainText("Entry Fee");
});
