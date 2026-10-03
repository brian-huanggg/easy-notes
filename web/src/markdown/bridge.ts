import { locale, t } from "../shared/i18n";

// JS → Swift 訊息。打字的熱路徑不送訊息：changed 只在停止輸入 300ms 或失焦時送出。
export type Outgoing =
  | { type: "ready" }
  | { type: "changed"; id: string; text: string }
  | { type: "openLink"; target: string }
  | { type: "openTag"; tag: string }
  | { type: "pickCover"; hasCover: boolean }
  | { type: "pickIcon"; icon: string | null }
  | { type: "metric"; name: string; ms: number };

declare global {
  interface Window {
    webkit?: { messageHandlers?: { bridge?: { postMessage(msg: Outgoing): void } } };
  }
}

export function post(msg: Outgoing) {
  const handler = window.webkit?.messageHandlers?.bridge;
  if (handler) handler.postMessage(msg);
  else console.log("[bridge]", msg);
}

// Vault 內的相對路徑 → WebView 讀得到的 URL（Swift 端的 WKURLSchemeHandler）
export function vaultURL(path: string): string {
  return "vault:///" + path.split("/").map(encodeURIComponent).join("/");
}

// 外掛畫好的預覽圖（`DocumentPreview.image`）。`h` 讓內容改變時 URL 改變，WebView 重新載入
export function embedURL(path: string, hash: string): string {
  return "embed:///" + path.split("/").map(encodeURIComponent).join("/") + "?h=" + encodeURIComponent(hash);
}

// 「剛剛」「3 分鐘前」「昨天」「3 天前」；一週以上是日期「9/1」「2025/9/1」。
// 相對時間與日期交給 Intl，「剛剛」才需要字典。
interface TimeText {
  text: string;
  relative: boolean;
}

function describeTime(ms: number): TimeText {
  const seconds = (Date.now() - ms) / 1000;
  if (seconds < 60) return { text: t("剛剛"), relative: true };
  const always = new Intl.RelativeTimeFormat(locale, { numeric: "always" });
  if (seconds < 3600) return { text: always.format(-Math.floor(seconds / 60), "minute"), relative: true };
  const then = new Date(ms);
  const now = new Date();
  const days = Math.round((startOfDay(now) - startOfDay(then)) / 86_400_000);
  if (days === 0) return { text: always.format(-Math.floor(seconds / 3600), "hour"), relative: true };
  if (days === 1) return { text: new Intl.RelativeTimeFormat(locale, { numeric: "auto" }).format(-1, "day"), relative: true };
  if (days < 7) return { text: always.format(-days, "day"), relative: true };
  const sameYear = then.getFullYear() === now.getFullYear();
  const date = new Intl.DateTimeFormat(locale, sameYear ? { month: "numeric", day: "numeric" } : { year: "numeric", month: "numeric", day: "numeric" });
  return { text: date.format(then), relative: false };
}

function startOfDay(d: Date): number {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}

// 「3 分鐘前編輯」「9/1 編輯」。整句各自一個 key，語序由各語言決定
export function editedLabel(ms: number): string {
  const { text, relative } = describeTime(ms);
  return relative ? t("{time}編輯", { time: text }) : t("{date} 編輯", { date: text });
}

export function updatedLabel(ms: number): string {
  const { text, relative } = describeTime(ms);
  return relative ? t("{time}更新", { time: text }) : t("{date} 更新", { date: text });
}

export function el<K extends keyof HTMLElementTagNameMap>(tag: K, className?: string, text?: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// 按下（不是 click）就處理，並阻止 CodeMirror 移動游標
export function onPress(node: HTMLElement, handler: (e: MouseEvent) => void) {
  node.addEventListener("mousedown", (e) => {
    e.preventDefault();
    e.stopPropagation();
    handler(e);
  });
}
