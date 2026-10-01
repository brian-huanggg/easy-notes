// EasyNotes Markdown 編輯器：CodeMirror 6 + Live Preview + Swift Bridge
//
// Bridge 協定（見架構文件）：
//   Swift → JS : window.editor.load / applyRemote / exec / focus
//   JS → Swift : ready / changed / openLink / metric
// 打字的熱路徑不跨 Bridge：變更只在停止輸入 300ms 或失焦時回報。
import { autocompletion, CompletionContext, CompletionResult, completionKeymap } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { EditorSelection, EditorState } from "@codemirror/state";
import { drawSelection, EditorView, keymap } from "@codemirror/view";
import { tags } from "@lezer/highlight";
import { livePreview } from "./livePreview";

type Outgoing =
  | { type: "ready" }
  | { type: "changed"; id: string; text: string }
  | { type: "openLink"; target: string }
  | { type: "openTag"; tag: string }
  | { type: "metric"; name: string; ms: number };

declare global {
  interface Window {
    webkit?: { messageHandlers?: { bridge?: { postMessage(msg: Outgoing): void } } };
    editor: typeof api;
  }
}

function post(msg: Outgoing) {
  const handler = window.webkit?.messageHandlers?.bridge;
  if (handler) handler.postMessage(msg);
  else console.log("[bridge]", msg);
}

const highlight = HighlightStyle.define([
  { tag: tags.link, class: "cm-lp-link" },
  { tag: tags.url, class: "cm-lp-url" },
  { tag: tags.processingInstruction, class: "cm-lp-mark" },
]);

// [[ 自動完成：筆記名稱由 Swift 從索引推送（setLinkTargets）
let linkTargets: string[] = [];

function wikilinkCompletion(ctx: CompletionContext): CompletionResult | null {
  const before = ctx.matchBefore(/\[\[[^\]|\n]*/);
  if (!before) return null;
  const from = before.from + 2;
  const query = ctx.state.sliceDoc(from, ctx.pos).toLowerCase();
  const hasClose = ctx.state.sliceDoc(ctx.pos, ctx.pos + 2) === "]]";
  // CodeMirror 內建的模糊比對只從詞首比對，中文名稱中間的字會配對不到，所以自己做子字串比對：
  // 開頭相符優先，其次依名稱長度排序
  const matches = linkTargets
    .map((name) => ({ name, at: name.toLowerCase().indexOf(query) }))
    .filter((m) => m.at >= 0)
    .sort((a, b) => (a.at === 0 ? 0 : 1) - (b.at === 0 ? 0 : 1) || a.name.length - b.name.length)
    .slice(0, 50);
  if (matches.length === 0) return null;
  return {
    from,
    filter: false,
    options: matches.map(({ name, at }) => ({
      label: name,
      type: "text",
      apply: hasClose ? name : name + "]]",
      // 標出相符的文字
      displayLabel: name,
      boost: at === 0 ? 1 : 0,
    })),
    getMatch: (completion) => {
      const at = completion.label.toLowerCase().indexOf(query);
      return at >= 0 && query ? [at, at + query.length] : [];
    },
  };
}

const extensions = [
  history(),
  drawSelection(),
  EditorView.lineWrapping,
  markdown({ base: markdownLanguage }),
  syntaxHighlighting(highlight),
  livePreview,
  autocompletion({ override: [wikilinkCompletion], icons: false, activateOnTyping: true }),
  keymap.of([
    ...completionKeymap,
    { key: "Mod-b", run: () => (api.exec("bold"), true) },
    { key: "Mod-i", run: () => (api.exec("italic"), true) },
    ...defaultKeymap,
    ...historyKeymap,
    indentWithTab,
  ]),
  EditorView.updateListener.of((u) => {
    if (u.docChanged) scheduleFlush();
    if (u.focusChanged && !u.view.hasFocus) flush();
  }),
  EditorView.domEventHandlers({
    click(e) {
      const tag = (e.target as HTMLElement).closest(".cm-lp-tag") as HTMLElement | null;
      if (tag && !(e.metaKey || e.altKey)) {
        post({ type: "openTag", tag: tag.dataset.tag ?? "" });
        return true;
      }
      const el = (e.target as HTMLElement).closest(".cm-lp-wikilink") as HTMLElement | null;
      if (el && !(e.metaKey || e.altKey)) {
        post({ type: "openLink", target: el.dataset.target ?? el.textContent ?? "" });
        return true;
      }
      return false;
    },
  }),
];

// 每篇開過的筆記保留 EditorState：切回來時 undo 紀錄與游標都還在
const states = new Map<string, EditorState>();
let currentId: string | null = null;
let dirty = false;
let timer: number | undefined;

const view = new EditorView({
  parent: document.getElementById("editor")!,
  state: EditorState.create({ doc: "", extensions }),
});

function scheduleFlush() {
  dirty = true;
  clearTimeout(timer);
  timer = window.setTimeout(flush, 300);
}

function flush() {
  clearTimeout(timer);
  if (!dirty || currentId === null) return;
  dirty = false;
  // 組字中（注音尚未選字）不回報，避免把未確定的字存檔
  if (view.composing) {
    scheduleFlush();
    return;
  }
  post({ type: "changed", id: currentId, text: view.state.doc.toString() });
}

const api = {
  load(id: string, text: string) {
    const t0 = performance.now();
    flush();
    if (currentId !== null) states.set(currentId, view.state);
    let state = states.get(id);
    if (!state || state.doc.toString() !== text) {
      state = EditorState.create({ doc: text, extensions, selection: EditorSelection.cursor(0) });
    }
    currentId = id;
    view.setState(state);
    view.scrollDOM.scrollTop = 0;
    post({ type: "metric", name: "load", ms: performance.now() - t0 });
  },

  // 同步拉到遠端版本：以最小差異套用，保留游標與 undo
  applyRemote(id: string, text: string) {
    if (id !== currentId) {
      states.delete(id);
      return;
    }
    const old = view.state.doc.toString();
    if (old === text) return;
    let start = 0;
    while (start < old.length && start < text.length && old[start] === text[start]) start++;
    let endOld = old.length;
    let endNew = text.length;
    while (endOld > start && endNew > start && old[endOld - 1] === text[endNew - 1]) {
      endOld--;
      endNew--;
    }
    view.dispatch({ changes: { from: start, to: endOld, insert: text.slice(start, endNew) } });
    dirty = false;
  },

  // App 進入背景或重新命名、刪除檔案前呼叫，確保變更已寫回
  flush() {
    flush();
  },

  setLinkTargets(names: string[]) {
    linkTargets = names;
  },

  close(id: string) {
    states.delete(id);
  },

  focus() {
    view.focus();
  },

  // 原生工具列 / 快捷鍵觸發的指令
  exec(command: string) {
    const wrap = (open: string, close = open) => {
      view.dispatch(
        view.state.changeByRange((range) => ({
          changes: [
            { from: range.from, insert: open },
            { from: range.to, insert: close },
          ],
          range: EditorSelection.range(range.from + open.length, range.to + open.length),
        })),
      );
    };
    const prefixLine = (prefix: string) => {
      const line = view.state.doc.lineAt(view.state.selection.main.head);
      view.dispatch({ changes: { from: line.from, insert: prefix } });
    };
    switch (command) {
      case "bold": wrap("**"); break;
      case "italic": wrap("*"); break;
      case "code": wrap("`"); break;
      case "heading": prefixLine("# "); break;
      case "task": prefixLine("- [ ] "); break;
      case "bullet": prefixLine("- "); break;
      case "link": wrap("[[", "]]"); break;
    }
    view.focus();
  },

  // Spike S1：產生大檔案量測效能
  benchmark(lines: number) {
    const parts: string[] = [];
    for (let i = 0; i < lines; i++) {
      parts.push(i % 20 === 0 ? `## 段落 ${i}` : `第 ${i} 行，含 **粗體**、*斜體*、\`code\` 與 [[連結 ${i}]]。`);
    }
    api.load(`benchmark-${lines}`, parts.join("\n"));
  },
};

window.editor = api;
post({ type: "ready" });
