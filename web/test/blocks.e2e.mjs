// 表格、數學公式、屬性面板、多行卡片的語法標示：在 Chromium 實際點擊、打字、注音組字，檢查寫回的 md。
// 注音以 DevTools 的 Input.imeSetComposition 模擬（WebKit 的實作不同，實機仍需驗證）。
// 需要 Playwright（不列為相依套件）：npm i --no-save playwright && npx playwright install chromium
// 用法：npm run build && node test/blocks.e2e.mjs
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
const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
let failed = 0;

async function open(text) {
  const tab = await browser.newPage();
  const saved = [];
  const messages = [];
  tab.on("console", async (m) => {
    const msg = await m.args()[1]?.jsonValue().catch(() => null);
    if (msg?.type === "changed") saved.push(msg.text);
    if (msg?.type) messages.push(msg);
  });
  tab.on("pageerror", (e) => console.log("pageerror", e.message));
  await tab.goto(`file://${page}`);
  await tab.waitForFunction(() => window.editor);
  await tab.evaluate((t) => window.editor.load("a.md", t), text);
  const doc = async () => {
    await tab.evaluate(() => window.editor.flush());
    await tab.waitForTimeout(50);
    return saved.at(-1) ?? text;
  };
  return { tab, doc, messages, cdp: await tab.context().newCDPSession(tab) };
}

function check(name, ok, detail = "") {
  if (!ok) failed++;
  console.log(`${ok ? "ok" : "FAIL"} - ${name}${ok ? "" : " " + detail}`);
}

const TABLE = "前文\n\n| 名稱 | 數量 |\n| --- | ---: |\n| 蘋果 | 3 |\n\n後文\n";

{
  const { tab, doc, cdp } = await open(TABLE);
  check("表格顯示成格子", (await tab.locator(".cm-table td, .cm-table th").count()) === 4);
  const cell = tab.locator('.cm-table-cell[data-row="1"][data-col="0"]');
  await cell.click();
  await tab.keyboard.press("End");
  await tab.keyboard.type("派");
  let text = await doc();
  check("改一格只動那一格", text === TABLE.replace("蘋果", "蘋果派"), JSON.stringify(text));

  // 注音組字：組字中不改動文件，選字後寫回
  await cdp.send("Input.imeSetComposition", { text: "ㄌㄧˊ", selectionStart: 3, selectionEnd: 3 });
  const during = await tab.evaluate(() => document.querySelector(".cm-table") !== null);
  await cdp.send("Input.insertText", { text: "梨" });
  await tab.waitForTimeout(100);
  text = await doc();
  check("格子內注音組字", during && text === TABLE.replace("蘋果", "蘋果派梨") && !/[ㄅ-ㄩˉˊˇˋ˙]/.test(text), JSON.stringify(text));
  check("焦點留在格子", await tab.evaluate(() => document.activeElement?.classList.contains("cm-table-cell")));

  // Tab 移到下一格；最後一格 Tab 新增一列
  await tab.keyboard.press("Tab");
  await tab.keyboard.type("5");
  await tab.keyboard.press("Tab");
  await tab.keyboard.type("香蕉");
  text = await doc();
  check("Tab 移動並在最後新增一列", text === "前文\n\n| 名稱 | 數量 |\n| --- | ---: |\n| 蘋果派梨 | 35 |\n| 香蕉 |  |\n\n後文\n", JSON.stringify(text));

  // 「+」新增欄
  await tab.hover(".cm-table");
  await tab.locator(".cm-table-add-col").dispatchEvent("mousedown");
  await tab.keyboard.type("產地");
  text = await doc();
  check("新增欄", text.includes("| 名稱 | 數量 | 產地 |\n| --- | ---: | --- |"), JSON.stringify(text));

  // 選單：刪除列
  await tab.locator('.cm-table-cell[data-row="2"][data-col="0"]').click();
  await tab.locator('.cm-table-more[data-row="2"][data-col="0"]').dispatchEvent("mousedown");
  await tab.locator(".cm-table-menu-item", { hasText: "刪除列" }).dispatchEvent("mousedown");
  text = await doc();
  check("選單刪除列", !text.includes("香蕉") && text.includes("| 蘋果派梨 | 35 |"), JSON.stringify(text));

  // Escape 離開表格，游標在表格下一行
  await tab.locator('.cm-table-cell[data-row="0"][data-col="0"]').click();
  await tab.keyboard.press("Escape");
  await tab.keyboard.type("X");
  text = await doc();
  check("Escape 離開表格", /\|\n(\| [^\n]*\n)?X\n後文/.test(text) || text.includes("|\nX"), JSON.stringify(text));
  await tab.close();
}

{
  // 格內 md：沒在編輯時渲染，點進去改顯示原始文字
  const md = "| a | b |\n| --- | --- |\n| **粗** | `x` |\n";
  const { tab, doc } = await open(md);
  const cell = tab.locator('.cm-table-cell[data-row="1"][data-col="0"]');
  check("格內粗體渲染", (await cell.locator("strong").count()) === 1);
  await cell.click();
  check("編輯時顯示原始 md", (await cell.textContent()) === "**粗**");
  await tab.keyboard.type("體");
  await tab.locator('.cm-table-cell[data-row="1"][data-col="1"]').click();
  const text = await doc();
  check("離開格子後寫回並重新渲染", text === md.replace("**粗**", "**粗**體") && (await cell.locator("strong").count()) === 1, JSON.stringify(text));
  await tab.close();
}

{
  // 游標移進表格：顯示原始 md
  const { tab } = await open(TABLE);
  await tab.evaluate(() => window.editor.revealLine("a.md", 3));
  await tab.waitForTimeout(100);
  check("游標在表格內顯示原始 md", (await tab.locator(".cm-table").count()) === 0);
  await tab.close();
}

{
  // 工具列插入表格：焦點在第一個欄名
  const { tab, doc } = await open("內容\n");
  await tab.click(".cm-line >> nth=0");
  await tab.evaluate(() => window.editor.exec("table"));
  await tab.keyboard.type("姓名");
  const text = await doc();
  check("插入表格後直接打欄名", text.startsWith("內容\n| 姓名 | 欄位 2 | 欄位 3 |\n| --- | --- | --- |\n|  |  |  |\n"), JSON.stringify(text));
  await tab.close();
}

{
  const { tab } = await open("行內 $E=mc^2$ 公式，價格 $5 和 $10 不是公式。\n\n$$\n\\int_0^1 x\\,dx = \\frac12\n$$\n\n結尾\n");
  await tab.waitForFunction(() => document.querySelectorAll(".cm-math .katex").length >= 2, null, { timeout: 5000 }).catch(() => {});
  check("行內公式以 KaTeX 渲染", (await tab.locator("span.cm-math .katex").count()) === 1);
  check("區塊公式以 KaTeX 渲染", (await tab.locator(".cm-math-block .katex-display").count()) === 1);
  check("$5 和 $10 不是公式", (await tab.locator(".cm-content").innerText()).includes("$5 和 $10"));
  check("KaTeX 字型載入", await tab.evaluate(async () => (await document.fonts.ready, [...document.fonts].some((f) => f.family.includes("KaTeX") && f.status === "loaded"))));
  await tab.evaluate(() => window.editor.revealLine("a.md", 3));
  await tab.waitForTimeout(100);
  check("游標在區塊公式內：原始碼 + 預覽", (await tab.locator(".cm-lp-math-src").count()) === 3 && (await tab.locator(".cm-math-block").count()) === 1);
  await tab.close();
}

const FRONT = "---\ntitle: 舊標題\ntags:\n  - 讀書\npinned: false\nicon: sf:map\n---\n# 筆記\n\n內文\n";

{
  const { tab, doc, cdp, messages } = await open(FRONT);
  check("屬性面板在標題下方", await tab.evaluate(() => {
    const title = document.querySelector(".cm-doc-title");
    const props = document.querySelector(".cm-props");
    return !!title && !!props && title.compareDocumentPosition(props) & Node.DOCUMENT_POSITION_FOLLOWING;
  }));
  check("icon 不顯示在面板", (await tab.locator('.cm-prop[data-key="icon"]').count()) === 0 && (await tab.locator(".cm-prop").count()) === 3);

  const input = tab.locator('.cm-prop[data-key="title"] .cm-prop-input');
  await input.click();
  await input.press("End");
  await cdp.send("Input.imeSetComposition", { text: "ㄒㄧㄣ", selectionStart: 3, selectionEnd: 3 });
  await cdp.send("Input.insertText", { text: "新" });
  await tab.waitForTimeout(100);
  let text = await doc();
  check("屬性值注音組字", text === FRONT.replace("舊標題", "舊標題新"), JSON.stringify(text));
  check("焦點留在輸入框", await tab.evaluate(() => document.activeElement?.classList.contains("cm-prop-input")));

  await tab.locator('.cm-prop[data-key="pinned"] .cm-prop-check').dispatchEvent("mousedown");
  text = await doc();
  check("核取方塊", text.includes("pinned: true\n"), JSON.stringify(text));

  const chip = tab.locator('.cm-prop[data-key="tags"] .cm-prop-chip-input');
  await chip.click();
  await chip.type("數學");
  await chip.press("Enter");
  text = await doc();
  check("新增標籤", text.includes("tags:\n  - 讀書\n  - 數學\n"), JSON.stringify(text));
  await tab.locator('.cm-prop[data-key="tags"] .cm-prop-chip-text', { hasText: "讀書" }).dispatchEvent("mousedown");
  await tab.waitForTimeout(50);
  check("點標籤開啟標籤頁", messages.some((m) => m.type === "openTag" && m.tag === "讀書"));

  await tab.locator(".cm-props-add").dispatchEvent("mousedown");
  await tab.waitForTimeout(50);
  await tab.keyboard.type("status");
  await tab.keyboard.press("Enter");
  await tab.keyboard.type("草稿");
  text = await doc();
  check("新增屬性", text.includes("icon: sf:map\nstatus: 草稿\n---"), JSON.stringify(text));

  const key = tab.locator('.cm-prop[data-key="status"] .cm-prop-key');
  await key.fill("狀態");
  await key.press("Enter");
  text = await doc();
  check("改名", text.includes("狀態: 草稿\n") && !text.includes("status"), JSON.stringify(text));

  await tab.locator('.cm-prop[data-key="title"] .cm-prop-del').dispatchEvent("mousedown");
  text = await doc();
  check("刪除屬性", !text.includes("title:"), JSON.stringify(text));
  check("內文不變", text.endsWith("---\n# 筆記\n\n內文\n"));
  await tab.close();
}

{
  // 沒有 frontmatter：文件頭的「新增屬性」
  const { tab, doc } = await open("# 標題\n\n內文\n");
  await tab.hover(".cm-doc-header");
  await tab.locator(".cm-doc-add .cm-doc-btn", { hasText: "新增屬性" }).dispatchEvent("mousedown");
  await tab.waitForTimeout(50);
  await tab.keyboard.type("作者");
  await tab.keyboard.press("Enter");
  await tab.keyboard.type("我");
  const text = await doc();
  check("沒有 frontmatter 時新增屬性", text === "---\n作者: 我\n---\n# 標題\n\n內文\n", JSON.stringify(text));
  await tab.close();
}

{
  // 多行卡片：首行行尾與分界行的分隔符號換成箭頭、子行的克漏字（分界行之前）標示，子行中的卡片語法不另外標示
  const CARDS = [
    "- 請說明 SDT :: ^c-a1b2c3",
    "  - Competence",
    "  - 子 :: 不是卡片",
    "",
    "- Erikson ::",
    "  - 嬰兒期：{{信任}}",
    "  ::",
    "  補充 {{不算}}",
    "",
    "- 單行 :: 卡片",
    "",
  ].join("\n");
  const { tab, doc, cdp } = await open(CARDS);
  await tab.evaluate(() => document.activeElement?.blur());
  await tab.waitForTimeout(50);
  const arrows = await tab.locator(".cm-card-sep").allTextContents();
  check("多行卡片的分隔符號", JSON.stringify(arrows) === JSON.stringify(["→", "→", "→", "→"]), JSON.stringify(arrows));
  const clozes = await tab.locator(".cm-card-cloze").allTextContents();
  check("子行的克漏字只標示到分界行", JSON.stringify(clozes) === JSON.stringify(["信任"]), JSON.stringify(clozes));
  check("首行的 ^id 隱藏", !(await tab.locator(".cm-content").innerText()).includes("^c-a1b2c3"));

  // 在子行中注音組字：組字中與選字後文件都正確
  await tab.locator(".cm-line", { hasText: "Competence" }).click();
  await tab.keyboard.press("End");
  await cdp.send("Input.imeSetComposition", { text: "ㄋㄥˊ", selectionStart: 3, selectionEnd: 3 });
  await cdp.send("Input.insertText", { text: "能力" });
  const text = await doc();
  check("子行注音組字", text === CARDS.replace("Competence", "Competence能力"), JSON.stringify(text));
  await tab.close();
}

await browser.close();
process.exit(failed ? 1 : 0);
