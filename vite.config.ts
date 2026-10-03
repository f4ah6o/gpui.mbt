import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { defineConfig } from "vite-plus";
import moonbit from "vite-plugin-moonbit";

const repoRoot = fileURLToPath(new URL(".", import.meta.url));
const siteRoot = resolve(repoRoot, "examples/browser/site");

function initialMoonBitBuild() {
  return {
    name: "gpui-initial-moonbit-build",
    enforce: "pre",
    configResolved() {
      execFileSync(
        process.env.MOON_BIN || "moon",
        ["build", "examples/browser", "--target", "js", "--release", "--deny-warn"],
        { cwd: repoRoot, stdio: "inherit" },
      );
    },
  };
}

export default defineConfig({
  root: siteRoot,
  base: "./",
  plugins: [
    initialMoonBitBuild(),
    moonbit({
      root: repoRoot,
      target: "js",
      mode: "release",
    }),
  ],
  build: {
    outDir: resolve(repoRoot, "_build/browser-site"),
    emptyOutDir: true,
    sourcemap: true,
  },
  check: {
    // MoonBit's formatter remains authoritative for this repository. Avoid
    // reformatting the existing Markdown/document corpus as part of browser CI.
    fmt: false,
  },
  lint: {
    ignorePatterns: ["node_modules/**", "_build/**"],
  },
  server: {
    fs: {
      allow: [repoRoot],
    },
  },
});
