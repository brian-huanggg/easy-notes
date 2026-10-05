// 表格上方的工具列、編輯列（名稱方塊 + fx）與下方的狀態列（見 docs/architecture/sheets.md）。
// 只負責 DOM；選取、指令與寫入在 main.ts。打字只改 fx 輸入框，結束時才由 main.ts 送出 edit。
import { t } from "../shared/i18n";

interface ToolButton {
  command: string;
  symbol: string;
  label: string;
  /** 切換鈕：開著時用強調色 */
  toggle?: keyof ToolbarState;
  /** 需要選取的儲存格才能按 */
  needsCell?: boolean;
}

const groups: ToolButton[][] = [
  [
    { command: "undo", symbol: "arrow.uturn.backward", label: t("復原") },
    { command: "redo", symbol: "arrow.uturn.forward", label: t("重做") },
  ],
  [
    { command: "insertRowAbove", symbol: "rectangle.tophalf.inset.filled", label: t("在上方插入列") },
    { command: "insertRowBelow", symbol: "rectangle.bottomhalf.inset.filled", label: t("在下方插入列") },
    { command: "deleteRows", symbol: "minus.rectangle", label: t("刪除列"), needsCell: true },
  ],
  [
    { command: "insertColumnLeft", symbol: "rectangle.lefthalf.inset.filled", label: t("在左側插入欄") },
    { command: "insertColumnRight", symbol: "rectangle.righthalf.inset.filled", label: t("在右側插入欄") },
    { command: "deleteColumn", symbol: "minus.rectangle.portrait", label: t("刪除欄"), needsCell: true },
  ],
  [
    { command: "sortAscending", symbol: "arrow.up.circle", label: t("依此欄遞增排序並寫入"), needsCell: true },
    { command: "sortDescending", symbol: "arrow.down.circle", label: t("依此欄遞減排序並寫入"), needsCell: true },
  ],
  [
    { command: "toggleFreeze", symbol: "pin", label: t("凍結首欄"), toggle: "frozen" },
    { command: "toggleHeaderRow", symbol: "rectangle.topthird.inset.filled", label: t("第一列是標題"), toggle: "headerRow" },
  ],
];

export interface ToolbarState {
  readOnly: boolean;
  canUndo: boolean;
  canRedo: boolean;
  hasCell: boolean;
  frozen: boolean;
  headerRow: boolean;
}

function icon(symbol: string): HTMLSpanElement {
  const glyph = document.createElement("span");
  glyph.className = "sheet-icon";
  glyph.style.setProperty("--icon", `url("symbol:///${encodeURIComponent(symbol)}")`);
  return glyph;
}

/** 工具列；回傳更新按鈕狀態的函式 */
export function buildToolbar(container: HTMLElement, run: (command: string) => void): (state: ToolbarState) => void {
  container.setAttribute("role", "toolbar");
  container.setAttribute("aria-label", t("表格工具列"));
  const buttons: { item: ToolButton; el: HTMLButtonElement }[] = [];
  for (const group of groups) {
    const box = document.createElement("div");
    box.className = "sheet-tool-group";
    for (const item of group) {
      const el = document.createElement("button");
      el.type = "button";
      el.className = "sheet-tool";
      el.dataset.command = item.command;
      el.title = item.label;
      el.setAttribute("aria-label", item.label);
      el.append(icon(item.symbol));
      // 不搶走表格的焦點：指令以目前選取的儲存格為對象
      el.addEventListener("mousedown", (e) => e.preventDefault());
      el.addEventListener("click", () => run(item.command));
      box.append(el);
      buttons.push({ item, el });
    }
    container.append(box);
  }
  return (state) => {
    for (const { item, el } of buttons) {
      let enabled = !state.readOnly;
      if (item.command === "undo") enabled &&= state.canUndo;
      if (item.command === "redo") enabled &&= state.canRedo;
      if (item.needsCell) enabled &&= state.hasCell;
      el.disabled = !enabled;
      if (item.toggle) {
        const on = Boolean(state[item.toggle]);
        el.classList.toggle("is-active", on);
        el.setAttribute("aria-pressed", String(on));
      }
    }
  };
}

export interface FormulaBar {
  /** 跟著選取更新；輸入框有焦點時不改內容（使用者正在編輯） */
  show(name: string, value: string | null): void;
  readonly editing: boolean;
}

/**
 * 編輯列：Enter 寫入並回到表格、⇧Enter / ⌥Enter 換行、Esc 放棄、失焦時寫入；組字中的 Enter 不寫入。
 * `begin` 在取得焦點時記下對象（之後選取改變也寫回原本的儲存格），`commit` 寫入，`leave` 回到表格。
 */
export function buildFormulaBar(
  container: HTMLElement,
  handlers: { begin(): void; commit(value: string): void; leave(): void },
): FormulaBar {
  const name = document.createElement("div");
  name.className = "sheet-name";
  name.setAttribute("aria-label", t("目前儲存格"));
  const fx = icon("function");
  fx.classList.add("sheet-fx");
  const input = document.createElement("textarea");
  input.className = "sheet-formula";
  input.rows = 1;
  input.spellcheck = false;
  input.setAttribute("aria-label", t("儲存格內容"));
  container.append(name, fx, input);

  let shown = "";
  /** Enter 或 Esc 已經處理過：接著的 blur 不再寫入（Esc 之後寫入會把外部變動改回舊值） */
  let settled = false;
  const fit = () => {
    input.style.height = "";
    if (document.activeElement === input) input.style.height = `${input.scrollHeight}px`;
  };

  input.addEventListener("focus", () => {
    settled = false;
    handlers.begin();
    fit();
  });
  input.addEventListener("input", fit);
  // RevoGrid 在 document 上聽按鍵與剪貼簿（方向鍵移動、打字進入儲存格編輯、貼上到選取範圍）；編輯列的事件不往外傳
  for (const type of ["keydown", "keyup", "copy", "cut", "paste"]) input.addEventListener(type, (e) => e.stopPropagation());
  input.addEventListener("blur", () => {
    if (!settled) handlers.commit(input.value);
    settled = true;
    fit();
  });
  input.addEventListener("keydown", (e) => {
    // 注音組字中的 Enter 是選字（WebKit 的 isComposing 在 compositionend 之後的 keydown 可能已經是 false，keyCode 229 再擋一次）
    if (e.isComposing || e.keyCode === 229) return;
    if (e.key === "Enter" && !e.shiftKey && !e.altKey) {
      e.preventDefault();
      handlers.commit(input.value);
      settled = true;
      handlers.leave();
    } else if (e.key === "Escape") {
      e.preventDefault();
      input.value = shown;
      settled = true;
      handlers.leave();
    }
  });

  return {
    show(cellName, value) {
      // 編輯中名稱方塊與內容都維持編輯的那一格（外部變動可能讓表格的選取暫時對到別列）
      if (document.activeElement === input) return;
      name.textContent = cellName;
      input.disabled = value === null;
      shown = value ?? "";
      input.value = shown;
    },
    get editing() {
      return document.activeElement === input;
    },
  };
}

/** 狀態列：左邊是列數與欄數，右邊是選取範圍的計數、加總、平均 */
export function buildStatusBar(container: HTMLElement): (summary: string, selection: string[]) => void {
  const left = document.createElement("span");
  const right = document.createElement("span");
  right.className = "sheet-status-selection";
  container.append(left, right);
  return (summary, selection) => {
    left.textContent = summary;
    right.replaceChildren(
      ...selection.map((text) => {
        const span = document.createElement("span");
        span.textContent = text;
        return span;
      }),
    );
  };
}
