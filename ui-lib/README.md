# Project UAI UI LIB

An independent, responsive Roblox UI library with a graphite-and-porcelain
workbench, inset fields, strong typography, and Project UAI's coral accent.

```lua
local UI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai-ui.lua"))()
```

- [API and agent guide](../docs/UI_LIBRARY.md)
- [Embedding, state binding, and application patterns](../docs/UI_LIBRARY.md#embedding)
- [Full UAI embedding reference](../docs/EMBEDDING.md)
- [Custom assistant workbench](../examples/embedding/README.md)
- [Starter script](examples/starter.lua)
- [All-controls showcase](examples/showcase.lua)
- [Built library](../dist/uai-ui.lua) and [SHA-256 manifest](../dist/uai-ui.manifest.json)

Manually review changes, build with `node tools/build_ui_lib.js`, and inspect the
outputs before checking with `luajit test/ui_library.lua`. Follow the full
verification sequence in the guide after client or documentation changes.
The library owns layout, input, state, cleanup, and the permanent
`Project UAI | UI LIB.` footer. Navigation and action labels use text; the library
draws its own brand mark and window-control glyphs. A pinned sidebar profile shows
the local player and game; Roblox supplies the headshot. Owned transitions support
reduced motion. Scripts own application logic.

Every window automatically includes an Appearance tab for palette colors,
restrained corner rounding, text size, and motion. Detailed color groups collapse
to keep common settings easy to reach. Existing setters stay reflected, and
configuration profiles retain the full appearance. `SetAppearance`,
`GetAppearance`, and `ResetAppearance` expose the same preferences to scripts.

Mobile windows leave space for the game by default and resize with a 44px touch
grip. `SetSize`, `GetSize`, and `ResetSize` expose sizing preferences while the
library handles safe insets, rotation, and keyboard obstruction.

The built-in Light/Dark action is a sun/moon header icon to the left of Minimize
and uses the existing token palettes, including open
pickers and dialogs. `GetTheme()` and `ToggleTheme()` complement `SetTheme()`;
`ThemeToggle = false` omits the built-in action. Explicit configuration profiles
also retain the chosen mode and custom accent, without a separate settings file.

The visual refresh preserves the v1 API and saved configuration format. Existing
scripts receive the updated window, navigation, controls, pickers and dialogs
without migration. Tab headings and live counts scroll with the content; the
window keeps its touch targets and keyboard-safe layout.

Use the library independently for a script UI, or pass it into a view factory
alongside a live UAI client. `Parent` chooses the owned ScreenGui's parent; it
does not dock a window into a Frame. Keep model state outside controls, use
silent setters for reflection, and register view resources with `window:Give`.
The guide covers local ModuleScript loading, configuration, asynchronous work,
responsive layouts, and adding reusable capabilities under `src/`.
