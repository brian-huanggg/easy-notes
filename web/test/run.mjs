// 單元測試：esbuild 打包 test/*.test.ts 後交給 node --test（不需要瀏覽器）
// 用法：pnpm test
import * as esbuild from "esbuild";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const files = readdirSync("test").filter((f) => f.endsWith(".test.ts"));
// node --test 不執行 node_modules 內的檔案，所以輸出到暫存資料夾
const outdir = mkdtempSync(join(tmpdir(), "easynotes-test-"));
await esbuild.build({
  entryPoints: files.map((f) => `test/${f}`),
  outdir,
  bundle: true,
  format: "esm",
  platform: "node",
  outExtension: { ".js": ".mjs" },
  // i18n 在載入時讀 window.__locale
  banner: { js: "globalThis.window ??= globalThis;" },
  logLevel: "warning",
});
const result = spawnSync(process.execPath, ["--test", ...files.map((f) => join(outdir, f.replace(/\.ts$/, ".mjs")))], {
  stdio: "inherit",
});
process.exit(result.status ?? 1);
