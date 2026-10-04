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
  },
};

/** `t("{time}編輯", { time })`：參數用 `{名稱}`，語序由各語言的字串決定，不要在程式裡拼接 */
export function t(key: string, params?: Record<string, string | number>): string {
  const text = dictionaries[locale.split("-")[0]]?.[key] ?? key;
  return params ? text.replace(/\{(\w+)\}/g, (match, name) => (name in params ? String(params[name]) : match)) : text;
}
