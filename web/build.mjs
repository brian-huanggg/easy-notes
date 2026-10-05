// 每個 WebView 外掛一個 entry，輸出到該外掛的 SPM Resources（Bundle.module 載入）
// 用法：node build.mjs [--watch]
import * as esbuild from "esbuild";
import { copyFileSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";

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

// KaTeX（數學公式）：編輯器第一次遇到公式時才載入（src/markdown/math.ts），不打包進 editor.js。
// 字型只帶 woff2（WebKit 都支援），CSS 裡的 woff / ttf 備援拿掉
const katexDir = "../Packages/KindMarkdown/Sources/KindMarkdown/Resources/Editor/katex";
rmSync(katexDir, { recursive: true, force: true });
mkdirSync(`${katexDir}/fonts`, { recursive: true });
copyFileSync("node_modules/katex/dist/katex.min.js", `${katexDir}/katex.min.js`);
copyFileSync("node_modules/katex/LICENSE", `${katexDir}/LICENSE`);
const css = readFileSync("node_modules/katex/dist/katex.min.css", "utf8").replace(/,url\([^)]*\.(?:woff|ttf)\) format\("(?:woff|truetype)"\)/g, "");
writeFileSync(`${katexDir}/katex.min.css`, css);
for (const font of readdirSync("node_modules/katex/dist/fonts").filter((f) => f.endsWith(".woff2"))) {
  copyFileSync(`node_modules/katex/dist/fonts/${font}`, `${katexDir}/fonts/${font}`);
}
console.log(`copied ${katexDir}`);
