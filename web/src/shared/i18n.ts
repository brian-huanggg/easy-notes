// 介面語言（規則見 docs/architecture/translation.md）。
// Swift 在建立 WebView 時把語言識別碼注入 `window.__locale`（一次性，不經 Bridge、不在打字路徑）。
// 來源語言是 zh-Hant：key 就是中文原文，查不到就回傳 key；其他語言各一份字典。
declare global {
  interface Window {
    __locale?: string;
  }
}

export const locale: string = window.__locale ?? "zh-Hant";

const dictionaries: Record<string, Record<string, string>> = {
  en: {
    "{time}編輯": "Edited {time}",
    "{date} 編輯": "Edited {date}",
    "{time}更新": "Updated {time}",
    "{date} 更新": "Updated {date}",
    剛剛: "Just now",
    卡片: "Card",
    雙向卡片: "Two-way card",
    "欄位 {n}": "Column {n}",
    新增圖示: "Add Icon",
    新增封面: "Add Cover",
    更換圖示: "Change Icon",
    更換封面: "Change Cover",
    點一下建立新筆記: "Click to create a new note",
    // 表格
    表格選項: "Table options",
    在上方插入列: "Insert Row Above",
    在下方插入列: "Insert Row Below",
    在左側插入欄: "Insert Column Left",
    在右側插入欄: "Insert Column Right",
    上移一列: "Move Row Up",
    下移一列: "Move Row Down",
    左移一欄: "Move Column Left",
    右移一欄: "Move Column Right",
    靠左對齊: "Align Left",
    置中對齊: "Align Center",
    靠右對齊: "Align Right",
    刪除列: "Delete Row",
    刪除欄: "Delete Column",
    "編輯 Markdown 原始碼": "Edit Markdown Source",
    新增列: "Add Row",
    新增欄: "Add Column",
    拖曳以移動列: "Drag to move row",
    拖曳以移動欄: "Drag to move column",
    // 尋找
    在筆記中尋找: "Find in note",
    區分大小寫: "Match case",
    上一個: "Previous",
    下一個: "Next",
    關閉: "Close",
    沒有結果: "No results",
    // 屬性
    新增屬性: "Add Property",
    "＋ 新增屬性": "+ Add Property",
    屬性名稱: "Property name",
    刪除屬性: "Remove Property",
    "編輯原始 YAML": "Edit YAML Source",
    文字: "Text",
    清單: "List",
    核取方塊: "Checkbox",
    日期: "Date",
    空白: "Empty",
    "新增…": "Add…",
  },
};

/** `t("{time}編輯", { time })`：參數用 `{名稱}`，語序由各語言的字串決定，不要在程式裡拼接 */
export function t(key: string, params?: Record<string, string | number>): string {
  const text = dictionaries[locale.split("-")[0]]?.[key] ?? key;
  return params ? text.replace(/\{(\w+)\}/g, (match, name) => (name in params ? String(params[name]) : match)) : text;
}
