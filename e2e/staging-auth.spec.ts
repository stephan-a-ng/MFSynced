import { test, expect } from '@playwright/test';

const STAGING_URL = 'https://mfsynced-dashboard-staging-329274314764.us-central1.run.app';

test.describe('Staging Auth Bypass', () => {
  test('login page shows dev login button', async ({ page }) => {
    await page.goto(STAGING_URL + '/login');
    await page.waitForLoadState('networkidle');

    // Screenshot the login page
    await page.screenshot({ path: 'e2e/screenshots/01-login-page.png', fullPage: true });

    // Should show the dev login button
    const devLoginButton = page.getByRole('button', { name: /sign in as leroy/i });
    await expect(devLoginButton).toBeVisible();

    // Should NOT show the Google sign-in button
    const googleButton = page.getByRole('button', { name: /sign in with google/i });
    await expect(googleButton).not.toBeVisible();
  });

  test('dev login works end-to-end', async ({ page }) => {
    await page.goto(STAGING_URL + '/login');
    await page.waitForLoadState('networkidle');

    // Click dev login
    const devLoginButton = page.getByRole('button', { name: /sign in as leroy/i });
    await devLoginButton.click();

    // Should navigate to dashboard after login
    await page.waitForURL('**/');
    await expect(page).not.toHaveURL(/\/login/);

    // Wait for the page to fully load
    await page.waitForLoadState('networkidle');
    await page.screenshot({ path: 'e2e/screenshots/02-dashboard.png', fullPage: true });

    // Should show the user's name or email somewhere in the layout
    const pageContent = await page.textContent('body');
    expect(pageContent).toContain('Leroy');
  });

  test('authenticated pages are accessible after login', async ({ page }) => {
    // Login first
    await page.goto(STAGING_URL + '/login');
    await page.waitForLoadState('networkidle');
    const devLoginButton = page.getByRole('button', { name: /sign in as leroy/i });
    await devLoginButton.click();
    await page.waitForURL('**/');
    await page.waitForLoadState('networkidle');

    // Navigate to conversations
    const conversationsLink = page.getByRole('link', { name: /conversations/i });
    if (await conversationsLink.isVisible()) {
      await conversationsLink.click();
      await page.waitForLoadState('networkidle');
      await page.screenshot({ path: 'e2e/screenshots/03-conversations.png', fullPage: true });
    }
  });
});
