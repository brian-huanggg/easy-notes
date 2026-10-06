# Flashcards

**Overview**: scheduling uses swift-fsrs (FSRS-6) and parameter optimization uses fsrs-rs; folder = deck, tag = filter; settings are managed as presets whose defaults match Anki.

## Card types and identity

The syntax (RemNote-like) belongs to the vault's Markdown dialect: one line is one note (extendable to several lines, see "Multi-line cards"), and the `^id` at the end of the first line is the note's identity, added by the App when missing. A note produces one or more cards according to its syntax, with card id = note id + suffix:

| Syntax | Produces | Card id |
| --- | --- | --- |
| `Photosynthesis happens in :: chloroplasts ^c-a1b2c3` | 1 card (forward) | `c-a1b2c3` |
| `apple ;; 蘋果 ^c-d4e5f6` | 2 cards (forward, reverse) | `c-d4e5f6`, `c-d4e5f6:r` |
| `{{Mitochondria}} are the {{powerhouse of the cell}} ^c-g7h8i9` | one card per `{{}}` | `c-g7h8i9:1`, `c-g7h8i9:2` |

- Cards produced by the same note are siblings (the target of "bury siblings").
- Card identity is bound only to `^id` and is independent of the file path: cutting a whole note and pasting it into another note carries the review history along.
- When copy and paste duplicates a `^id`, the line that appears later gets a new id.
- Deleting the line makes the card disappear while its log stays in the jsonl; when the same `^id` returns the history is restored with it.
- `::` and `;;` need whitespace on both sides (so text like `std::vector` is not taken as a card); cards are not parsed inside code blocks, inline code or frontmatter.
- `^id` has the form `c-` + 6 lowercase alphanumerics, decided by a hash of "file path + the line's content": two devices adding an id to the same line get the same result, which diff3 treats as the same change and produces no conflict. When the line already ends with another block id (for example Obsidian's `^abc`) it is reused.
- Adding ids is done by `ContentFixer` (see "Extension points" in [core.md](./core.md)): open files are not fixed and are handled after the user leaves them. Duplicate ids: within one file the later line after the change; against another file, the file currently being processed (the pasted-to location).
- The card type is an enum inside the Flashcards plugin and Core does not know it. The syntax specification is written in the vault's `CLAUDE.md`, and the Markdown plugin (syntax highlighting) and the Flashcards plugin (parsing) each implement it from that spec without importing each other.

## Multi-line cards

A note is one line by default; to write lists, paragraphs or images, extend it into several lines with the children of a list item. Only the first line ("first line" below) decides:

- **A first line ending with a delimiter = multi-line note**: the first line is a list item (`-`, `*`, `+`, `1.`) which, after removing `^id`, ends with ` ::` or ` ;;`. Content = the first line's text + all child lines of this list item.
- **The range of child lines** follows a CommonMark list item: lines indented to the start of the first line's text (after the list marker) count, with blank lines allowed in between; it ends at the first non-blank line with insufficient indentation, and trailing blank lines do not count. A tab counts as 4 columns. After removing that indentation, a child line is content.
- **A line with only `::` (or `;;`) is the divider between front and back**: the first child line that is just `::` or `;;` after removing indentation. With no divider line, front = the first line's text and back = all child lines; with a divider, front = the first line's text + child lines before the divider and back = child lines after it. The type (forward / bidirectional) is decided by the first line's symbol.
- **Cloze**: `{{}}` anywhere in the content makes it a cloze, numbered by order of appearance in the whole note; what follows the divider line is Back Extra (shown only on the back, and `{{}}` inside it does not count). A cloze's `{{` and `}}` must be on the same line.
- The first line's text cannot be empty and the back (Text for a cloze) cannot be empty, otherwise it is not a card.
- `^id` goes at the end of the first line (`Q :: ^c-a1b2c3`), matching the block id of an Obsidian list item (covering the whole item and its children). The id hash takes only the first line's content, so id adding and duplicate detection are the same as single-line.
- **Child lines are always content**: `::`, `{{}}` and `^id` in child lines never produce cards of their own; indenting an existing card into a multi-line note turns it into content (its old `^id` no longer counts and is stripped when displayed). A code block inside the child range belongs to the content; one not closed by the end of the range is treated as closed there.
- **Compatible with single-line**: `Q :: A` (text on both sides), or a first line containing `{{}}` but not ending with a delimiter, remains a single-line note and its children do not count (sub-cards can still sit under a single-line card as before). A first line that is not a list item (paragraph, heading, quote) cannot extend into multiple lines.
- A note's position is the first line's line number (the review screen's "Edit note", the card browser's line number, sorting), with the last line recorded too.

```markdown
- Explain the three basic elements of **SDT** :: ^c-a1b2c3
  ![[sdt.png]]
  - Competence
  - Autonomy
  - Relatedness

- To find all **running processes** :: ^c-d4e5f6
  - The process **containing** "python"
  ::
  `ps aux | grep python`

- Erik Erikson's developmental theory :: ^c-g7h8i9
  - **Infancy (0–1)**: {{trust vs. mistrust}}, developing "hope"
  - **Early adulthood (18–40)**: {{intimacy vs. isolation}}, developing "love"
  ::
  Resolving each stage's crisis yields the corresponding psychological strength.
```

First note: one-line front, back with an image and a list. Second: two-line front, one-line back. Third: two cloze cards, with Back Extra after the divider.

## Images

- **Syntax**: `![[x.png]]`, `![[x.png|300]]` (width in pt); path rules match the editor: without `/` it is `Attachments/x.png` (falling back to the legacy `附件/`), with `/` it is a vault-relative path. The rules live in Core's `Attachments` (Swift) and `linkCards.ts` (editor), each implemented from the same rule. Supported extensions match the editor: png, jpg, jpeg, gif, webp, heic, avif (svg is unsupported and shows the raw text).
- Usable in single-line and multi-line notes; alone on a line inside a multi-line note, the editor shows it as an image as usual.
- **Native display**: an image forms its own block (split out even when written mid-text), no wider than the card, height capped at 400 pt, using the specified width when given (never enlarged). Data is read in the background through `DocumentSession.resourceReader` (the same path as `vault://`, vault paths only), and the decoded result is cached in memory by path + modified time. When not found or undecodable, the raw text shows in the secondary color.
- Attachment import, sync and rename follow Core's existing rules; Flashcards manages no files of its own.
- **Audio**: `![[x.mp3]]` (mp3, m4a, wav, aac, ogg, flac) forms its own block with the same path rules as images, showing a play button and the file name; one tap plays and another stops (no autoplay); data is read through the same `resourceReader` and not cached. When unreadable or undecodable the raw text shows. When exporting to Anki it is written as `[sound:x.mp3]`. Other non-image embeds (such as pdf) show the raw text.
- **Preview**: clicking an image opens a sheet that scales it to the window (small images are enlarged); clicking inside the sheet toggles actual size (scrollable).

## Card content: Markdown and LaTeX

Card text uses Markdown and LaTeX math (like Anki, but without writing HTML). A single-line note has inline syntax only; a multi-line note additionally supports these blocks:

| Block | Syntax | Display |
| --- | --- | --- |
| Paragraph | Consecutive text lines | Each line breaks as written (like Anki's `<br>`); a blank line = paragraph spacing |
| List | `-`, `*`, `+`, `1.`, children indented further | Bullets / numbers, nested by indentation |
| Image | `![[x.png]]` | See "Images" |
| Code block | Fenced with ```` ``` ```` | Monospace, whitespace preserved, no Markdown or math parsed inside |
| Display math | A line `$$…$$` | Centered |

Headings, quotes and tables show as plain text in cards (not parsed).

| Syntax | Display |
| --- | --- |
| `**bold**`, `__bold__`, `*italic*`, `~~strikethrough~~`, `==highlight==`, `` `code` `` | The corresponding style |
| `[text](https://…)`, `[[note]]`, `[[note\|text]]` | A link; `[[ ]]` shows only the text |
| `$E=mc^2$` | Inline math |
| `$$\int_0^1 x\,dx$$` | Display math (its own paragraph, centered; written on one line) |
| `\$` | A literal `$` |

- **Deciding what is math** (the same as Obsidian / Pandoc, so amounts are not taken as math): the `$` after the opening must not be whitespace, the closing `$` must not be preceded by whitespace nor followed by a digit; the closing must be found on the same line, otherwise `$` is plain text. `$$…$$` takes precedence over `$…$`; the character after `\` is never a delimiter. So "$5 and $10" is not math.
- **Math is protected like inline code**: a `$` inside code is not math; `::`, `;;`, `{{` and `}}` inside math are not card syntax (`$\frac{{a}}{b}$` is not a cloze).
- **A cloze may wrap a whole formula or inline code**: `{{$E=mc^2$}}`, ``{{`ps aux`}}``; a cloze's `{{` and `}}` must be outside math and code, `{` and `}` in the content may appear only inside math or code, and inline code must sit wholly inside the cloze (not half in).
- **Native rendering**: the review screen and card browser open no WebView. Multi-line content is first split into blocks (`CardBlocks`), each laid out on its own and stacked vertically; inline Markdown in a text block is converted to `AttributedString` by the plugin's own parser (`CardMarkup`, the same rules as TSV export); math is typeset by [SwiftMath](https://github.com/mgriebling/SwiftMath) (the Swift port of iosMath, MIT) into template images embedded in text with `Text(Image)` and baseline-aligned, so it wraps with the text and takes the foreground color (cloze answers are colored too). Text, list items and code blocks always wrap to the card width (no horizontal scrolling); an inline formula wider than the line is typeset at a smaller font size (down to 40%), and display math is scaled down to fit. Images are cached in memory by "LaTeX + font size". SwiftMath supports only a math subset of LaTeX (fractions, roots, sub / superscripts, Greek letters, matrices, `\sum`, `\int`, etc.); unparseable formulas show their raw text in code style.
- Math preview inside the editor (CM6) is out of scope here; card syntax highlighting applies only the protection rules above.

## Decks

- **Folder = deck**: each note is in exactly one folder, so each card belongs to one deck. Decks are hierarchical (like Anki's `A::B`), and a parent deck's limit covers all child decks; notes in the vault root belong to the root deck.
- **Tag = filtered study** (like Anki's filtered deck): you can temporarily review only "#exam", but a tag has no limits or settings of its own and does not change which deck a card belongs to.
- **Preset**: several decks share one set of settings (presets + "folder path → preset"), synced and merged per field with LWW (file format in "Settings"). A folder with no assignment inherits from its parent and the root uses the default preset. When a folder is renamed its path is updated, as with link renames.

## Scheduling

- **No self-written algorithm**. Scheduling uses swift-fsrs and parameter optimization uses fsrs-rs (the library Anki itself uses), wrapped for Swift through UniFFI; both share the same FSRS-6 set of 21 parameters `w`.
- **swift-fsrs is pinned by `revision:` to a commit**: FSRS-6 was merged into `main` in 2026-05 but the last release is still v5.0.0 (2024-10) with FSRS-5's 19 default parameters; initialization passes `FSRSDefaults.defaultWv6` or the optimized `w` explicitly. Pinned at `4fbaf20` (2026-05-25).
- **Regression tests with reference vectors**: results are compared with fsrs-rs / py-fsrs (vectors are generated into a JSON fixture by `scripts/fsrs-vectors.py`); if they cannot be matched and cannot be fixed, scheduling also moves to fsrs-rs.
- **Parameter optimization** is run manually (or prompted after a number of entries accumulate) and is disallowed when there are too few logs; the result is written back to the preset's `w`.

## Review log and replay

- **Log**: `.easynotes/srs/<deviceId>.jsonl`, appended only by that device. Fields align with Anki's `revlog` (`id` millisecond timestamp, `cid`, `ease`, `ivl`, `lastIvl`, `time`, `type`).
- **Card state is not stored separately**: it is computed by replaying every device's log and the result is cached in the rebuildable index.
- **Replay does not recompute intervals**: due dates always use the `ivl` in the log (fuzz is random and parameters may be changed by optimization); only the memory state (stability, difficulty) is recomputed with the current parameters, the same as Anki after a parameter change. This way the same logs give the same state on every device.
- **Manual operations are events too**: suspend / unsuspend, reset and leech handling are written as jsonl events (Anki revlog's Manual type), not into md.

**Log and replay details**:

- **Log format**: one JSON per line; field names and meanings follow Anki `revlog`, plus an `op` extension field:

  ```json
  {"id":1759400000123,"cid":"c-a1b2c3:r","ease":3,"ivl":-600,"lastIvl":-60,"time":5320,"type":0}
  {"id":1759400100000,"cid":"c-a1b2c3:r","ease":0,"ivl":0,"lastIvl":0,"time":0,"type":4,"op":"suspend"}
  ```

  | Field | Meaning |
  | --- | --- |
  | `id` | Review time (Unix milliseconds) |
  | `cid` | Card id (`^id` + suffix) |
  | `ease` | 1 Again, 2 Hard, 3 Good, 4 Easy; 0 for manual events |
  | `ivl` / `lastIvl` | This / last interval; positive = days, negative = seconds (learning steps) |
  | `time` | Milliseconds spent answering |
  | `type` | State at review time: 0 Learning (including New), 1 Review, 2 Relearning, 3 Filtered (early review: a review card not yet due), 4 Manual |
  | `op` | Only with `type: 4`: `suspend`, `unsuspend`, `reset` |

  Reading tolerates corrupted lines (skipped), unknown `op` (skipped) and unknown fields; the same entry (`id` + `cid` + `ease` + `op`) appearing in several files (for example conflict copies) counts once.
- **Rollover time**: "day" is computed the Anki way: a new day starts after the local rollover time (default 4 a.m.). swift-fsrs rolls over at UTC midnight, so the wrapper shifts the time by "time zone offset − rollover time" before handing it over and shifts the result back, without modifying the package.
- **Replay rules**: all devices' logs are sorted by `(id, deviceId)` and applied one by one. A rating event uses swift-fsrs with the current parameters to compute new stability / difficulty; the state after review is determined by `ivl` (negative → Learning or Relearning, positive → Review); due = the rollover time `ivl` days later, or `-ivl` seconds later. `reset` returns to New and `suspend` / `unsuspend` only toggle the suspended flag.
- **Answering and replay take the same path**: when answering, swift-fsrs (fuzz on) computes `ivl` which is written as a log entry, and then the same function replay uses applies it to the card, so live state and replay results never disagree.
- **Cache**: replay results are kept in memory and replayed once in the background at app launch; a local answer applies only the one new entry, and when another device's log file changes only cards with new entries are replayed. Measured (Apple-silicon Mac, release): 100,000 entries take about 1.3 s and personal-scale (tens of thousands) under 0.5 s, so nothing is written to disk yet; if iPhone turns out too slow, store it in `.easynotes/cache/srs/` (deletable and rebuildable) or replay in parallel.
- **Replay performance**: for review cards swift-fsrs computes all four buttons at once and rounds every value with `String(format:)`, about 47 µs per entry. Memory state depends only on S, D, elapsed days and the rating, not on card state, so replay always hands swift-fsrs a learning state and computes only the chosen rating (about 13 µs) with identical results (covered by the reference vector tests).
- **Learning steps are handled by the wrapper**: swift-fsrs (like ts-fsrs) averages the previous two steps when Hard is pressed from the second step on, whereas Anki and py-fsrs repeat the current step. So the steps handed to swift-fsrs are left empty, used only to compute memory state and day-based intervals, and steps are handled by Anki's rules ourselves. The review card Hard ≤ Good < Easy constraint follows swift-fsrs (the same as Anki; py-fsrs does not have it).

## Settings

Preset (per deck, defaults the same as Anki):

| Setting | Default |
| --- | --- |
| New cards per day | 20 |
| Reviews per day | 200 |
| Learning steps | 1m 10m |
| Relearning steps | 10m |
| Desired retention | 0.90 |
| Maximum interval | 36500 days |
| FSRS parameters `w` (21) | FSRS-6 defaults; optimization can be run |
| Leech threshold / action | 8 / tag only (can be changed to suspend) |
| New card order | file order / random |
| Review order | by due date / by retrievability |
| Bury siblings | One switch each for new and review cards |

Global: start-of-day time (default 4 a.m.), show next interval on buttons, parameter-optimization reminder.

Deliberately not exposed: starting ease, Hard / Easy multipliers, interval modifier (SM-2 only, FSRS does not use them). Fuzz is always on (Anki cannot turn it off either).

**Config files and folder rename**:

- **Each device writes its own config file**: `.easynotes/srs/<deviceId>.config.json`, containing the fields this device changed and their modification times. A single `config.json` has no registered `DocumentKind` and would become a conflict copy when two devices both change it; writing per device like the review logs avoids adding a merge extension point to Core. Reading merges all devices' files, taking for each field the value with the latest modification time (ties broken by deviceId), which is field-level LWW.

  ```json
  {"version":1,"fields":[
    {"k":["presets","p-k3x9a2","name"],"v":"Languages","t":1759400000123},
    {"k":["presets","p-k3x9a2","newPerDay"],"v":30,"t":1759400000123},
    {"k":["decks","Japanese"],"v":"p-k3x9a2","t":1759400000123},
    {"k":["global","rolloverHour"],"v":4,"t":1759400000123}
  ]}
  ```

  | Field key | Value |
  | --- | --- |
  | `presets/<id>/<field>` | A preset's field (`name`, `newPerDay`, `reviewsPerDay`, `learningSteps`…); `deleted: true` = deleted |
  | `decks/<folder path>` | A preset id; `null` = inherit from the parent |
  | `global/<field>` | `rolloverHour`, `showIntervals`, `optimizeReminder` |

  The key is an array because folder paths contain `/`. The built-in "Default" preset id is `default` and cannot be deleted; a new preset's id is `p-` + 6 random characters. Fields that do not appear use Anki's defaults.
- **Folder rename**: on an in-app rename or move (`moved`), the old path and all subpaths under it have their `decks/…` written as `null` and the new path gets the original preset. Renames by Finder or Claude Code are not detected, and that folder goes back to inheriting from its parent (no other settings are lost).
- Deleting a preset: decks using it go back to inheriting from their parent.

## Daily limits and queue

Rules follow Anki's v3 scheduler:

- **Daily limits**: new cards remaining today = limit − new cards learned today (a card's first rating log is today); reviews likewise (today's rating logs with `type` Review). Logs are counted by the deck the card is **currently** in. When starting a review from a deck, the limits of that deck and each of its descendant decks apply (ancestor decks' limits do not, as in Anki): a card must pass the remaining count at every level on the path from the chosen deck to the card's deck. The numbers in the deck list are the count "starting from this deck" would produce, so a parent's number is smaller than the sum of its children.
- **New cards are also limited by the review limit** (the default since Anki 23.10): new cards ≤ the review limit minus cards already reviewed and pending review today.
- Learning / Relearning cards are not limited.
- **Sibling burying is not stored**: a card whose note had any card reviewed today does not appear that day (new and review cards each per setting); only one card of a note goes into the queue. It is derived from today's logs and lifts automatically after rollover, so no bury event is needed.
- **New card order**: file order = by path, line number, card id suffix; random = sorted by a hash of "card id + date" (stable within a day). **Review order**: by due date (earliest first) / by retrievability (lowest first).
- **Show order**: due learning cards first; then new cards are spread evenly among review cards; when none of those exist, learning cards due within 20 minutes appear early (Anki's learn-ahead limit).
- **Leech**: when pressing Again on a review card makes lapses reach the threshold (and again each half-threshold afterwards). The action "tag only" does not change md: `leech` is a virtual tag computed from lapses that can be chosen in the tag filter; the action "suspend" additionally writes a `suspend` event.
- **Tag filter** (Anki's filtered deck): pick a tag to review only cards whose note has that tag, across all decks and not limited by daily limits; due cards first, then new cards, at most 100 at a time.
- **Undo (U)**: deletes the last line from the local log file and replays that card. It can only undo logs written by this device during this review session, and the last line must be it (if another program appended in between, undo is not possible). Only this device writes the log file, so deleting the last line and syncing it out cannot conflict.
- **Due badge**: the number on the sidebar's "Review" = pending review + learning cards of the root deck (including all child decks), with limits applied.

## Review UI

- Deck list (design `rHTaT`): a folder tree listing only folders that contain cards and their ancestors; cards in the vault root show as "Uncategorized" (last). Expandable / collapsible, with state stored locally. The statistics block (streak, retention, due forecast, heatmap) is out of scope.
- Review screen (`b2AjRQ`): card text is shown per "Card content: Markdown and LaTeX". Show front → show answer (Space) → four buttons (1–4, Space = Good). A card shows its source file and line number, its note's tags and lapses. "Edit note" (E) opens the note with `session.open(path, line:)`; Esc leaves. The top bar falls back as width shrinks: full buttons, then icon-only buttons, then the counts on a second row; the counts never wrap. Cloze: the front replaces the current `{{}}` with `[…]` and shows the other `{{}}` contents; the back marks the answer, with Back Extra below. A cloze front also has an optional type-in field (Return = show answer; the keyboard shortcuts are off while it has focus); the back shows what was typed with a check or cross, comparing with the answer ignoring case and extra whitespace. The typed text is never stored. Multi-line card content scrolls when it exceeds the screen.
- Deck options (`AYlad`): a sheet; preset menu, preset fields, global settings. "Optimize…" is disabled until fsrs-rs is integrated.

## Custom Study

Modeled on Anki's Custom Study, with only three options:

| Option | Scope | How |
| --- | --- | --- |
| Increase today's limit | One deck | Add N new and N review cards, valid only today; no separate review is opened and the deck's numbers simply grow |
| Review forgotten cards | One deck or all decks | Cards that got Again in the last N days (including today) |
| Review ahead | One deck or all decks | Review cards due within N days (including already due) |

- **Extended limits are written into the config file** and sync: key `["extend", <folder path>, "new" | "review"]`, value `{"day": <which day>, "n": <count>}`. A `day` that is not today does not count, so nothing needs clearing; each deck has at most two entries, so the file does not keep growing. Field LWW, so changes to new and to review on two devices are both kept. What is set is "how many extra in total today" (reopening shows the current value), not an increment, so saving repeatedly gives the same result. How it applies: when computing remaining counts, this deck's limit plus `n`; like ordinary limits it takes effect only when this deck lies on the path "from the chosen deck to the card's deck". "All decks" and the tag filter cannot increase limits ("All decks" computes from each top-level deck, with no single deck to add to).
- **Forgotten cards and review ahead are temporary filters** (like the tag filter): the cards are fixed at start (at most `filteredLimit`), not limited by daily limits, no new cards; siblings on the same line are buried per preset. Cards that graduate (return to Review) after answering are removed from this selection so cards not yet due do not keep reappearing; undo adds them back.
- **Review-ahead logs are written with `type: 3`** (Anki revlog's Filtered): always so when a review card is answered before its due date (only custom study produces such cards). Today's review count counts only `type: 1`, so review ahead does not use up today's review limit, the same as Anki. Memory state is computed by FSRS from the actual elapsed days as usual, with the due date following `ivl`; Again still counts as a lapse and checks for Leech.
- **Order**: forgotten cards and review ahead both follow the preset's review order.
- Entry: the "Custom Study" button at the top of the deck list (all decks) and the deck row's context menu (iPad long press; that deck); the sheet picks the option and days / count and shows how many cards will be added.

## Card browser

Modeled on Anki's Browse: view all cards in a deck.

- **Entry**: "Browse Cards" at the top of the deck list (all decks) and "Browse Cards…" in the deck row's context menu (that deck and its children). The deck can be changed inside the sheet.
- **List**: front, back (cloze marked as in the review screen; multi-line content shows only the first two lines, images shown as file names), source note and line number, tags, state (new / learning / review / suspended), due date, lapses.
- **Filter** (`CardQuery`): state (all, new, learning, review, due today, suspended, Leech); search matches front and back text and tags, and a `#` prefix matches tags only. **Sort**: by note order (path in Finder order, line number), by due date (new cards last), by lapses.
- **Actions** (context menu / long press): open the note and scroll to the line; suspend / resume; reset to new (confirmed first). All three are written as jsonl manual events (`type: 4`) and md is not changed; nothing is written for a card already in the target state.
- Reads only the in-memory replay results and index and builds no data of its own.

## Interoperability

Export TSV for Anki import; import cards and review history from Anki's `.apkg`.

**TSV export**:

- **Split into three files by note type**, exported into one folder: `basic.txt` (`::`), `basic-and-reversed.txt` (`;;`), `cloze.txt` (`{{}}`). No note-type column is written: the names of Anki's built-in types vary with the UI language (the Chinese version calls it "基本型"), so writing one would fail to match on import; instead the type is chosen in Anki's import dialog.
- **Header**: `#separator:tab`, `#html:true`, `#guid column:1`, `#deck column:2`, `#tags column:5`. Columns are guid, deck, two fields (Front / Back; Text / Back Extra for cloze, with a single-line cloze's Back Extra left empty), tags, in the same order as Anki's built-in types.
- **guid = `^id`**: re-importing makes Anki update the existing notes instead of duplicating. Lines without a `^id` are not exported.
- **Deck**: folder `Japanese/N2` → `Japanese::N2`; the vault root is left empty and Anki uses the deck chosen in the import dialog instead.
- **Tags**: the note's tags, with spaces turned into `_` and `/` into `::` (Anki's hierarchy); the virtual tag `leech` is not exported.
- **Content**: inline Markdown converts to HTML (bold, italic, strikethrough, highlight, inline code, links; `[[link]]` keeps only the display text) with `<` and `&` escaped; math `$…$` → `\(…\)` and `$$…$$` → `\[…\]` (Anki's built-in MathJax), escaping only `<`, `>` and `&` inside math, with the `}}` of a formula inside a cloze changed to `} }` (otherwise Anki ends the cloze early); `\$` → `$`. The nth `{{}}` of a cloze becomes `{{cn::…}}`. Fields containing `"` are quoted. Multi-line content: `<br>` between lines, `<br><br>` for blank lines, lists as `<ul>` / `<ol>`, code blocks as `<pre><code>`; images become `<img src="file name">` and the files themselves are not exported (put them into Anki's `collection.media` yourself). Review history does not carry over (that needs an `.apkg`).
- Entry: "Export for Anki" at the top of the deck list (all decks) and the deck row's context menu (that deck and its children).

**Anki import**:

- **Entry and flow**: the deck list's "Import from Anki" → choose an `.apkg` or `.colpkg` → analysis in the background (nothing written) → a sheet shows the summary (decks, note files, cards, review logs, images) and skipped notes with reasons → only "Import" writes.
- **Reading files**: an `.apkg` is a zip; the central directory is read ourselves, stored entries are taken directly, deflate uses the system's Compression (`COMPRESSION_ZLIB` is raw deflate), and a single entry is read out only when needed. The default format since Anki 2.1.50 uses zstd: `collection.anki21b`, `media` (protobuf `MediaEntries`) and every media file are zstd-compressed, decompressed with [facebook/zstd](https://github.com/facebook/zstd) (BSD, official SwiftPM). The collection takes the first that exists in the order `anki21b` → `anki21` → `anki2` (in the new format `anki2` is just an empty shell prompting an upgrade); the legacy `media` is JSON. The collection is written to a temporary file and opened read-only with the system SQLite3, registering the `unicase` collation that Anki's indexes use (without it queries on tables such as `fields` fail). Both schema 18 (`notetypes`, `fields`, `templates`, `decks` tables, deck names layered by `\x1f`) and schema 11 (`col.models`, `col.decks` JSON) are supported.
- **Untrusted input**: decompressed size has limits (collection 1 GB, a single media file 200 MB) and it gives up beyond them; paths inside the zip are not used and only fixed entry names are taken; a media file name takes only the last segment and must appear in the media list.
- **Note type** is decided by structure, not by name (names vary with Anki's UI language; the Chinese version's Basic is called "基本型"): a cloze type (schema 18 `notetypes.config` column 1 `kind = 1`; schema 11 `type = 1`) → `{{}}`, with the first field Text and the second Back Extra; one whose Text contains `image-occlusion:` is Image Occlusion and is skipped. A normal type with exactly two fields: one template → `::`, two → `;;`. Other types (three or more fields, custom types like Option) are skipped and listed.
- **Decks and files**: deck `A::B` → folder `A/B`. When the first field begins with "`X > Y > Z`" plus a newline (a breadcrumb), `X/Y` is a subfolder under the deck folder and `Z.md` is the file name, and the breadcrumb is removed from the card; notes without a breadcrumb go to the deck folder's "Anki Import.md". Notes of the same file are sorted by Anki's note id (creation time) with a blank line between them. A new file's frontmatter `tags` is the union of all the file's notes' tags (tags belong to the file, so notes of one file share them); Anki's hierarchy `a::b` becomes `a/b` and disallowed characters become `_`.
- **HTML → Markdown**: `<br>`, `<div>`, `<p>` break lines; `<ul>` / `<ol>` / `<li>` become lists (nested by level indentation); `<b>`, `<strong>`, `<i>`, `<em>`, `<s>`, `<del>`, `<code>`, `<a href>` become the corresponding syntax (a style spanning line breaks is paired per line); `<pre>` becomes a code block; `<img src>` → `![[file name]]` alone on a line; `[sound:x.mp3]` → `![[x.mp3]]`; MathJax `\(…\)` → `$…$` and `\[…\]` → `$$…$$`, with `[$]…[/$]` and `[$$]…[/$$]` converted likewise; a `$` in text is written `\$` (Anki's `$` is never math). Other tags (`<u>`, `<span>`, `<font>`, colors) are stripped leaving only text; HTML entities are decoded; `&nbsp;` is a space; consecutive blank lines are merged into one.
- **Cloze**: `{{c1::answer::hint}}` → `{{answer}}` (the hint is dropped). A trailing newline in the answer moves outside the cloze; a cloze inside inline code becomes code inside the cloze (`` `a {{c1::b}}` `` → `` `a `{{`b`}} ``); a code block with a single line containing a cloze becomes inline code. A note whose answer spans lines cannot be expressed (a cloze must be on one line) and is skipped and listed. When one number appears several times, EasyNotes makes one card per `{{}}` and copies that number's review history to each.
- **How a note is written**: with one line each on front and back it is written as a single-line `- front :: back`; otherwise as a multi-line note (see "Multi-line cards"): the first line is the front's first line, the rest of the front follows as child lines, then the divider `::` and the back. When the front's first line is a list, an image or blank, the first line uses the breadcrumb's last segment (the deck name if none). A cloze whose Text has one line and no Back Extra is written single-line. Each written note is parsed with `CardSyntax`, and when the type or card count differs from Anki's it is skipped and listed (for example front text containing ` :: `).
- **Identity and re-import**: `^id` uses the same hash as `CardIDFixer` (file path + first-line content) and is added at import time, so review logs can write the card id directly. When the target file exists the note is appended at the end; a note with identical content (excluding `^id`) is not written again and the card maps to the existing id. So re-importing the same `.apkg` produces no duplicate cards, and review logs newly added in Anki are filled in (the same entry counts once when read); a note whose content was changed in Anki becomes a new note and the old one stays.
- **Review logs**: Anki `revlog` entries of Learning / Review / Relearning / Filtered (`type` 0–3) are written as is into this device's jsonl (`id`, `ease`, `ivl`, `lastIvl`, `time` unchanged, `cid` replaced by the card id); manual adjustments and rescheduling (`type` 4, 5, `ease` 0) have no corresponding event and are skipped. A card that is new in Anki but has logs (was Forgotten) gets one `reset`, and a suspended card gets one `suspend`, both timed with the Anki card's modification time (the same entry on re-import). Burying and flags are not imported. Replay looks only at `ivl`, so due dates match Anki; with FSRS in Anki and the same parameters the memory state matches too.
- **Media**: only files referenced by imported notes are copied, into `Attachments/`. A same-named file with identical content is reused; a same-named file with different content gets a unique name through `importAttachment` and the reference in the note is rewritten.
- **Settings are not imported** (presets, daily limits, FSRS parameters); when Anki's rollover time differs from EasyNotes's, the summary says so.
