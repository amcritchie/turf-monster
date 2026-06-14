// Playwright global setup — runs once before any spec.
//
// Swaps the canonical admin user's wallet to MOCK_PUBKEY_B58 (the address
// the Phantom mock signs with) so loginViaPhantom resolves to alex and
// admin-only specs see admin UI. The previous wallet is stashed in
// Rails.cache by the endpoint and restored by globalTeardown.
//
// Why this exists: e2e/seed.rb now defaults to alex's REAL Phantom wallet
// (so manual browser testing gets admin treatment). Without this swap,
// every Playwright Phantom auth would create a fresh "viewer" user.
//
// Crash safety: if the run dies before teardown fires, the dev DB is left
// pointing alex at the mock pubkey. Run `bin/rails runner e2e/seed.rb`
// to restore (the seed re-reads the canonical wallet from
// db/seeds/users.rb).

const { request } = require("@playwright/test");

module.exports = async (config) => {
  const baseURL = config?.projects?.[0]?.use?.baseURL || "http://127.0.0.1:3100";
  const ctx = await request.newContext({ baseURL });
  const response = await ctx.post("/test/use_phantom_mock_admin");
  if (!response.ok()) {
    throw new Error(
      `globalSetup: /test/use_phantom_mock_admin failed ${response.status()} ` +
      `${await response.text()}`
    );
  }
  await ctx.dispose();
};
