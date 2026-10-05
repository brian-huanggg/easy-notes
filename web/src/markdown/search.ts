// 在筆記中尋找（⌘F）：@codemirror/search 的比對與標示，搜尋列自己做（中文介面、顯示第幾個 / 共幾個）。
// 搜尋框是一般的 <input>：組字中的 Enter 交給輸入法；查詢改變只標示結果，不移動游標。
// 搜尋列開著時，選到的結果若在表格、區塊公式內會顯示原始碼（editorFocus.ts 的 revealing）。
import {
  closeSearchPanel,
  findNext,
  findPrevious,
  getSearchQuery,
  openSearchPanel,
  search,
  SearchQuery,
  searchKeymap,
  setSearchQuery,
} from "@codemirror/search";
import { EditorState, Extension } from "@codemirror/state";
import { EditorView, keymap, Panel, ViewUpdate } from "@codemirror/view";
import { t } from "../shared/i18n";
import { el, onPress } from "./bridge";

// 超過就只顯示「1000+」，大檔案不必數完
const COUNT_LIMIT = 1000;

// 第幾個（選取剛好是某個結果時）、共幾個
export function countMatches(state: EditorState, query: SearchQuery): { index: number; total: number } {
  if (!query.valid) return { index: 0, total: 0 };
  const sel = state.selection.main;
  let index = 0;
  let total = 0;
  const cursor = query.getCursor(state);
  for (let m = cursor.next(); !m.done && total <= COUNT_LIMIT; m = cursor.next()) {
    total++;
    if (m.value.from === sel.from && m.value.to === sel.to) index = total;
  }
  return { index, total };
}

const ICON_UP = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m6 15 6-6 6 6"/></svg>';
const ICON_DOWN = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m6 9 6 6 6-6"/></svg>';
const ICON_CLOSE = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg>';

function button(className: string, icon: string, title: string, action: () => void): HTMLElement {
  const node = el("button", "cm-find-btn " + className);
  node.innerHTML = icon;
  node.title = title;
  node.setAttribute("aria-label", title);
  onPress(node, action);
  return node;
}

function createPanel(view: EditorView): Panel {
  const dom = el("div", "cm-find");
  const input = el("input", "cm-find-input") as HTMLInputElement;
  input.type = "search";
  input.placeholder = t("在筆記中尋找");
  input.spellcheck = false;
  input.autocapitalize = "off";
  input.setAttribute("autocorrect", "off");
  // openSearchPanel 再按一次時聚焦這個欄位
  input.setAttribute("main-field", "true");
  input.value = getSearchQuery(view.state).search;
  const count = el("span", "cm-find-count");
  const caseToggle = el("button", "cm-find-btn cm-find-case", "Aa");
  caseToggle.title = t("區分大小寫");
  caseToggle.setAttribute("aria-pressed", "false");

  const commit = (caseSensitive = getSearchQuery(view.state).caseSensitive) => {
    const query = new SearchQuery({ search: input.value, caseSensitive, literal: true });
    if (!query.eq(getSearchQuery(view.state))) view.dispatch({ effects: setSearchQuery.of(query) });
  };
  const go = (forward: boolean) => {
    commit();
    (forward ? findNext : findPrevious)(view);
  };

  input.addEventListener("input", () => commit());
  input.addEventListener("keydown", (e) => {
    // 組字中的 Enter 是輸入法在選字
    if (e.isComposing || e.keyCode === 229) return;
    if (e.key === "Enter") {
      e.preventDefault();
      go(!e.shiftKey);
    } else if (e.key === "Escape") {
      e.preventDefault();
      closeSearchPanel(view);
    }
  });
  onPress(caseToggle, () => commit(!getSearchQuery(view.state).caseSensitive));

  dom.append(
    input,
    count,
    caseToggle,
    button("cm-find-prev", ICON_UP, t("上一個"), () => go(false)),
    button("cm-find-next", ICON_DOWN, t("下一個"), () => go(true)),
    button("cm-find-close", ICON_CLOSE, t("關閉"), () => closeSearchPanel(view)),
  );

  const refresh = (state: EditorState) => {
    const query = getSearchQuery(state);
    if (input.value !== query.search && document.activeElement !== input) input.value = query.search;
    caseToggle.setAttribute("aria-pressed", String(query.caseSensitive));
    caseToggle.classList.toggle("is-on", query.caseSensitive);
    if (!query.search) {
      count.textContent = "";
      return;
    }
    const { index, total } = countMatches(state, query);
    count.textContent = total === 0 ? t("沒有結果") : total > COUNT_LIMIT ? `${COUNT_LIMIT}+` : `${index}/${total}`;
    dom.classList.toggle("is-empty", total === 0);
  };
  refresh(view.state);

  return {
    dom,
    top: true,
    mount() {
      input.focus();
      input.select();
    },
    update(u: ViewUpdate) {
      if (u.docChanged || u.selectionSet || u.transactions.some((tr) => tr.effects.some((e) => e.is(setSearchQuery)))) refresh(u.state);
    },
  };
}

const FIND_KEYS = new Set(["Mod-f", "F3", "Mod-g", "Escape"]);

export const findInNote: Extension = [
  search({ top: true, literal: true, createPanel }),
  // ⌘F 開啟、⌘G / ⇧⌘G（F3）下一個 / 上一個、Esc 關閉；不要 ⌘D、跳到行號等其他綁定
  keymap.of(searchKeymap.filter((b) => b.key && FIND_KEYS.has(b.key))),
];

export function openFind(view: EditorView) {
  openSearchPanel(view);
}
