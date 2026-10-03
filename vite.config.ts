import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { defineConfig } from "vite-plus";
import moonbit from "vite-plugin-moonbit";

const repoRoot = fileURLToPath(new URL(".", import.meta.url));
const siteRoot = resolve(repoRoot, "examples/browser/site");

function initialMoonBitBuild(mode: "debug" | "release") {
  return {
    name: "gpui-initial-moonbit-build",
    enforce: "pre",
    configResolved() {
      execFileSync(
        process.env.MOON_BIN || "moon",
        [
          "build",
          "examples/browser",
          "--target",
          "js",
          mode === "release" ? "--release" : "--debug",
          "--deny-warn",
        ],
        { cwd: repoRoot, stdio: "inherit" },
      );
    },
  };
}

export default defineConfig(({ command }) => {
  const moonMode = command === "serve" ? "debug" : "release";

  return {
    root: siteRoot,
    base: "./",
    plugins: [
      initialMoonBitBuild(moonMode),
      moonbit({
        root: repoRoot,
        target: "js",
        mode: moonMode,
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
  };
});
