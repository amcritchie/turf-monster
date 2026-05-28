// Playwright global teardown — runs once after the suite completes
// (success or failure). Restores alex's web3_solana_address to the value
// global-setup.js stashed before swapping it to MOCK_PUBKEY_B58.

const { request } = require("@playwright/test");

module.exports = async (config) => {
  const baseURL = config?.projects?.[0]?.use?.baseURL || "http://127.0.0.1:3001";
  const ctx = await request.newContext({ baseURL });
  try {
    const response = await ctx.post("/test/restore_canonical_admin");
    if (!response.ok()) {
      // Don't throw — teardown should be best-effort. Log loudly so a
      // crashed dev DB is visible in the test output.
      console.error(
        `globalTeardown: /test/restore_canonical_admin failed ` +
        `${response.status()} ${await response.text()}\n` +
        `Run \`bin/rails runner e2e/seed.rb\` to restore alex's wallet.`
      );
    }
  } finally {
    await ctx.dispose();
  }
};
