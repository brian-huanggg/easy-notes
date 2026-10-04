// 開過的筆記保留的 EditorState：最近使用的 `limit` 篇（LRU），超過就丟掉最久沒用的。
// 丟掉不會遺失內容：存檔在切換前就做了，下次開啟時以磁碟內容重建（只少了 undo 紀錄與游標）
export class StateCache<T> {
  // Map 依插入順序走訪：最前面 = 最久沒用
  private map = new Map<string, T>();

  constructor(private limit: number) {}

  get(id: string): T | undefined {
    const value = this.map.get(id);
    if (value !== undefined) this.set(id, value);
    return value;
  }

  set(id: string, value: T) {
    this.map.delete(id);
    this.map.set(id, value);
    while (this.map.size > this.limit) this.map.delete(this.map.keys().next().value!);
  }

  delete(id: string) {
    this.map.delete(id);
  }

  /** 記憶體警告：全部丟掉（畫面上的那篇不在快取內，由 EditorView 持有） */
  clear() {
    this.map.clear();
  }

  get size() {
    return this.map.size;
  }
}
