// 編輯器是否有焦點（StateField 版的 view.hasFocus）：表格、區塊公式只在有焦點且游標在範圍內時顯示原始碼，
// 開檔時游標預設在文件開頭，開頭的表格不會因此顯示成原始 md。
import { EditorState, StateEffect, StateField } from "@codemirror/state";
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

// 游標（有焦點時）是否在 [from, to] 內
export function editingRange(state: EditorState, from: number, to: number): boolean {
  return state.field(editorFocus, false) === true && state.selection.ranges.some((r) => r.from <= to && r.to >= from);
}
