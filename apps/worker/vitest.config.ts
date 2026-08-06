import { defineConfig } from "vitest/config";
import { resolve } from "node:path";

export default defineConfig({
  test: {
    include: ["src/**/*.test.ts"],
    setupFiles: [resolve(__dirname, "vitest.setup.ts")],
  },
});
