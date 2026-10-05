// CSV / TSV 的工具列、編輯列（fx）與狀態列：在 Chromium 實際點擊、打字、注音組字，檢查送給 Swift 的 edit / meta。
// 注音以 DevTools 的 Input.imeSetComposition 模擬（WebKit 的實作不同，實機仍需驗證）。
// 需要 Playwright（不列為相依套件）：pnpm add -D playwright && pnpm exec playwright install chromium（只在本機用，不要 commit package.json 與 pnpm-lock.yaml 的變更）
// 用法：pnpm build && node test/sheet.e2e.mjs
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

let chromium;
try {
  ({ chromium } = createRequire(import.meta.url)("playwright"));
} catch {
  console.log("skip: 找不到 playwright（見檔案開頭的說明）");
  process.exit(0);
}

const page = fileURLToPath(new URL("../../Packages/KindSheet/Sources/KindSheet/Resources/Sheet/index.html", import.meta.url));
const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {});
let failed = 0;

function check(name, ok, detail = "") {
  if (!ok) failed++;
  console.log(`${ok ? "ok" : "FAIL"} - ${name}${ok ? "" : " " + detail}`);
}

const ROWS = [
  { id: 1, cells: ["名稱", "數量"] },
  { id: 2, cells: ["蘋果", "3"] },
  { id: 3, cells: ["香蕉", "1,200.5"] },
  { id: 4, cells: ["備註\n第二行", ""] },
];

async function open(rows = ROWS) {
  const tab = await browser.newPage();
  const messages = [];
  tab.on("console", async (m) => {
    const msg = await m.args()[1]?.jsonValue().catch(() => null);
    if (msg?.type) messages.push(msg);
  });
  tab.on("pageerror", (e) => console.log("pageerror", e.message));
  await tab.goto(`file://${page}`);
  await tab.waitForFunction(() => window.sheet);
  await tab.evaluate((json) => window.sheet.load(json), JSON.stringify({ rows }));
  await tab.waitForTimeout(200);
  const edits = () => messages.filter((m) => m.type === "edit").flatMap((m) => JSON.parse(m.ops));
  const metas = () => messages.filter((m) => m.type === "meta").map((m) => JSON.parse(m.meta));
  const cellAt = (row, col) => tab.locator(`revogr-data[type="rgRow"] .rgCell[role="gridcell"][data-rgrow="${row}"][data-rgcol="${col}"]`);
  const ui = async () => {
    await tab.waitForTimeout(80);
    return tab.evaluate(() => ({
      name: document.querySelector(".sheet-name").textContent,
      formula: document.querySelector(".sheet-formula").value,
      status: document.querySelector("#status").textContent,
      selection: [...document.querySelectorAll(".sheet-status-selection span")].map((s) => s.textContent),
      disabled: Object.fromEntries([...document.querySelectorAll(".sheet-tool")].map((b) => [b.dataset.command, b.disabled])),
      active: [...document.querySelectorAll(".sheet-tool.is-active")].map((b) => b.dataset.command),
      focusInFormula: document.activeElement?.classList.contains("sheet-formula") ?? false,
    }));
  };
  return { tab, edits, metas, cellAt, ui, cdp: await tab.context().newCDPSession(tab) };
}

{
  const { tab, edits, cellAt, ui } = await open();
  let s = await ui();
  check("狀態列顯示列數與欄數（不含標題列）", s.status.startsWith("3 列 · 2 欄"), s.status);
  check("沒有選取時刪除列停用、沒有步驟時復原停用", s.disabled.deleteRows && s.disabled.undo && !s.disabled.insertRowBelow, JSON.stringify(s.disabled));
  check("標題列預設開著", s.active.includes("toggleHeaderRow") && !s.active.includes("toggleFreeze"), JSON.stringify(s.active));

  await cellAt(2, 0).click();
  s = await ui();
  check("名稱方塊顯示欄名 + 列號（同列標頭，標題列是第 1 列）", s.name === "A4", s.name);
  check("編輯列顯示完整內容（含換行）", s.formula === "備註\n第二行", JSON.stringify(s.formula));
  check("選取後刪除列可以按", !s.disabled.deleteRows);

  // 編輯列：Enter 寫入並回到表格
  await cellAt(0, 0).click();
  await ui(); // 選取在下一幀才更新到編輯列（人不會在 16 ms 內點兩下）
  await tab.click(".sheet-formula");
  await tab.keyboard.press("End");
  await tab.keyboard.type("派");
  check("打字中不送 edit", edits().length === 0, JSON.stringify(edits()));
  await tab.evaluate(() => {
    const data = new DataTransfer();
    data.setData("text/plain", "甲\t乙");
    document.querySelector(".sheet-formula").dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true }));
  });
  check("在編輯列貼上不會貼到表格", edits().length === 0, JSON.stringify(edits()));
  await tab.keyboard.press("Enter");
  s = await ui();
  check("Enter 送出 set", JSON.stringify(edits()) === JSON.stringify([{ op: "set", row: 2, col: 0, value: "蘋果派" }]), JSON.stringify(edits()));
  check("表格畫面跟著更新", (await cellAt(0, 0).textContent()) === "蘋果派", await cellAt(0, 0).textContent());
  check("Enter 後回到表格", !s.focusInFormula && s.name === "A2");
  check("寫入後可以復原", !s.disabled.undo);

  // 工具列的復原
  await tab.click('.sheet-tool[data-command="undo"]');
  await tab.waitForTimeout(100);
  check("工具列復原送出舊值", JSON.stringify(edits().at(-1)) === JSON.stringify({ op: "set", row: 2, col: 0, value: "蘋果" }), JSON.stringify(edits().at(-1)));
  check("復原後畫面是舊值", (await cellAt(0, 0).textContent()) === "蘋果");

  // ⇧Enter 換行、Esc 放棄
  await tab.click(".sheet-formula");
  await tab.keyboard.press("End");
  await tab.keyboard.press("Shift+Enter");
  await tab.keyboard.type("x");
  s = await ui();
  check("⇧Enter 換行不寫入", s.formula === "蘋果\nx" && s.focusInFormula && edits().length === 2, JSON.stringify(s.formula));
  await tab.keyboard.press("Escape");
  s = await ui();
  check("Esc 放棄並回到表格", s.formula === "蘋果" && !s.focusInFormula && edits().length === 2, JSON.stringify(s));

  // 失焦時寫回取得焦點時的那一格
  await tab.click(".sheet-formula");
  await tab.keyboard.press("End");
  await tab.keyboard.type("乾");
  await cellAt(1, 1).click();
  s = await ui();
  check("失焦寫回原本的儲存格", JSON.stringify(edits().at(-1)) === JSON.stringify({ op: "set", row: 2, col: 0, value: "蘋果乾" }), JSON.stringify(edits().at(-1)));
  check("選取移到新的儲存格", s.name === "B3" && s.formula === "1,200.5", JSON.stringify(s));

  // 範圍選取：計數、加總、平均
  await cellAt(0, 1).click();
  await cellAt(2, 1).click({ modifiers: ["Shift"] });
  s = await ui();
  check("範圍的平均、計數、加總", JSON.stringify(s.selection) === JSON.stringify(["平均：601.75", "計數：2", "加總：1,203.5"]), JSON.stringify(s.selection));
  await cellAt(0, 0).click();
  await cellAt(2, 0).click({ modifiers: ["Shift"] });
  s = await ui();
  check("沒有數字時只有計數", JSON.stringify(s.selection) === JSON.stringify(["計數：3"]), JSON.stringify(s.selection));
  await cellAt(1, 0).click();
  s = await ui();
  check("單一儲存格不顯示統計", s.selection.length === 0, JSON.stringify(s.selection));

  // 工具列：插入列、凍結首欄
  const before = edits().length;
  await tab.click('.sheet-tool[data-command="insertRowBelow"]');
  s = await ui();
  const op = edits().at(-1);
  check("插入列送 insertRows，接在選取的列之後", edits().length === before + 1 && op.op === "insertRows" && op.before === 4, JSON.stringify(op));
  check("狀態列列數加一", s.status.startsWith("4 列"), s.status);
  check("工具列按下後焦點留在表格", s.name === "A3", s.name);
  await tab.close();
}

{
  const { tab, metas, ui } = await open();
  await tab.click('.sheet-tool[data-command="toggleFreeze"]');
  let s = await ui();
  check("凍結首欄送 meta 並亮起", metas().at(-1)?.frozenColumns === 1 && s.active.includes("toggleFreeze"), JSON.stringify(metas()));
  await tab.click('.sheet-tool[data-command="toggleHeaderRow"]');
  s = await ui();
  check("關掉標題列：列數包含第一列", metas().at(-1)?.headerRow === false && s.status.startsWith("4 列"), s.status);
  await tab.close();
}

{
  // 編輯列有焦點時收到外部變動：輸入框的內容不被蓋掉，寫入時以 row id 對回
  const { tab, edits, cellAt, ui } = await open();
  await cellAt(0, 0).click();
  await ui(); // 選取在下一幀才更新到編輯列（人不會在 16 ms 內點兩下）
  await tab.click(".sheet-formula");
  await tab.keyboard.press("End");
  await tab.keyboard.type("汁");
  const remote = [ROWS[0], { id: 9, cells: ["外部新增", ""] }, ...ROWS.slice(1)];
  await tab.evaluate((json) => window.sheet.applyRemote(json), JSON.stringify({ rows: remote }));
  let s = await ui();
  check("外部變動不蓋掉編輯列", s.formula === "蘋果汁" && s.focusInFormula, JSON.stringify(s));
  await tab.keyboard.press("Enter");
  await tab.waitForTimeout(100); // console 訊息是非同步收集的
  check("寫回原本的列（row id）", JSON.stringify(edits()) === JSON.stringify([{ op: "set", row: 2, col: 0, value: "蘋果汁" }]), JSON.stringify(edits()));
  await tab.close();
}

{
  // 注音：組字中按 Enter 是選字，不寫入
  const { tab, edits, cellAt, ui, cdp } = await open();
  await cellAt(0, 0).click();
  await ui(); // 選取在下一幀才更新到編輯列（人不會在 16 ms 內點兩下）
  await tab.click(".sheet-formula");
  await tab.keyboard.press("End");
  await cdp.send("Input.imeSetComposition", { text: "ㄌㄧˊ", selectionStart: 3, selectionEnd: 3 });
  // Playwright 在組字中按 Enter 會插入換行（真的輸入法拿去選字），所以直接送組字中的 keydown
  await tab.evaluate(() =>
    document.querySelector(".sheet-formula").dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", isComposing: true, bubbles: true, cancelable: true })),
  );
  check("組字中 Enter 不寫入", edits().length === 0, JSON.stringify(edits()));
  await cdp.send("Input.insertText", { text: "梨" });
  let s = await ui();
  check("選字後內容正確、仍在編輯列", s.formula === "蘋果梨" && s.focusInFormula, JSON.stringify(s));
  await tab.keyboard.press("Enter");
  await tab.waitForTimeout(100); // console 訊息是非同步收集的
  check("Enter 寫入選好的字", JSON.stringify(edits()) === JSON.stringify([{ op: "set", row: 2, col: 0, value: "蘋果梨" }]), JSON.stringify(edits()));
  await tab.close();
}

{
  // 唯讀（Big5）：工具列與編輯列停用
  const tab = await browser.newPage();
  await tab.goto(`file://${page}`);
  await tab.waitForFunction(() => window.sheet);
  await tab.evaluate((json) => window.sheet.load(json), JSON.stringify({ rows: ROWS, readOnly: true }));
  await tab.waitForTimeout(150);
  const allDisabled = await tab.evaluate(() => [...document.querySelectorAll(".sheet-tool")].every((b) => b.disabled));
  check("唯讀時工具列全部停用", allDisabled);
  await tab.close();
}

await browser.close();
process.exit(failed ? 1 : 0);
