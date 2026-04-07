/**
 * E2E: Mac app message sync + FYI forward
 *
 * Simulates the full flow:
 *   1. Mac app pushes inbound messages via agent API key
 *   2. Mac app forwards conversation as FYI via agent API key
 *   3. Recipient logs into web dashboard and sees the thread
 *
 * Runs against both staging (full, with dev-login) and production (API-only,
 * requires PROD_AGENT_KEY env var).
 */

import { test, expect, request as playwrightRequest } from '@playwright/test';

// ── Environment configs ────────────────────────────────────────────────────

interface Env {
  name: string;
  apiUrl: string;
  frontendUrl: string;
  /** Dev-login endpoints available (staging / development only) */
  devLogin: boolean;
  /** For production: pre-existing agent API key from env var */
  agentKeyEnvVar?: string;
}

const ENVS: Env[] = [
  {
    name: 'staging',
    apiUrl: 'https://mfsynced-api-staging-iztclq7eza-uc.a.run.app',
    frontendUrl: 'https://mfsynced-dashboard-staging-iztclq7eza-uc.a.run.app',
    devLogin: true,
  },
  {
    name: 'production',
    apiUrl: 'https://mfsynced-api-production-iztclq7eza-uc.a.run.app',
    frontendUrl: 'https://mfsynced-dashboard-production-iztclq7eza-uc.a.run.app',
    devLogin: false,
    agentKeyEnvVar: 'PROD_AGENT_KEY',
  },
];

// ── Test factory ───────────────────────────────────────────────────────────

for (const env of ENVS) {
  test.describe.serial(`[${env.name}] sync messages + FYI forward`, () => {
    let apiKey = '';
    let senderToken = '';     // JWT for the agent owner (forwarder)
    let recipientToken = '';  // JWT for the inbox recipient
    let recipientUserId = '';
    const ts = Date.now();
    // Use 555-range numbers so they're clearly synthetic
    const TEST_PHONE = `+1555${ts.toString().slice(-7)}`;
    const CONTACT_NAME = `E2E Contact [${env.name}]`;

    test.beforeAll(async () => {
      if (env.agentKeyEnvVar && !env.devLogin) {
        apiKey = process.env[env.agentKeyEnvVar] ?? '';
        if (!apiKey) {
          console.log(`Skipping ${env.name}: ${env.agentKeyEnvVar} env var not set`);
          return;
        }
      }

      if (env.devLogin) {
        const ctx = await playwrightRequest.newContext({ baseURL: env.apiUrl });

        // Log in as Stephan (agent owner / forwarder)
        const stephanResp = await ctx.post('/v1/auth/dev-admin-login');
        expect(stephanResp.ok(), `dev-admin-login: ${await stephanResp.text()}`).toBeTruthy();
        senderToken = (await stephanResp.json()).access_token;

        // Log in as Leroy (inbox recipient)
        const leroyResp = await ctx.post('/v1/auth/dev-login');
        expect(leroyResp.ok(), `dev-login: ${await leroyResp.text()}`).toBeTruthy();
        recipientToken = (await leroyResp.json()).access_token;

        const meResp = await ctx.get('/v1/auth/me', {
          headers: { Authorization: `Bearer ${recipientToken}` },
        });
        recipientUserId = (await meResp.json()).id;

        // Register a fresh agent for this test run
        const agentResp = await ctx.post('/v1/agent/register', {
          headers: { Authorization: `Bearer ${senderToken}` },
          data: { name: `E2E [${env.name}] ${ts}` },
        });
        expect(agentResp.ok(), `register: ${await agentResp.text()}`).toBeTruthy();
        const agentData = await agentResp.json();
        apiKey = agentData.api_key;

        await ctx.dispose();
      } else {
        // Production: look up a recipient from the users list
        const ctx = await playwrightRequest.newContext({ baseURL: env.apiUrl });
        const usersResp = await ctx.get('/v1/agent/users', {
          headers: { Authorization: `Bearer ${apiKey}` },
        });
        expect(usersResp.ok(), `list users: ${await usersResp.text()}`).toBeTruthy();
        const users: { id: string; email: string; name: string }[] = await usersResp.json();
        // Forward to Chase on production
        const chase = users.find(u => u.email === 'chase@moonfive.tech');
        expect(chase, 'chase@moonfive.tech not found in users list').toBeTruthy();
        recipientUserId = chase!.id;
        await ctx.dispose();
      }
    });

    // ── Test 1: inbound message sync ───────────────────────────────────────

    test('pushes inbound messages and gets them confirmed', async () => {
      if (!apiKey) test.skip();

      const ctx = await playwrightRequest.newContext({ baseURL: env.apiUrl });

      const messages = [
        {
          id: `e2e-${ts}-1`,
          phone: TEST_PHONE,
          contact_name: CONTACT_NAME,
          is_from_me: false,
          service: 'iMessage',
          text: 'Hey, just wanted to follow up on the Q2 proposal.',
          timestamp: new Date(Date.now() - 120_000).toISOString(),
        },
        {
          id: `e2e-${ts}-2`,
          phone: TEST_PHONE,
          contact_name: CONTACT_NAME,
          is_from_me: true,
          service: 'iMessage',
          text: "Thanks for reaching out — I'll loop in the team.",
          timestamp: new Date(Date.now() - 60_000).toISOString(),
        },
        {
          id: `e2e-${ts}-3`,
          phone: TEST_PHONE,
          contact_name: CONTACT_NAME,
          is_from_me: false,
          service: 'iMessage',
          text: 'Sounds good, looking forward to it.',
          timestamp: new Date().toISOString(),
        },
      ];

      const resp = await ctx.post('/v1/agent/messages/inbound', {
        headers: { Authorization: `Bearer ${apiKey}` },
        data: { agent_id: '', messages },
      });
      expect(resp.ok(), `inbound: ${await resp.text()}`).toBeTruthy();
      const data = await resp.json();
      expect(data.confirmed).toHaveLength(messages.length);

      await ctx.dispose();
    });

    // ── Test 2: /v1/agent/users lists team members ─────────────────────────

    test('lists team members via agent API key', async () => {
      if (!apiKey) test.skip();

      const ctx = await playwrightRequest.newContext({ baseURL: env.apiUrl });
      const resp = await ctx.get('/v1/agent/users', {
        headers: { Authorization: `Bearer ${apiKey}` },
      });
      expect(resp.ok(), `users: ${await resp.text()}`).toBeTruthy();
      const users: { id: string; email: string }[] = await resp.json();
      expect(users.length).toBeGreaterThan(0);
      // All records have required fields
      for (const u of users) {
        expect(u.id).toBeTruthy();
        expect(u.email).toContain('@');
      }

      await ctx.dispose();
    });

    // ── Test 3: FYI forward ────────────────────────────────────────────────

    test('forwards conversation as FYI via agent API key', async () => {
      if (!apiKey) test.skip();

      const ctx = await playwrightRequest.newContext({ baseURL: env.apiUrl });
      const resp = await ctx.post('/v1/agent/forward', {
        headers: { Authorization: `Bearer ${apiKey}` },
        data: {
          phone: TEST_PHONE,
          mode: 'fyi',
          note: `E2E FYI forward [${env.name}] ${ts}`,
          recipient_user_ids: [recipientUserId],
        },
      });
      expect(resp.ok(), `forward: ${await resp.text()}`).toBeTruthy();
      const data = await resp.json();
      expect(data.thread_id).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      );

      await ctx.dispose();
    });

    // ── Test 4: re-forward as action (upsert) works ────────────────────────

    test('re-forwarding same conversation as action mode upserts cleanly', async () => {
      if (!apiKey) test.skip();

      const ctx = await playwrightRequest.newContext({ baseURL: env.apiUrl });
      const resp = await ctx.post('/v1/agent/forward', {
        headers: { Authorization: `Bearer ${apiKey}` },
        data: {
          phone: TEST_PHONE,
          mode: 'action',
          note: `E2E action re-forward [${env.name}] ${ts}`,
          recipient_user_ids: [recipientUserId],
        },
      });
      expect(resp.ok(), `re-forward: ${await resp.text()}`).toBeTruthy();
      const data = await resp.json();
      expect(data.thread_id).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      );

      await ctx.dispose();
    });

    // ── Tests 5–6: web inbox verification (staging only, requires dev-login) ─

    test('recipient sees FYI thread in web inbox', async ({ page }) => {
      if (!env.devLogin || !recipientToken) test.skip();

      await page.goto(env.frontendUrl);
      await page.evaluate((token) => localStorage.setItem('token', token), recipientToken);
      await page.goto(`${env.frontendUrl}/`);
      await page.waitForLoadState('networkidle');

      // The E2E contact thread should appear in inbox
      await expect(page.getByText(CONTACT_NAME).first()).toBeVisible({ timeout: 15_000 });
    });

    test('recipient opens thread and sees messages + FYI badge', async ({ page }) => {
      if (!env.devLogin || !recipientToken) test.skip();

      await page.goto(env.frontendUrl);
      await page.evaluate((token) => localStorage.setItem('token', token), recipientToken);
      await page.goto(`${env.frontendUrl}/`);
      await page.waitForLoadState('networkidle');

      // Open the thread
      const threadLink = page.getByRole('link').filter({ hasText: CONTACT_NAME }).first();
      await expect(threadLink).toBeVisible({ timeout: 10_000 });
      await threadLink.click();

      await page.waitForURL(/\/inbox\//);
      await page.waitForLoadState('networkidle');

      // Mode shows Action Needed (we re-forwarded as action in test 4)
      await expect(page.getByText('Action Needed').first()).toBeVisible();

      // Note is visible
      await expect(
        page.getByText(new RegExp(`E2E action re-forward \\[${env.name}\\]`)).first()
      ).toBeVisible();

      // All 3 messages present
      await expect(page.getByText('Hey, just wanted to follow up on the Q2 proposal.')).toBeVisible();
      await expect(page.getByText(/loop in the team/).first()).toBeVisible();
      await expect(page.getByText('Sounds good, looking forward to it.')).toBeVisible();
    });
  });
}
