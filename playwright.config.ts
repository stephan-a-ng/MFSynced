import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  timeout: 60000,
  use: {
    browserName: 'chromium',
    headless: true,
    baseURL: 'http://localhost:5173',
  },
  projects: [
    {
      name: 'local',
      testMatch: /forward-to-(leroy|marco)\.spec\.ts/,
      use: { baseURL: 'http://localhost:5173' },
    },
    {
      name: 'staging',
      testMatch: /staging-auth\.spec\.ts/,
    },
    {
      name: 'sync-fyi',
      testMatch: /sync-and-fyi\.spec\.ts/,
    },
  ],
});
