import { test, expect, request as playwrightRequest } from '@playwright/test';

const BASE_URL = 'http://localhost:5173';
const API_URL = 'http://localhost:8001';

// Conrad Kong's real data (phone from Contacts, messages from iMessage thread)
const CONTACT_NAME = 'Conrad Kong';
const CONTACT_PHONE = '+14088338896';
const ts = Date.now();
const MESSAGES = [
  {
    id: `ck-1-${ts}`, phone: CONTACT_PHONE, contact_name: CONTACT_NAME, is_from_me: false, service: 'iMessage',
    text: "also own the conduit and cabling costs and electricians (if you need them). We have a team that we're working with at the moment.",
    timestamp: new Date(Date.now() - 480000).toISOString(),
  },
  {
    id: `ck-2-${ts}`, phone: CONTACT_PHONE, contact_name: CONTACT_NAME, is_from_me: true, service: 'iMessage',
    text: "Hey Conrad, if you are ok with it. We can do a site walk tomorrow and complete an installation by end of week.",
    timestamp: new Date(Date.now() - 420000).toISOString(),
  },
  {
    id: `ck-3-${ts}`, phone: CONTACT_PHONE, contact_name: CONTACT_NAME, is_from_me: false, service: 'iMessage',
    text: "Sure",
    timestamp: new Date(Date.now() - 360000).toISOString(),
  },
  {
    id: `ck-4-${ts}`, phone: CONTACT_PHONE, contact_name: CONTACT_NAME, is_from_me: false, service: 'iMessage',
    text: "Go for it",
    timestamp: new Date(Date.now() - 300000).toISOString(),
  },
  {
    id: `ck-5-${ts}`, phone: CONTACT_PHONE, contact_name: CONTACT_NAME, is_from_me: false, service: 'iMessage',
    text: "The breaker to the outside circuit is in the stair well",
    timestamp: new Date(Date.now() - 240000).toISOString(),
  },
  {
    id: `ck-6-${ts}`, phone: CONTACT_PHONE, contact_name: CONTACT_NAME, is_from_me: true, service: 'iMessage',
    text: "Sounds good. For this one it's tied to the output power from the individual meter bank (like the one I showed in the office) so it will be located near the bank, not at the common power in the stairwell.",
    timestamp: new Date(Date.now() - 180000).toISOString(),
  },
  {
    id: `ck-7-${ts}`, phone: CONTACT_PHONE, contact_name: CONTACT_NAME, is_from_me: false, service: 'iMessage',
    text: "Do you know which one is the common meter?",
    timestamp: new Date(Date.now() - 120000).toISOString(),
  },
  {
    id: `ck-8-${ts}`, phone: CONTACT_PHONE, contact_name: CONTACT_NAME, is_from_me: true, service: 'iMessage',
    text: "We do not at the moment. I believe there is marking for most of the meters, but I'm unsure which one is common. Do you know?",
    timestamp: new Date(Date.now() - 60000).toISOString(),
  },
];

let stephanToken = '';
let marcoToken = '';
let agentId = '';
let apiKey = '';

test.describe.serial('Forward Conrad Kong texts to Marco', () => {

  test.beforeAll(async () => {
    const ctx = await playwrightRequest.newContext({ baseURL: API_URL });

    // 1. Create / log in as Marco
    const marcoResp = await ctx.post('/v1/auth/dev-marco-login');
    expect(marcoResp.ok(), `dev-marco-login failed: ${await marcoResp.text()}`).toBeTruthy();
    marcoToken = (await marcoResp.json()).access_token;

    // 2. Create / log in as Stephan (admin)
    const stephanResp = await ctx.post('/v1/auth/dev-admin-login');
    expect(stephanResp.ok(), `dev-admin-login failed: ${await stephanResp.text()}`).toBeTruthy();
    stephanToken = (await stephanResp.json()).access_token;

    // 3. Register a Mac agent for Stephan
    const agentResp = await ctx.post('/v1/agent/register', {
      headers: { Authorization: `Bearer ${stephanToken}` },
      data: { name: "Stephan's Mac (Conrad test)" },
    });
    expect(agentResp.ok(), `agent register failed: ${await agentResp.text()}`).toBeTruthy();
    const agentData = await agentResp.json();
    agentId = agentData.agent_id;
    apiKey = agentData.api_key;

    // 4. Inject Conrad Kong's real iMessage thread (same messages visible in Mac app)
    const inboundResp = await ctx.post('/v1/agent/messages/inbound', {
      headers: { Authorization: `Bearer ${apiKey}` },
      data: { agent_id: agentId, messages: MESSAGES },
    });
    expect(inboundResp.ok(), `inbound messages failed: ${await inboundResp.text()}`).toBeTruthy();
    const inboundData = await inboundResp.json();
    expect(inboundData.confirmed).toHaveLength(MESSAGES.length);

    await ctx.dispose();
  });

  test('Conrad Kong conversation exists in Stephan\'s view with contact name', async ({ request }) => {
    const convResp = await request.get(`${API_URL}/v1/conversations`, {
      headers: { Authorization: `Bearer ${stephanToken}` },
    });
    expect(convResp.ok()).toBeTruthy();
    const conversations = await convResp.json();
    const conv = conversations.find((c: { phone: string; contact_name?: string }) =>
      c.phone === CONTACT_PHONE || c.contact_name === CONTACT_NAME
    );
    expect(conv, `No conversation for ${CONTACT_NAME} (${CONTACT_PHONE})`).toBeTruthy();
    expect(conv.message_count).toBeGreaterThanOrEqual(MESSAGES.length);
    expect(conv.contact_name).toBe(CONTACT_NAME);
  });

  test('Stephan forwards Conrad Kong conversation to Marco', async ({ page }) => {
    // Inject Stephan's token — skip UI login
    await page.goto(BASE_URL);
    await page.evaluate((token) => localStorage.setItem('token', token), stephanToken);
    await page.goto(`${BASE_URL}/conversations`);
    await page.waitForLoadState('networkidle');

    await page.screenshot({ path: 'e2e/screenshots/30-stephan-conversations.png', fullPage: true });

    // Find Conrad Kong's conversation row (shows contact_name)
    const convRow = page.locator('div').filter({ hasText: CONTACT_NAME }).first();
    await expect(convRow).toBeVisible({ timeout: 10000 });

    // Click the Forward button for that row
    const forwardBtn = page.getByRole('button', { name: /^Forward$/i }).first();
    await expect(forwardBtn).toBeVisible();
    await forwardBtn.click();

    // ForwardDialog should appear
    await expect(page.getByText('Forward Thread')).toBeVisible();
    await page.screenshot({ path: 'e2e/screenshots/31-forward-dialog-open.png', fullPage: true });

    // Select "Action Needed" mode
    await page.getByRole('button', { name: /Action Needed/i }).click();

    // Select Marco as recipient
    const marcoCheckbox = page.getByLabel(/marco/i);
    if (await marcoCheckbox.count() === 0) {
      const marcoRow = page.locator('label').filter({ hasText: /marco/i }).first();
      await marcoRow.click();
    } else {
      await marcoCheckbox.check();
    }

    await page.screenshot({ path: 'e2e/screenshots/32-marco-selected.png', fullPage: true });

    // Add note for context
    const noteInput = page.getByPlaceholder('Add a note (optional)');
    if (await noteInput.count() > 0) {
      await noteInput.fill('Conrad is asking about the meter bank installation — please coordinate the site walk');
    }

    // Submit forward
    const submitBtn = page.getByRole('button', { name: /Forward to 1 recipient/i });
    await expect(submitBtn).toBeEnabled();
    await submitBtn.click();

    page.on('dialog', async dialog => {
      expect(dialog.message()).toContain('forwarded');
      await dialog.accept();
    });

    await page.waitForTimeout(1000);
    await page.screenshot({ path: 'e2e/screenshots/33-forwarded-success.png', fullPage: true });
  });

  test('Marco logs in and sees Conrad Kong thread in inbox', async ({ page }) => {
    await page.goto(`${BASE_URL}/login`);
    await page.waitForLoadState('networkidle');
    await page.screenshot({ path: 'e2e/screenshots/40-marco-login.png', fullPage: true });

    // Click "Sign in as marco" button
    const devLoginBtn = page.getByRole('button', { name: /sign in as marco/i });
    await expect(devLoginBtn).toBeVisible();
    await devLoginBtn.click();

    await page.waitForURL(`${BASE_URL}/`);
    await page.waitForLoadState('networkidle');
    await page.screenshot({ path: 'e2e/screenshots/41-marco-inbox.png', fullPage: true });

    await expect(page.getByText(/Marco/)).toBeVisible();

    // Conrad Kong's thread should appear in inbox
    const threadCard = page.locator('*').filter({ hasText: CONTACT_NAME }).first();
    await expect(threadCard).toBeVisible({ timeout: 10000 });

    await page.screenshot({ path: 'e2e/screenshots/42-marco-inbox-with-conrad.png', fullPage: true });
  });

  test('Marco opens Conrad Kong thread and sees all messages', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.evaluate((token) => localStorage.setItem('token', token), marcoToken);
    await page.goto(`${BASE_URL}/`);
    await page.waitForLoadState('networkidle');

    // Click the thread card link
    const threadLink = page.getByRole('link').filter({ hasText: CONTACT_NAME }).first();
    await expect(threadLink).toBeVisible({ timeout: 10000 });
    await threadLink.click();

    await page.waitForURL(/\/inbox\//);
    await page.waitForLoadState('networkidle');
    await page.screenshot({ path: 'e2e/screenshots/43-marco-thread-view.png', fullPage: true });

    // Thread header shows Conrad Kong's name
    await expect(page.locator('h2.font-semibold')).toContainText(CONTACT_NAME);

    // "Action Needed" badge
    await expect(page.getByText('Action Needed')).toBeVisible();

    // Note contains the coordination text
    await expect(page.getByText(/meter bank installation/).first()).toBeVisible();

    // Key messages visible
    await expect(page.getByText('Sure').first()).toBeVisible();
    await expect(page.getByText('Go for it').first()).toBeVisible();
    await expect(page.getByText(/breaker to the outside circuit/)).toBeVisible();
    await expect(page.getByText(/Do you know which one is the common meter/).first()).toBeVisible();

    // "Forwarded by Stephan" attribution
    await expect(page.getByText(/Forwarded by Stephan/i)).toBeVisible();

    // Reply box present
    const replyBox = page.locator('textarea, input[type="text"]').last();
    await expect(replyBox).toBeVisible();

    await page.screenshot({ path: 'e2e/screenshots/44-marco-thread-verified.png', fullPage: true });
  });
});
