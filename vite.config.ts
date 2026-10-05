import { execFileSync } from "node:child_process";
import { watch } from "node:fs";
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
      for (const entry of ["examples/browser", "examples/browser_board"]) {
        execFileSync(
          process.env.MOON_BIN || "moon",
          [
            "build",
            entry,
            "--target",
            "js",
            mode === "release" ? "--release" : "--debug",
            "--deny-warn",
          ],
          { cwd: repoRoot, stdio: "inherit" },
        );
      }
    },
  };
}

// vite-plugin-moonbit owns the MoonBit watch build. Its generated-output watcher
// can observe the file event after the build-complete signal, leaving its HMR
// batch empty for that cycle. Keep the plugin as the compiler/watch bridge and
// add a Vite-side refresh guard that invalidates loaded mbt: modules whenever
// the generated debug JavaScript changes.
function moonbitDevRefreshGuard() {
  let buildWatcher;
  let reloadTimer;

  return {
    name: "gpui-moonbit-dev-refresh-guard",
    apply: "serve",
    configureServer(server) {
      const buildDir = resolve(repoRoot, "_build/js/debug/build");

      buildWatcher = watch(
        buildDir,
        { recursive: true },
        (_eventType, filename) => {
          if (!filename || !filename.toString().endsWith(".js")) return;

          if (reloadTimer) clearTimeout(reloadTimer);
          reloadTimer = setTimeout(() => {
            let invalidated = 0;
            for (const [id, mod] of server.moduleGraph.idToModuleMap.entries()) {
              if (!id.startsWith("\0mbt:")) continue;
              server.moduleGraph.invalidateModule(mod);
              invalidated += 1;
            }

            if (invalidated === 0) return;

            server.config.logger.info(
              `[gpui-moonbit-refresh] invalidated ${invalidated} MoonBit module(s); full reload`,
            );
            server.ws.send({ type: "full-reload", path: "*" });
          }, 50);
        },
      );

      server.httpServer?.once("close", () => {
        if (reloadTimer) clearTimeout(reloadTimer);
        buildWatcher?.close();
      });
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
      moonbitDevRefreshGuard(),
    ],
    build: {
      outDir: resolve(repoRoot, "_build/browser-site"),
      emptyOutDir: true,
      sourcemap: true,
      rollupOptions: {
        input: {
          board: resolve(siteRoot, "index.html"),
          proof: resolve(siteRoot, "proof.html"),
        },
      },
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
