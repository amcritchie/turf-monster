const { test, expect } = require("@playwright/test");
const { login } = require("./helpers");

// World Cup Survivor — entry + per-round pick flow.
// The seeded survivor contest is the free roll and is not on-chain, so entry
// is a pure DB write (the on-chain entry path is unit- and devnet-tested
// separately).

const CONTEST = "/contests/world-cup-survivor";

test("survivor contest page renders the board for a guest", async ({ page }) => {
  await page.goto(CONTEST);

  await expect(page.locator("body")).toContainText("Last one standing wins");
  await expect(page.locator("body")).toContainText("Tournament Rounds");
  await expect(page.locator("body")).toContainText("Survivors"); // leaderboard panel
  await expect(page.locator('[data-testid="survivor-enter"]')).toBeVisible();
});

test("a logged-in user can enter and make a round-1 pick", async ({ page }) => {
  await login(page, "mason@mcritchie.studio", "password");

  // Enter via the API — the entry flow itself is unit- and devnet-tested; this
  // spec is about the page + picker UI.
  await page.goto(CONTEST);
  const entered = await page.evaluate(async () => {
    const csrf = document.querySelector('meta[name="csrf-token"]')?.content;
    const r = await fetch("/contests/world-cup-survivor/enter", {
      method: "POST",
      headers: { "X-CSRF-Token": csrf, Accept: "application/json" },
    });
    return r.ok;
  });
  expect(entered).toBeTruthy();

  // Reload — the entered board shows the status banner + the round-1 picker.
  await page.goto(CONTEST);
  await expect(page.locator("body")).toContainText("You're alive");
  await expect(page.locator("body")).toContainText("pick a team to survive");

  // Pick the first team in the round-1 picker.
  const teamButton = page.locator('[data-testid="survivor-team"]').first();
  const [pickResp] = await Promise.all([
    page.waitForResponse(
      (r) => r.url().includes("/pick") && r.request().method() === "POST"
    ),
    teamButton.click(),
  ]);
  expect(pickResp.ok()).toBeTruthy();
  await expect(page.locator("body")).toContainText("Pick saved");
});
