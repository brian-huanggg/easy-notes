// 注音組字中收到遠端內容（同步或外部工具）：組字不被打斷、注音符號不留在文件裡、選好的字不遺失。
// 在 Chromium 以 DevTools 的 Input.imeSetComposition 模擬輸入法（WebKit 的實作不同，實機仍需驗證）。
// 需要 Playwright（不列為相依套件）：npm i --no-save playwright && npx playwright install chromium
// 用法：npm run build && node test/ime.e2e.mjs
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

let chromium;
try {
  ({ chromium } = createRequire(import.meta.url)("playwright"));
} catch {
  console.log("skip: 找不到 playwright（見檔案開頭的說明）");
  process.exit(0);
}

const page = fileURLToPath(new URL("../../Packages/KindMarkdown/Sources/KindMarkdown/Resources/Editor/index.html", import.meta.url));

// 第一行行尾組字「ㄓㄨㄥ」→ 組字中收到 remote →「ㄓㄨㄥˉ」→ 選「中」
const cases = [
  ["遠端改別行", "一\n二（遠端）\n", "一中\n二（遠端）\n"],
  ["遠端在同一行前面插入", "遠端一\n二\n", "遠端一中\n二\n"],
  ["遠端在前面加一行", "零\n一\n二\n", "零\n一中\n二\n"],
  ["遠端變更範圍涵蓋組字位置", "零一\n二（遠端）\n", null],
];

const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
let failed = 0;
for (const [name, remote, expected] of cases) {
  const tab = await browser.newPage();
  const saved = [];
  tab.on("console", async (m) => {
    const msg = await m.args()[1]?.jsonValue().catch(() => null);
    if (msg?.type === "changed") saved.push(msg.text);
  });
  await tab.goto(`file://${page}`);
  await tab.waitForFunction(() => window.editor);
  await tab.evaluate(() => window.editor.load("a.md", "一\n二\n"));
  await tab.click(".cm-line >> nth=0");
  await tab.keyboard.press("End");
  const cdp = await tab.context().newCDPSession(tab);
  await cdp.send("Input.imeSetComposition", { text: "ㄓㄨㄥ", selectionStart: 3, selectionEnd: 3 });
  await tab.evaluate((r) => window.editor.applyRemote("a.md", r), remote);
  await cdp.send("Input.imeSetComposition", { text: "ㄓㄨㄥˉ", selectionStart: 4, selectionEnd: 4 });
  await cdp.send("Input.insertText", { text: "中" });
  await tab.waitForTimeout(400);
  await tab.evaluate(() => window.editor.flush());
  await tab.waitForTimeout(100);
  const text = saved.at(-1) ?? "";
  // 範圍涵蓋組字位置時，選好的字放在變更範圍之後；只檢查沒有注音符號、字沒有遺失
  const ok = !/[ㄅ-ㄩˉˊˇˋ˙]/.test(text) && text.includes("中") && (expected === null || text === expected);
  if (!ok) failed++;
  console.log(`${ok ? "ok" : "FAIL"} - ${name}: ${JSON.stringify(text)}`);
  await tab.close();
}
await browser.close();
process.exit(failed ? 1 : 0);
