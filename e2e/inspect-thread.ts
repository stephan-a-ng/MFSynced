/**
 * One-off inspection script: logs in as Leroy, opens the 34913 inbox thread,
 * screenshots it, and dumps the rendered group-separator text so we can confirm
 * whether date separators appear.
 *
 * Run with:  npx ts-node --esm e2e/inspect-thread.ts
 * OR:        npx playwright test --config e2e/inspect-thread.config.ts
 */
import { chromium } from 'playwright';

const STAGING_URL = 'https://mfsynced-dashboard-staging-329274314764.us-central1.run.app';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  page.setViewportSize({ width: 1200, height: 900 });

  // 1. Login as Leroy
  await page.goto(STAGING_URL + '/login');
  await page.waitForLoadState('networkidle');
  await page.getByRole('button', { name: /sign in as leroy/i }).click();
  await page.waitForURL('**/');
  await page.waitForLoadState('networkidle');

  // 2. Find and click the 34913 thread
  const thread = page.getByText('34913').first();
  await thread.click();
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(1500); // let messages render

  // 3. Screenshot the full thread view
  await page.screenshot({ path: 'e2e/screenshots/thread-34913.png', fullPage: true });
  console.log('Screenshot saved to e2e/screenshots/thread-34913.png');

  // 4. Dump the text of any date-separator <p> elements
  const separators = await page.$$eval(
    'p.text-center.text-\\[11px\\].text-muted-foreground',
    els => els.map(el => el.textContent),
  );
  console.log('Date separator labels found:', separators.length);
  separators.forEach((s, i) => console.log(`  [${i}] ${s}`));

  // 5. Also dump the raw API response for messages to check timestamps
  const apiResp = await page.evaluate(async () => {
    // Extract thread ID from the current URL
    const match = location.pathname.match(/inbox\/([a-f0-9-]+)/);
    if (!match) return null;
    const threadId = match[1];
    const token = document.cookie.match(/token=([^;]+)/)?.[1]
      ?? localStorage.getItem('token')
      ?? sessionStorage.getItem('token');
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = `Bearer ${token}`;
    const r = await fetch(`/v1/inbox/${threadId}`, { headers });
    const data = await r.json();
    return {
      messageCount: data.messages?.length,
      firstTimestamp: data.messages?.[0]?.timestamp,
      lastTimestamp: data.messages?.[data.messages.length - 1]?.timestamp,
      allTimestamps: data.messages?.map((m: { timestamp: string }) => m.timestamp),
    };
  });
  console.log('API message info:', JSON.stringify(apiResp, null, 2));

  await browser.close();
})();
