// 外部修改或同步推進來時，還沒存檔的本地修改轉換到新內容上保留，不被覆蓋（與協作編輯相同的 ChangeSet.map）
import { ChangeSet, Text } from "@codemirror/state";
import { replaceChange } from "./lineBreak";

// saved：上次與磁碟一致的內容；unsaved：之後本地的修改（從 saved 到目前的文件）；remote：磁碟上的新內容
// 回傳要套用到目前文件的變更，以及新的 saved / unsaved
export function rebase(saved: Text, unsaved: ChangeSet, remote: string): { changes: ChangeSet; saved: Text; unsaved: ChangeSet } {
  const theirs = ChangeSet.of(replaceChange(saved, remote), saved.length);
  return { changes: theirs.map(unsaved), saved: theirs.apply(saved), unsaved: unsaved.map(theirs, true) };
}
