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

// 「剛剛」「3 分鐘前」「昨天」「2026/9/1」
export function relativeTime(ms: number): string {
  const seconds = (Date.now() - ms) / 1000;
  if (seconds < 60) return "剛剛";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分鐘前`;
  const then = new Date(ms);
  const now = new Date();
  const days = Math.round((startOfDay(now) - startOfDay(then)) / 86_400_000);
  if (days === 0) return `${Math.floor(seconds / 3600)} 小時前`;
  if (days === 1) return "昨天";
  if (days < 7) return `${days} 天前`;
  const date = `${then.getMonth() + 1}/${then.getDate()}`;
  return then.getFullYear() === now.getFullYear() ? date : `${then.getFullYear()}/${date}`;
}

function startOfDay(d: Date): number {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}

// 「3 分鐘前」+「編輯」→「3 分鐘前編輯」；日期 →「9/1 編輯」
export function withVerb(time: string, verb: string): string {
  return /[前天剛]$/.test(time) ? time + verb : `${time} ${verb}`;
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
