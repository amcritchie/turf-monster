const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");
const path = require("path");

const BANNER_WIDE = path.join(__dirname, "..", "test", "fixtures", "files", "banner_wide.png");

// Admin "Update banner" flow (PR #29). The server side is covered by
// ContestsControllerTest; this drives the actual JS path that unit tests can't:
// modal open -> imageDropzone file pick -> Turbo submit -> in-place hero swap +
// modal close, plus the second entry point in the actions dropdown.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Contest banner update", () => {
  test("admin frames + saves a new banner from the hero modal", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/contests/world-cup-2026");

    // Open the modal from the hero's admin "Edit banner" button.
    await page.locator("#contest-hero")
      .getByRole("button", { name: "Edit banner", exact: true })
      .click();
    await expect(page.getByRole("heading", { name: "Update banner" })).toBeVisible();

    const save = page.getByRole("button", { name: "Save banner" });
    await expect(save).toBeDisabled();

    // Pick an image -> the cropper.js frame mounts -> Save enables.
    await page.locator("#banner-image-picker").setInputFiles(BANNER_WIDE);
    await expect(page.locator(".cropper-container")).toBeVisible();
    await expect(save).toBeEnabled();

    await save.click();

    // turbo:submit-end closes the modal; the hero re-renders with an <img>.
    await expect(page.getByRole("heading", { name: "Update banner" })).toBeHidden();
    await expect(page.locator("#contest-hero img")).toBeVisible();
  });

  test("admin can open the banner modal from the actions dropdown", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/contests/world-cup-2026");

    await page.getByRole("button", { name: "Contest actions" }).click();
    await page.getByRole("button", { name: "Edit Banner", exact: true }).click();

    await expect(page.getByRole("heading", { name: "Update banner" })).toBeVisible();
  });

  test("non-admin sees no banner edit affordance", async ({ page }) => {
    const { login } = require("./helpers");
    await login(page, "mason@mcritchie.studio", "password");
    await page.goto("/contests/world-cup-2026");

    await expect(page.locator("#contest-hero")).toBeVisible();
    await expect(page.getByRole("button", { name: /edit banner/i })).toHaveCount(0);
  });
});
