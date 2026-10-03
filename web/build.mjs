// 每個 WebView 外掛一個 entry，輸出到該外掛的 SPM Resources（Bundle.module 載入）
// 用法：node build.mjs [--watch]
import * as esbuild from "esbuild";

const entries = [
  { in: "src/markdown/main.ts", out: "../Packages/KindMarkdown/Sources/KindMarkdown/Resources/Editor/editor.js" },
  { in: "src/sheet/main.ts", out: "../Packages/KindSheet/Sources/KindSheet/Resources/Sheet/sheet.js" },
];

const watch = process.argv.includes("--watch");
const common = { bundle: true, format: "iife", target: "safari17" };

for (const entry of entries) {
  const options = {
    ...common,
    entryPoints: [entry.in],
    outfile: entry.out,
    ...(watch ? { sourcemap: "inline" } : { minify: true }),
  };
  if (watch) {
    const ctx = await esbuild.context(options);
    await ctx.watch();
    console.log(`watching ${entry.in}`);
  } else {
    await esbuild.build(options);
    console.log(`built ${entry.out}`);
  }
}
