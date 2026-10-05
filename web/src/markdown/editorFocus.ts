// 編輯器是否有焦點（StateField 版的 view.hasFocus）：表格、區塊公式只在有焦點且游標在範圍內時顯示原始碼，
// 開檔時游標預設在文件開頭，開頭的表格不會因此顯示成原始 md。
// 搜尋列開著時焦點在搜尋框，但選到的結果要看得到，所以也算在編輯（search.ts）。
import { searchPanelOpen } from "@codemirror/search";
import { EditorState, StateEffect, StateField, Transaction } from "@codemirror/state";
import { EditorView } from "@codemirror/view";

export const setEditorFocus = StateEffect.define<boolean>();

export const editorFocus = StateField.define<boolean>({
  create: () => false,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setEditorFocus)) value = e.value;
    return value;
  },
  provide: () => EditorView.focusChangeEffect.of((_, focusing) => setEditorFocus.of(focusing)),
});

// 顯示原始碼的條件：編輯器有焦點，或搜尋列開著
export function revealing(state: EditorState): boolean {
  return state.field(editorFocus, false) === true || searchPanelOpen(state);
}

// 游標是否在 [from, to] 內（且 revealing）
export function editingRange(state: EditorState, from: number, to: number): boolean {
  return revealing(state) && state.selection.ranges.some((r) => r.from <= to && r.to >= from);
}

// 焦點或搜尋列狀態改變（StateField 要重建 decorations）
export function revealChanged(tr: Transaction): boolean {
  return tr.effects.some((e) => e.is(setEditorFocus)) || searchPanelOpen(tr.state) !== searchPanelOpen(tr.startState);
}
