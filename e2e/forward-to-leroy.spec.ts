import { test, expect, request as playwrightRequest } from '@playwright/test';

const BASE_URL = 'http://localhost:5173';
const API_URL = 'http://localhost:8001';

// Test data
const TEST_PHONE = '34913';
const MESSAGES = [
  { id: `msg-34913-1-${Date.now()}`, phone: TEST_PHONE, text: 'Hey I need help with my account', timestamp: new Date(Date.now() - 60000).toISOString(), is_from_me: false },
  { id: `msg-34913-2-${Date.now()}`, phone: TEST_PHONE, text: 'Is anyone there?', timestamp: new Date(Date.now() - 30000).toISOString(), is_from_me: false },
  { id: `msg-34913-3-${Date.now()}`, phone: TEST_PHONE, text: 'Please call me back ASAP', timestamp: new Date().toISOString(), is_from_me: false },
];

let stephanToken = '';
let leroyToken = '';
let agentId = '';
let apiKey = '';

test.describe.serial('Forward texts from 34913 to Leroy', () => {

  test.beforeAll(async () => {
    // Use a raw HTTP request context (not browser) to set up test data
    const ctx = await playwrightRequest.newContext({ baseURL: API_URL });

    // 1. Create / log in as Leroy (so the user exists in DB for the forward dialog)
    const leroyResp = await ctx.post('/v1/auth/dev-login');
    expect(leroyResp.ok(), `dev-login failed: ${await leroyResp.text()}`).toBeTruthy();
    leroyToken = (await leroyResp.json()).access_token;

    // 2. Create / log in as Stephan (admin — owns the Mac agent / conversations)
    const stephanResp = await ctx.post('/v1/auth/dev-admin-login');
    expect(stephanResp.ok(), `dev-admin-login failed: ${await stephanResp.text()}`).toBeTruthy();
    stephanToken = (await stephanResp.json()).access_token;

    // 3. Register a Mac agent for Stephan
    const agentResp = await ctx.post('/v1/agent/register', {
      headers: { Authorization: `Bearer ${stephanToken}` },
      data: { name: 'Stephan\'s Mac (test)' },
    });
    expect(agentResp.ok(), `agent register failed: ${await agentResp.text()}`).toBeTruthy();
    const agentData = await agentResp.json();
    agentId = agentData.agent_id;
    apiKey = agentData.api_key;

    // 4. Inject 3 messages from 34913 (simulating what the Mac app would sync)
    const inboundResp = await ctx.post('/v1/agent/messages/inbound', {
      headers: { Authorization: `Bearer ${apiKey}` },
      data: { agent_id: agentId, messages: MESSAGES },
    });
    expect(inboundResp.ok(), `inbound messages failed: ${await inboundResp.text()}`).toBeTruthy();
    const inboundData = await inboundResp.json();
    expect(inboundData.confirmed).toHaveLength(MESSAGES.length);

    await ctx.dispose();
  });

  test('Mac agent is registered and messages from 34913 are synced', async ({ request }) => {
    // Verify via API that the conversation exists
    const convResp = await request.get(`${API_URL}/v1/conversations`, {
      headers: { Authorization: `Bearer ${stephanToken}` },
    });
    expect(convResp.ok()).toBeTruthy();
    const conversations = await convResp.json();
    const conv = conversations.find((c: { phone: string }) => c.phone === TEST_PHONE);
    expect(conv, `No conversation for phone ${TEST_PHONE}`).toBeTruthy();
    expect(conv.message_count).toBeGreaterThanOrEqual(MESSAGES.length);
  });

  test('Stephan logs in and forwards 34913 conversation to Leroy', async ({ page }) => {
    // Inject Stephan's token directly so we skip the UI login form
    await page.goto(BASE_URL);
    await page.evaluate((token) => localStorage.setItem('token', token), stephanToken);

    // Navigate to Conversations page
    await page.goto(`${BASE_URL}/conversations`);
    await page.waitForLoadState('networkidle');

    await page.screenshot({ path: 'e2e/screenshots/10-stephan-conversations.png', fullPage: true });

    // Find the row for 34913
    const row34913 = page.locator('div').filter({ hasText: TEST_PHONE }).first();
    await expect(row34913).toBeVisible({ timeout: 10000 });

    // Click the Forward button in that row
    const forwardBtn = page.getByRole('button', { name: /^Forward$/i }).first();
    await expect(forwardBtn).toBeVisible();
    await forwardBtn.click();

    // ForwardDialog should appear
    await expect(page.getByText('Forward Thread')).toBeVisible();
    await page.screenshot({ path: 'e2e/screenshots/11-forward-dialog-open.png', fullPage: true });

    // Select "Action Needed" mode
    await page.getByRole('button', { name: /Action Needed/i }).click();

    // Select Leroy as recipient (check his checkbox)
    const leroyCheckbox = page.getByLabel(/leroy/i);
    if (await leroyCheckbox.count() === 0) {
      // Fallback: find by text then check its checkbox sibling
      const leroyRow = page.locator('label').filter({ hasText: /leroy/i }).first();
      await leroyRow.click();
    } else {
      await leroyCheckbox.check();
    }

    await page.screenshot({ path: 'e2e/screenshots/12-leroy-selected.png', fullPage: true });

    // Add an optional note
    await page.getByPlaceholder('Add a note (optional)').fill('Please follow up with this customer from 34913');

    // Click the forward button
    const submitBtn = page.getByRole('button', { name: /Forward to 1 recipient/i });
    await expect(submitBtn).toBeEnabled();
    await submitBtn.click();

    // Success alert
    page.on('dialog', async dialog => {
      expect(dialog.message()).toContain('forwarded');
      await dialog.accept();
    });

    await page.waitForTimeout(1000);
    await page.screenshot({ path: 'e2e/screenshots/13-forwarded-success.png', fullPage: true });
  });

  test('Leroy logs in and sees the forwarded thread from 34913 in his inbox', async ({ page }) => {
    // Navigate to login page and use the UI dev login
    await page.goto(`${BASE_URL}/login`);
    await page.waitForLoadState('networkidle');
    await page.screenshot({ path: 'e2e/screenshots/20-leroy-login.png', fullPage: true });

    // Click "Sign in as leroy" button
    const devLoginBtn = page.getByRole('button', { name: /sign in as leroy/i });
    await expect(devLoginBtn).toBeVisible();
    await devLoginBtn.click();

    // Should redirect to inbox (/)
    await page.waitForURL(`${BASE_URL}/`);
    await page.waitForLoadState('networkidle');
    await page.screenshot({ path: 'e2e/screenshots/21-leroy-inbox.png', fullPage: true });

    // Verify Leroy's name is visible in the sidebar
    const bodyText = await page.textContent('body');
    expect(bodyText).toContain('Leroy');

    // The inbox should contain the forwarded thread from 34913
    const threadCard = page.locator('*').filter({ hasText: TEST_PHONE }).first();
    await expect(threadCard).toBeVisible({ timeout: 10000 });

    await page.screenshot({ path: 'e2e/screenshots/22-leroy-inbox-with-thread.png', fullPage: true });
  });

  test('Leroy opens the thread and sees all messages from 34913', async ({ page }) => {
    // Login as Leroy via token injection (faster for subsequent tests)
    await page.goto(BASE_URL);
    await page.evaluate((token) => localStorage.setItem('token', token), leroyToken);
    await page.goto(`${BASE_URL}/`);
    await page.waitForLoadState('networkidle');

    // Find and click the thread card link (ThreadCard renders as <a> via react-router Link)
    const threadLink = page.getByRole('link').filter({ hasText: TEST_PHONE }).first();
    await expect(threadLink).toBeVisible({ timeout: 10000 });
    await threadLink.click();

    // Wait for thread view to load (URL changes to /inbox/:threadId)
    await page.waitForURL(/\/inbox\//);
    await page.waitForLoadState('networkidle');
    await page.screenshot({ path: 'e2e/screenshots/23-thread-view.png', fullPage: true });

    // Verify the thread header shows 34913 (ThreadViewPage uses h2 for name)
    // The h2 shows contact_name || phone — since no contact name, shows "34913"
    await expect(page.locator('h2.font-semibold')).toContainText(TEST_PHONE);

    // Verify "Action Needed" badge is shown (it's a <span> in the header)
    await expect(page.getByText('Action Needed')).toBeVisible();

    // Verify the note is visible
    await expect(page.getByText(/follow up with this customer from 34913/)).toBeVisible();

    // Verify all message texts are shown
    for (const msg of MESSAGES) {
      await expect(page.getByText(msg.text)).toBeVisible();
    }

    // Verify forwarded-by attribution (shows "Forwarded by Stephan")
    await expect(page.getByText(/Forwarded by Stephan/i)).toBeVisible();

    // Verify the reply box is visible (since mode is "action")
    const replyBox = page.locator('textarea, input[type="text"]').last();
    await expect(replyBox).toBeVisible();

    await page.screenshot({ path: 'e2e/screenshots/24-thread-messages-verified.png', fullPage: true });
  });
});
