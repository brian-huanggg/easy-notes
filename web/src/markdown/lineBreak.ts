// 換行符。CM6 預設把 \r\n、\r 都當成換行並統一成 \n，存檔會改掉整份檔案的換行。
// 全部換行都是 \r\n 時以 lineSeparator 保留，存檔用 sliceDoc()；混合的換行照預設統一成 \n。
import { EditorState, Extension, Text } from "@codemirror/state";

const anyBreak = /\r\n|\r|\n/;

export function lineBreakOf(text: string): "\n" | "\r\n" {
  const crlf = text.split("\r\n").length - 1;
  if (crlf === 0) return "\n";
  return crlf === text.split(anyBreak).length - 1 ? "\r\n" : "\n";
}

// 建立 EditorState 時加上：讓 sliceDoc() 寫回原本的換行
export function lineBreakExtension(text: string): Extension {
  return lineBreakOf(text) === "\r\n" ? EditorState.lineSeparator.of("\r\n") : [];
}

// 與 doc.toString() 相同的座標：每個換行算一個字元
export function normalized(text: string): string {
  return text.split(anyBreak).join("\n");
}

// 插入多行文字一律經過它：設定 lineSeparator 後，字串裡的 \n 不會被當成換行
export function lines(text: string): Text {
  return Text.of(text.split(anyBreak));
}

// 把文件改成 `text` 的最小變更（共同前後綴之外的一段），在 doc 座標（換行算一個字元）上計算
export function replaceChange(doc: Text, text: string): { from: number; to: number; insert: Text } {
  const old = doc.toString();
  const next = normalized(text);
  let start = 0;
  while (start < old.length && start < next.length && old[start] === next[start]) start++;
  let endOld = old.length;
  let endNew = next.length;
  while (endOld > start && endNew > start && old[endOld - 1] === next[endNew - 1]) {
    endOld--;
    endNew--;
  }
  return { from: start, to: endOld, insert: lines(next.slice(start, endNew)) };
}
