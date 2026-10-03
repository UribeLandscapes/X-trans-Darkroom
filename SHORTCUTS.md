Keyboard shortcuts — Chunk C

The runtime source of truth is `Sources/ShortcutLogic/Shortcuts.swift`. The menus,
window-local key monitor, and Help → Keyboard Shortcuts sheet all read that catalog.
The small internal `ShortcutLogic` target lets Checks execute the same pure policies;
there are no new third-party dependencies.

| Scope | Keys | Action |
| --- | --- | --- |
| Global | G; ⌘⌥1 | Library grid |
| Global | E; D; ⌘⌥2 | Open the selected Library photo in Develop, or show the current Develop photo |
| Library | Return / keypad Enter | Open selected photo in Develop |
| Global | Tab; ⇧Tab | Toggle inspector; toggle sidebar and inspector together |
| Global | F; ⌘⇧F | Toggle window full screen |
| Global | L | Toggle focus / Lights Out |
| Develop | T; I | Toggle canvas bar; cycle info off → filename/dimensions → exposure/camera |
| Global | ⌘/ | Keyboard Shortcuts sheet (also Help menu) |
| Library / Develop | ←; → | Previous / next in current Library sort and filter order; clamp at ends |
| Library grid | ↑; ↓ | Existing row navigation |
| Library / Develop | 0–5; ]; [ | Set, increase, decrease rating; clamp to 0…5 |
| Library / Develop | P; X; U; backtick | Pick, reject, unflag, toggle pick |
| Library / Develop | Shift + any rating/flag key above | Apply and advance, stopping at the last photo |
| Develop | Z; Space tap | Toggle fit / last zoom (100% initially) |
| Develop | Space hold + drag | Pan using existing canvas drag handling |
| Develop | ⌘=; ⌘- | Step zoom: Fit, 25%, 50%, 100%, 200%, 400%, 800%, 1600% |
| Develop | ⌘0; ⌘⌥0; ⌘⇧0 | Fit; 100%; fill |
| Develop | Backslash | Toggle before-only |
| Develop | Y; ⌥Y; ⇧Y; ⇧⌥Y | Toggle left/right; top/bottom; split left/right; split top/bottom comparisons |
| Develop | J; W; V | Clipping; WB picker; B&W |
| Develop | R | Toggle Geometry/Crop and scroll to it when opened |
| Develop | ⌘⇧R | Reset all settings in one undo entry |
| Develop | Comma; period | Select previous / next mounted inspector slider |
| Develop | = or +; - | Increase / decrease selected slider by 1% of range |
| Develop | Shift + slider adjustment | 10% of range; consecutive presses within 500 ms coalesce into one undo entry |
| Develop | ⌘⇧C; ⌘⌥C | Copy selected settings; copy all standard settings |
| Library / Develop | ⌘⇧V | Paste settings, including existing Library batch paste |
| Develop | ⌘⌥V | Paste from previous photo |
| Global | ⌘⇧E; ⌘⇧I; ⌘O | Export; Add folder; Open Image |
| Develop | ⌘Z; ⇧⌘Z | Undo; redo |
| Develop | ⌘[; ⌘] | Rotate left / right 90°, one undo entry |
| Global | Esc | Exit WB picker, else collapse Geometry, else leave full screen |

Single-key and non-Command shortcuts yield to text input and sheets. Develop-only
shortcuts also yield in Library or without an image. Rating/flag changes use the
Library catalog record for the current photo, including records hidden by filters.
Navigation saves the outgoing photo. Auto-advance captures the successor before an
annotation can remove the current photo from the filtered grid.

Intentional Lightroom differences:

- E opens Develop because this app has no Library loupe.
- L has two states, using existing focus mode; Lightroom has three.
- Import adds a folder to the existing library rather than opening a Lightroom import workflow.
- R exposes existing Geometry controls rather than a separate crop workspace.
- Space distinguishes a short tap from holding or dragging; panning already exists.
- Standard Copy All retains the existing settings policy, which excludes Geometry.
- There is no mapped Auto Tone, colour-label editing, virtual copy, Photoshop handoff,
  keywording, quick collection, soft proofing, compare/survey, or local masking tool.
  The sheet lists ⌘⇧U, 6–9, ⌘', ⌘E, ⌘K, B, S, C, N, M/⇧M, Q, K, and O as unavailable.

Files added:

- `Sources/ShortcutLogic/Shortcuts.swift`, `ShortcutPolicy.swift`: catalog, key normalization, scope checks, clamping, zoom ladder, injectable-time coalescing.
- `Sources/App/EditorShortcuts.swift`, `ShortcutSheet.swift`, `CanvasInfoOverlay.swift`: action dispatch, cheat sheet, neutral info overlay.
- `Sources/StudioTheme/SliderKeyboard.swift`: mounted-slider registry and neutral selection highlight.
- `Sources/Checks/ShortcutChecks.swift`: 132 pure/wiring checks.
- `SHORTCUTS.md`: this implementation report.

Files updated:

- `Package.swift`: share pure shortcut logic with App and Checks.
- `Sources/App/DevelopKeys.swift`, `DevelopCommands.swift`, `XTransDarkroomApp.swift`: catalog-driven monitor and menus; replace Open/Undo/Redo command groups.
- `Sources/App/EditorView.swift`, `InspectorView.swift`, `CanvasArea.swift`, `ViewerState.swift`: visibility, focused-window commands, crop scrolling, overlay, zoom ladder.
- `Sources/App/EditorModel.swift`, `Sources/EditModel/EditHistory.swift`: keyboard undo coalescing and outgoing-photo persistence.
- `Sources/App/LibraryModel.swift`, `ThumbnailGridView.swift`: current-photo annotations, serialized writes, shared horizontal/key routing, selection scrolling.
- `Sources/StudioTheme/StudioSlider.swift`: register mounted sliders and apply keyboard steps.
- `Sources/Checks/main.swift`, `StudioOverlayChecks.swift`: run shortcut checks and scan new canvas-adjacent files.

Validation: `./Scripts/verify.sh` builds all targets successfully. Final sandbox run:
1022 passed, 58 failed; all 132 new shortcut checks pass. Failures are the known
pixel-readback/GPU, HEIC, and scoped-bookmark limitations; those implementations were
not changed. For this sandbox run, module caches were redirected to `/tmp` and a
local Swift wrapper disabled SwiftPM's nested manifest sandbox. The repository gate
script was not modified. Native window interaction still needs the local UI smoke test.
No commit was created.
