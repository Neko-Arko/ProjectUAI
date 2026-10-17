# Cowork bridge frontend rework — implementation plan

**Status:** historical October 16 plan, superseded by the expanded 3.3.0 work.
The October 17 scope includes browser workspaces, MCP setup, provider controls,
queued follow-ups, native client improvements, and regenerated release packages.
See the [3.3.0 verification record](../docs/TESTING_3.3.0.md) for current build and
test evidence. The scope and deferred-build notes below describe the original
appearance pass, rather than current release constraints. **Reference:** the
Zola-style chat screenshot supplied by the maintainer (white, near-chrome-less
page; one centered prompt; a large rounded composer; suggestion chips below it).

This document is written for the implementing agent. It records what the
reference asks for, where every piece lives today, what must not break, and the
exact build/verification order this repository requires. Read `AGENTS.md`,
`bridge/README.md`, and `bridge/UI_AUDIT.md` before starting.

The October 16 implementation added incremental response motion and stable
live Markdown, with focused browser coverage. That initial appearance pass
deferred release numbering and package builds; the expanded 3.3.0 task now owns
those changes together with client source and guide updates.

> Note: `docs/MOBILE_COMPANION.md` says `bridge/web/` is frozen *for the Android
> companion project*. This rework is an explicit maintainer request and takes
> precedence for this task. The companion is unaffected because it speaks to
> `bridge/server.js`, never to `web/`.

---

## 1. What "minimalistic yet beautiful" means here (from the image)

The reference page is pure white with almost no chrome:

| Zola element | Cowork equivalent |
| --- | --- |
| Wordmark top-left (`Zola` + tiny mark) | `#sidebar .wordmark` "Cowork Local" (text only; no imagery) |
| Quiet top-right links (`Login`, info) | `.topbar` controls (`#themeToggle`, `#setupHelp`, `#exportChat`, `#clear`) as low-contrast icon buttons |
| Centered display heading "What's on your mind?" | `.welcome h1` (keep the product voice, e.g. "What are we working on?") |
| Large rounded composer, placeholder top-left | `#composer` with `#input` |
| Bottom-left: paperclip + model chip (`GPT-4.1 Nano ▾`) | `#attach` / `#attachPictures` + `#modelButton` (`.dot` + `#modelLabel` + chevron) |
| Circular send button bottom-right | `#send` (`#stop` swaps in while generating) |
| Suggestion pills under the composer (icon + label) | the four `.starter` entries, restyled as chips and moved below the composer |

Measured proportions to reproduce (approximate, at 1920px wide):

- Heading: ~38–42px, weight 600, tracking ≈ −0.04em, centered, near-black.
- Composer: ≈ 720–760px wide, ≈ 120px tall minimum, radius ≈ 24px, 1px
  hairline border (`#e4e4e7`), no shadow, placeholder ~15px in light gray.
- Composer toolbar: bottom row, ~14px inset; icon buttons borderless; model
  chip borderless (or 1px) with 6–8px radius; send is a 34px circle.
- Chips: 34–36px tall pills, radius 999px, 1px border, 13px label, 15px line
  icon, 8px gaps, centered and allowed to wrap.
- Composition: heading → 24–30px gap → composer → 20–24px gap → chips, all as
  one vertically centered block around 40% of the viewport height, with the rest
  of the page empty white.
- Color: essentially monochrome. Ink `#18181b`, gray `#61616b`, hairlines
  `#e4e4e7`. Color appears only in state (danger, connected dot, focus ring).

The chat is the product's showpiece; the other nine views (Connection,
Providers, Tools, Subagents, Memory & skills, Chat loops, Activity, Settings)
only need a restrained repaint so the whole app feels like one design.

---

## 2. Design system to introduce

### 2.1 Palette (light)

Use these values; the UI audit test recomputes contrast from these exact tokens,
so keep the names and the ratios.

| Token | Value | Role |
| --- | --- | --- |
| `--canvas` | `#ffffff` | page |
| `--sidebar` | `#fafafa` | rail, quiet surfaces |
| `--surface` | `#ffffff` | cards, composer |
| `--surfaceRaised` | `#f4f4f5` | hover, user bubble-free surfaces |
| `--surfaceActive` | `#ececef` | selected rows |
| `--sunk` | `#f4f4f6` | inline code |
| `--border` | `#e4e4e7` | hairlines |
| `--line-soft` | `#efeff1` | row separators |
| `--line-hard` | `#c9c9d0` | hover borders |
| `--text` | `#18181b` | ink |
| `--textSecondary` | `#52525b` | body-adjacent gray |
| `--textTertiary` | `#61616b` | captions, placeholders |
| `--solid` / `--onSolid` | `#18181b` / `#ffffff` | send button, primary |
| `--accent` | `#3f3f46` | focus ring border (neutral ink) |
| `--accentHot` | `#18181b` | links (underline for affordance) |
| `--accent-soft` | `#f4f4f5` | focus halo |
| `--accent-line` | `#e4e4e7` | quiet highlighted borders |
| `--danger` | `#b33743` | errors |
| `--success` `--warning` | `#3f6f4f` `#8a6416` | status text |

Contrast proof (WCAG 2.x): `--textTertiary #61616b` scores 6.12 / 5.86 / 5.57 /
5.19 against `#ffffff` / `#fafafa` / `#f4f4f5` / `#ececef` — all ≥ 4.5:1, which
`browser-ui-audit.js` asserts for every light surface. `--danger #b33743` is
5.93:1 on white.

### 2.2 Palette (dark, `:root[data-theme=dark]`)

`--canvas #131316`, `--sidebar #0f0f11`, `--surface #191920`,
`--surfaceRaised #24242b`, `--surfaceActive #30303a`, `--sunk #101013`,
`--border #2e2e36`, `--line-soft #232329`, `--line-hard #4a4a55`,
`--text #f4f4f5`, `--textSecondary #c3c3cc`, `--textTertiary #a1a1aa`
(≥ 5.09:1 on every surface above), `--solid #f4f4f5`, `--onSolid #18181b`,
`--danger #f49da7` (9.03:1).

### 2.3 Type, radius, spacing, motion

- Font stack unchanged (`"Segoe UI", system-ui, …`); **no webfonts** — the CSP is
  same-origin and must stay clean.
- Shape scale: chips `999px`, composer `24px`, cards/lists `12px`, dialogs
  `16px`, small controls `8px`.
- Spacing: 4px base; composer padding 14px; card padding ~20px; welcome gap 24px.
- Shadows: only `--lift` (dialogs, toast, `#latest`). Hover elevation on cards
  is removed; hover is a border/ink change.
- Motion: existing `--dur 160ms` / `--ease`; keep the global
  `prefers-reduced-motion` kill-switch and the `rise-in` used by `.message`.

---

## 3. Current file map (so edits land in the right place)

```
bridge/web/index.html        gate (#gate) + app shell (#app) + #modal + #toast
bridge/web/style.css         one stylesheet, sections: tokens, navigation,
                             conversation, composer, workspace pages, dialogs,
                             pairing, responsive, keyframes
bridge/web/app.js            all rendering: welcome(), message(), refresh(),
                             renderState(), show(), renderThreads(),
                             renderStrips(), renderQuestions(), panels, gate
bridge/web/stream-renderer.js  live preview (creates .message.agent nodes via app.js)
bridge/web/markdown.js       safe Markdown → .code-block/.copy-code, tables
bridge/web/pictures.js       picture tray cards (.picture-*)
bridge/web/drafts.js         IndexedDB draft bodies
bridge/web/theme.js          pre-paint light/dark/game resolution
bridge/web/icons.svg         <symbol> sprite consumed via <use href="icons.svg#name">
```

Key `app.js` anchors (line numbers from the current revision):

- `welcome()` ~247–260 — builds `.welcome` inside `#transcript`; the `starters`
  array lives at ~260.
- `message()` ~240, `decorateMessage()` ~241 — message/byline markup.
- `refresh()` ~191–213 — composer state, captions, banner, `body.dataset.*`.
- `renderState()` ~408–420 — theme vars, `--reading`, `--chat-font-size`,
  sidebar labels, `welcome()`.
- `show()` ~490 — page switching and focus.
- `submit()` ~755 — send pipeline (do not touch).
- `insert()` ~261 — starter → composer (keep).

Everything visual is CSS in `style.css`; no build step processes the frontend.

---

## 4. Work packages

### WP1 — tokens and base chrome (style.css)

- Replace the `:root` and dark-theme token blocks with §2. Keep every token
  **name** that other rules and `app.js` use: `--reading`, `--chat-font-size`,
  `--compose-max`, `--ease`, `--dur`, `--radius`, `--model-accent`, `--lift`,
  `--veil`, `--scroll`, `--code-bg`.
- `body` background stays `var(--canvas)`; `.topbar` loses its bottom border and
  becomes ~52px tall, transparent, with the page title in 13px/550 ink and
  `#status` quiet.
- Sidebar: `#sidebar` keeps its width and all children; visually it becomes a
  paper rail — no heavy segment borders, selected rows use `--surfaceActive`,
  `#newConversation`/`.thread` rows use hover ink instead of boxes.
- Scrollbars: keep the existing thin styling.

### WP2 — the composer (the centerpiece)

Reference silhouette, applied to `#composer`:

```css
.composer {
  max-width: 760px; margin: 0 auto; border-radius: 24px;
  border: 1px solid var(--border); background: var(--surface);
  padding: 12px 14px 10px; box-shadow: none;
}
.composer:focus-within { border-color: var(--line-hard); box-shadow: 0 0 0 4px var(--accent-soft); }
#input { min-height: 72px; font-size: 15px; line-height: 1.7; padding: 6px 6px 10px; }
#send, #stop { width: 34px; height: 34px; border-radius: 999px; }
#send:disabled { background: var(--surfaceActive); color: var(--textTertiary); }
#modelButton { border-radius: 999px; padding: 5px 10px; }
@media (max-width: 520px) { .composer { border-radius: 20px; } }
```

- Keep `.composer-content > #pictureTray / #attachments / #input` order so the
  picture tray and attachment chips still scroll inside the card.
- Keep `.composer-toolbar`, `.toolbar-divider`, `.send-slot` structure — the
  audit asserts `.composer-toolbar` never overflows horizontally, and
  `#send`/`#stop` geometry is checked in `withinViewport()`.
- Move the model chip's `.dot` to a 10px neutral glyph; keep the chevron.
- `#permissionBadge` stays (`display:none` under 1100px as today).
- `.composer-caption` becomes 11px tertiary, centered max-width 760px. Keep
  `#composerHint` (JS writes status text into it) and `.local-caption`.

### WP3 — empty state: heading, composer, chips as one block

Target composition: transcript shows only the welcome; the composer sits right
beneath the heading; suggestion chips sit beneath the composer; the group is
vertically centered. No DOM moves, no fixed positioning:

1. **`index.html`**: inside `<footer class="composer-wrap">`, after `#composer`,
   add `<div id="suggestions" class="suggestions" hidden></div>`.
2. **`app.js` — `welcome()`**: build the welcome as
   `<p class="welcome-eyebrow">Hello, David.</p>` (reuse `.welcome-greeting`),
   `<h1>What are we working on?</h1>`, the optional `.welcome-context`
   (place name + dot) — and move the starter buttons **out of `.welcome` into
   `#suggestions`**, keeping `class="starter"` on each button (tests click
   `.starter`). Set `#suggestions.hidden = !empty`. Prefer label-only chips
   (icon + short title); keep the long prompt as the button's `title` and pass
   it to `insert()` unchanged. Keep the welcome action button ("Connect Roblox
   to get started" / "Add a provider to get started").
3. **`app.js` — state flag**: set `document.body.dataset.chat = 'empty' |
   'thread'` wherever the welcome is created or removed. The transcript
   `append()` helper (app.js ~239) removes `.welcome` on the first message, and
   `welcome()` itself is called from `renderState()`, `show()`, and the
   `bridge:snapshot`/`cleared` handlers; a single helper used from those points
   keeps the flag honest.
4. **`style.css`**:

```css
body[data-chat=empty] .transcript-wrap { flex: 0 0 auto; margin-top: auto; overflow: visible; }
body[data-chat=empty] .composer-wrap { margin-bottom: auto; }
body[data-chat=empty] .composer-caption { visibility: hidden; } /* still in flow */
.welcome { text-align: center; padding: 0 0 26px; }
.welcome h1 { font-size: clamp(30px, 3.2vw, 40px); font-weight: 600; letter-spacing: -.04em; }
.suggestions { display: flex; flex-wrap: wrap; justify-content: center; gap: 8px; padding: 20px 0 0; }
.starter { border: 1px solid var(--border); border-radius: 999px; background: transparent;
  padding: 8px 14px; gap: 8px; min-height: 36px; font-size: 13px; color: var(--textSecondary); }
.starter:hover { background: var(--surfaceRaised); border-color: var(--line-hard); }
.starter .icon { width: 15px; height: 15px; }
```

   With a conversation present the existing sticky-bottom composer returns
   unchanged. Do not change `#chatPage`'s `overflow: auto` — the audit asserts
   the computed `overflow-y` is `auto`.
5. Icons for the four chips already exist in `icons.svg`: `explore`, `spark`,
   `activity`, `player`. Use text `label` + `icon(name)` for each starter. No new
   asset files.

### WP4 — transcript and messages

- `.welcome-greeting` 13px tertiary centered; `.welcome-lead` removed or kept
  at 15px secondary centered (reference has no subcopy; prefer removing it and
  keeping only the heading + context line).
- Messages: keep `.byline` (name + model + copy action) but make it quieter
  (11px, tertiary, copy button appears on hover/focus as today).
- User messages: replace `.user .body` raised box with either a hairline box or
  a right-aligned narrow block — pick the hairline box (radius 14px,
  `border:1px solid var(--border)`, `background: var(--surface)`) to preserve
  easy scanning and keep `white-space: pre-wrap`.
- Assistant body: raise `--chat-font-size` default to 15px, `line-height 1.8`,
  measure `--reading` unchanged (640–920px). `body[data-density=compact]` must
  keep working.
- Keep `.code-block`, `.code-head`, `.copy-code`, `table-scroll`, `.tool`,
  `.thinking`, `.stream-*`, `.subagent-report`, `.latest` class names and
  behaviour; restyle only (hairline borders, 12px radius, mono 12px).

### WP5 — sidebar and topbar

- Slim the wordmark to 16px/650 with the `Local` chip as a 10px hairline pill;
  hover states become ink changes, not boxes.
- Keep every id and `data-page` attribute (tests navigate through
  `#sidebar [data-page="…"]`). Keep `.more-nav nav button` at exactly **12px**
  with ≥ 38px height on mobile — both asserted.
- Topbar: keep all buttons mounted and visible (the audit clicks `#clear`
  directly); reduce to 34px icon buttons at 18px icons, tertiary color.

### WP6 — panels, dialogs, gate (quiet repaint)

- `.card` moves from 24px padding + bottom borders to hairline-separated list
  rows (~20px). Keep `.provider-card`, `.tool-grid`, `.loop-launcher`,
  `.settings-section`, `.connection-path`, `.metrics`, `.setup-*` names.
- Dialogs: radius 16px, `--lift` only, backdrop `--veil` (keep the blur), footer
  button styles unchanged in size (audit measures `#modalClose`, `#modalFooter`).
- Gate (`#gate`): drop the split layout to a single centered column on white —
  wordmark top-left, `#gate-form` card centered (no visible border), `.gate-help`
  details below. Keep `#gate-token`, `#gate-connect`, `#gate-error`, and the
  `node UAI/bridge/start.txt` text in `.gate-help` (all asserted).

### WP7 — icons

- Add only what the new chips/references need; reuse existing symbols. Keep
  `icon.svg` a blank valid SVG — the audit asserts it has zero child elements
  and is the `link[rel=icon]`, and that no `<img src="icon.svg">` exists inside
  the workspace.

---

## 5. Invariants — do not break these (asserted by `bridge/tests/`)

Selectors that must keep existing and functioning (full list from the four
browser suites): `#app`, `#gate` + `#gate-token` + `#gate-connect` + `#gate-error`
+ `.gate-help`, `#sidebar` (+ `[data-page]` buttons, `#closeSidebar`,
`#sidebarToggle`, `#profile`, `.thread`/`.thread-menu` row markup), `#workspace`,
`#panel`, `#chatPage`, `#transcript`, `#latest`, `#taskStrip`, `#questions`,
`#composer`, `.composer-toolbar`, `#input`, `#send`, `#stop` (+ inner `<span>`),
`#attachments`, `#fileInput`, `#pictureInput`, `#deliveryNotice`/`#deliveryCheck`,
`#modelButton` + `#modelLabel`, `#options`, `#clear`, `#themeToggle`,
`#modal` + `#modalBody` + `#modalFooter` + `#modalClose` + `#modalTitle` +
`#modalNotice` + `#modalForm`, `.message` + `.message.user/.agent` + `.body`,
`.starter`, `.picture-card` + `.picture-remove`, `.copy-code`,
`.stream-error .retry`, `.tool-call`, `.setting[data-state=error] .save-status`,
`[data-focus-key]`, `[data-request-key]`, `[data-setting]`, `[data-model]`.

Behavioural assertions to respect while restyling:

1. `#chatPage` computed `overflow-y` must remain `auto`.
2. `.more-nav nav button` font-size must be exactly `12px`; height ≥ 38px on
   mobile.
3. `--textTertiary` ≥ 4.5:1 against `--canvas`, `--sidebar`, `--surface`,
   `--surfaceRaised`, `--surfaceActive`, `--sunk` (light theme, computed).
4. Reduced motion: `.message` `animation-name` must compute to `none`.
5. Forced colors: `#stop > span` keeps a `ButtonText` border with ≥ 3:1 against
   its background; `#input`/`#composer` keep an outline on focus.
6. `#latest` must stay inside `#transcript`'s box and above `#composer` on short
   screens (844×390, 320×480) with a full draft, 24 tasks and a question card.
7. No horizontal overflow of `#workspace`, `#panel`, `#composer` at 320–1440px.
8. Clicking the first `.starter` inserts its prompt into `#input` (the prompt
   text itself is unchanged).
9. `#taskStrip` keeps its `<details>/<summary>` structure and open state across
   state updates; `#questions` cards keep `data-request-key` and preserve focus/
   selection on updates (CSS + existing JS; don't move these blocks).
10. Modal geometry: `#modal` never overflows horizontally; `#modalClose` and
    `#modalFooter` stay within the viewport at 320×480 and 844×390.
11. JS hooks `body.dataset.*` (`page`, `op`, `link`, `game`, `streaming`,
    `reasoning`, `density`, `codeTheme`, `theme`) must survive; add `chat`
    (see WP3) without renaming others.

If a test genuinely must change because the design removed something, change the
test in the same commit and say so in the verification record — do not silently
delete coverage.

---

## 6. How to see it while working

1. Start a real bridge: `node bridge/server.js --port 8790` (prints a token and
   `http://127.0.0.1:8790/#t=<token>`). Open that URL. With no game connected
   you get the empty welcome; the gate appears if the token is missing.
2. For a realistic conversation, use the isolated test bridge with synthetic
   state (loopback fixtures only):
   `node bridge/tests/helpers/bridge.js` helpers — `startBridge()` returns
   `base`/`token`; POST `{sessionId, snapshot:[...], state:{...}}` to
   `/api/agent/events` with `Authorization: Bearer <token>`. `browser-revamp.js`
   and `browser-ui-audit.js` contain ready-made `state` fixtures to copy.
3. Playwright lives **outside** the repo. Install it there (including Chromium),
   then set `PLAYWRIGHT_MODULE` to that package directory and optionally
   `UAI_SCREENSHOTS` to an output directory that is not inside the repository.
4. Manual review is mandatory: check light/dark/game themes, 320/390/768/1024/
   1440px, the short landscape pair (844×390, 320×480), reduced motion, forced
   colors, and 200% zoom before running the suites.

---

## 7. Order of work, build, and verification

Per `AGENTS.md`: audit every source/doc/test change manually **before** running
builds or tests; build only after the inputs are final; inspect outputs.

1. Implement WP1–WP7 in small steps; after each, `node --check bridge/web/app.js`
   (plus `stream-renderer.js`, `markdown.js`, `pictures.js`, `drafts.js`,
   `theme.js`) and review the diff by eye.
2. Update `bridge/UI_AUDIT.md` with a new dated "Cowork UI rework" section in the
   existing table format (findings → corrections), and adjust `bridge/README.md`
   "Working in the browser" if user-visible copy changed.
3. Decision required: **release version.** `dist/uai-bridge-package.json` embeds
   every `bridge/web` byte, and `dist/bridge-release.json` hashes it. If this
   ships, bump `bridge/release.js` to the next version (e.g. `3.3.0`) and record
   it per the README/CHANGELOG convention. Do **not** rebuild `dist/` before
   that decision; once decided, run:
   `node tools/build_bridge.js` → inspect both `dist/` files →
   `node tools/build_bridge.js --check`.
4. Run:
   ```
   node bridge/tests/run.js                     # non-browser suites
   luajit test/bridge_install.lua               # executor download path
   luajit test/web_runtime.lua                  # client-side bridge UI (unchanged)
   ```
5. Browser suites (Playwright installed outside the repo):
   ```
   node bridge/tests/run.js --browser-only
   ```
   Inspect the screenshots, not just the assertions. The suites already cover
   themes, CSP, drafts, pictures, focus, reduced motion and 320–1440px layouts;
   `browser-ui-audit.js` additionally covers the geometry/contrast invariants in
   §5.
6. Update the verification section of `bridge/UI_AUDIT.md` with the commands and
   observed results (mirror the existing table style), then re-run
   `node tools/build_bridge.js --check` if `dist/` was rebuilt.

---

## 8. Known risks / decisions for the implementer

- **Empty-state centering vs. `#transcript` scrolling.** In empty state the
  transcript must not scroll; with only a heading inside, `overflow: visible`
  is safe. Verify with a tiny viewport (320×480) that the chip row and composer
  still fit without a scroll trap.
- **`#attachPictures` visibility** is toggled by JS (`UAI.pictures.enabled()`);
  keep the `[hidden]` behaviour and don't style it visible.
- **Streaming tail whitespace** is intentionally `white-space: pre-wrap` around
  stable Markdown; don't collapse it while restyling.
- **`--chat-font-size`** is written by `renderState()` from the game's
  `ui.fontScale`; never hard-code chat text size.
- Do not add web fonts, remote CSS, or image assets (CSP + no-asset rule).
- Keep changes to `index.html` minimal: the only structural additions planned
  are `#suggestions` in the composer footer; everything else is CSS/JS.
