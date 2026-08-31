import { defineConfig, mergeConfig } from "vitest/config";
import viteConfig from "./vite.config";

// Vitest-only config, kept out of vite.config.ts so that file can import
// `defineConfig` from "vite" (not "vitest/config"). Merges the app's
// plugins in so tests still build the same way the app does.
export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: "happy-dom",
      include: ["src/**/*.test.{ts,tsx}"],
      // vendor/auth-client is a vendored git submodule (dist/ committed, no
      // build step) — never run under this app's test config.
      exclude: ["**/node_modules/**", "vendor/**"],
    },
  }),
);
