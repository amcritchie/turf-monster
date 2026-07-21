const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

// The Turf multiplier base is pinned: rank 1 always prices x1.0, and NFL
// slates climb LINEARLY to the top of the curve (soccer keeps log decay).
// Seeded values come through the sport-aware SlateMatchup.turf_score_for.
test.describe("turf score pinned base", () => {
  test("NFL slate rank one shows x1.0 and the top rank shows the full scale", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/slates/nfl-2026-week-1");

    const rows = page.locator("div.sortable-item");
    await expect(rows).toHaveCount(32);
    await expect(rows.first()).toContainText("1.0x");
    await expect(rows.last()).toContainText("3.0x");

    // Linear midpoint: rank 17 of 32 sits near the curve's middle (~2.0x),
    // which the old log curve would have pushed well past 2.6x.
    await expect(rows.nth(16)).toContainText("2.0x");
  });
});
