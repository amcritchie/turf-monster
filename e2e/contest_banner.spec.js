const { test, expect } = require("@playwright/test");
const { login, loginAdmin, reseed } = require("./helpers");
const path = require("path");

const BANNER_WIDE = path.join(__dirname, "..", "test", "fixtures", "files", "banner_wide.png");

// Admin banner update (PR #29). The banner reuses the avatar's shared crop-photo
// modal (cropPhotoModal) via a persistent uploader host: "Edit banner" opens the
// OS file picker, the picked image is framed in the shared crop modal at the
// banner ratio (4:1), and "Crop & Save" submits via Turbo (in-place hero swap).
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Contest banner update", () => {
  test("admin frames + saves a new banner from the hero (shared crop modal)", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/contests/world-cup-2026");

    // "Edit banner" opens the OS file picker; choosing an image opens the
    // shared crop-photo modal at the banner ratio.
    const chooser = page.waitForEvent("filechooser");
    await page.locator("#contest-hero").getByRole("button", { name: "Edit banner", exact: true }).click();
    await (await chooser).setFiles(BANNER_WIDE);

    await expect(page.locator(".cropper-container")).toBeVisible();

    // "Crop & Save" -> the persistent host submits -> hero re-renders in place.
    await page.getByRole("button", { name: /Crop.*Save/ }).click();

    await expect(page.locator(".cropper-container")).toBeHidden();
    await expect(page.locator("#contest-hero img")).toBeVisible();
  });

  test("the actions dropdown 'Edit Banner' opens the picker", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/contests/world-cup-2026");

    await page.getByRole("button", { name: "Contest actions" }).click();
    const chooser = page.waitForEvent("filechooser");
    await page.getByRole("button", { name: "Edit Banner", exact: true }).click();
    expect(await chooser).toBeTruthy();
  });

  test("non-admin sees no banner edit affordance", async ({ page }) => {
    await login(page, "mason@mcritchie.studio", "password");
    await page.goto("/contests/world-cup-2026");

    await expect(page.locator("#contest-hero")).toBeVisible();
    await expect(page.getByRole("button", { name: /edit banner/i })).toHaveCount(0);
    await expect(page.locator("#banner-image-picker")).toHaveCount(0);
  });
});
