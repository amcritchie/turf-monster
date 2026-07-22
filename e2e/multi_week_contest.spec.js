const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

// A multi-week contest ("NFL Weeks 15-17") is picked by TEAM, not by game — the
// team plays a different opponent each week, so the single-week paired board
// would be meaningless here. Seeded by e2e/seed.rb.
test.describe("multi-week contest board", () => {
  test("names its span and drops the game/advantage sort", async ({ page }) => {
    await page.goto("/contests/nfl-weeks-15-17");

    await expect(page.getByText("Weeks 15-17", { exact: false }).first()).toBeVisible();
    await expect(page.getByText("pick 6 teams")).toBeVisible();

    // There is no game view on a span board, so the sort toggle must be gone —
    // leaving it would offer a pairing that doesn't exist.
    await expect(page.getByRole("button", { name: "Game", exact: true })).toHaveCount(0);
    await expect(page.getByRole("button", { name: /Advantage/ })).toHaveCount(0);
  });

  test("each team card shows one labelled section per week", async ({ page }) => {
    await page.goto("/contests/nfl-weeks-15-17");

    // A pick card is a TEAM with its three opponents. The aria-label carries the
    // whole span, which is also what a screen reader announces.
    const teamCard = page.locator('button[aria-label*="week 15:"]').first();
    await expect(teamCard).toBeVisible();

    for (const week of ["Week 15", "Week 16", "Week 17"]) {
      await expect(teamCard.getByText(week, { exact: true })).toBeVisible();
    }

    // One span multiplier per card, rendered "N× Point(s)" — not per week.
    await expect(teamCard.getByText(/Points?/).first()).toBeVisible();
  });

  test("selecting a team puts its mascot and span multiplier in the cart", async ({ page }) => {
    await page.goto("/contests/nfl-weeks-15-17");

    const teamCard = page.locator('button[aria-label*="week 15:"]').first();
    const teamName = await teamCard.locator(".team-name").innerText();
    await teamCard.click();

    // The cart labels the multiplier "Points" (it is points per goal), and uses
    // the mascot rather than the full city name to keep the row on one line.
    const cart = page.locator("text=Points").first();
    await expect(cart).toBeVisible();

    // The mascot is the last word of the full team name ("Los Angeles Chargers"
    // -> "Chargers"), so the cart row must contain it without the city.
    const mascot = teamName.trim().split(" ").pop();
    await expect(page.getByText(mascot, { exact: false }).first()).toBeVisible();
  });
});
