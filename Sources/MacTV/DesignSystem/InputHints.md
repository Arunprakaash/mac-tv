# Input hints (dialog contract)

Footer legends for every focus-navigable sheet and modal. Implementation: `InputHints.swift`.

## Rules

1. Use `InputHintsBar` — never plain-text legends (`Esc or Back…`, `↑ ↓ Choose…`).
2. **No header Done.** Dismiss with Back/Close; glyphs follow the active input. The Close hint is clickable, so mouse and trackpad users still have a way out.
3. Prefer a `HintSet` preset over a custom action list.
4. Glyphs track `TVController.lastInputKind` (last command source). Mouse/trackpad → keyboard.
5. Remote glyphs match the phone remote (OK disc, chevron Back, clickpad chevrons). Controllers show the d-pad for moves.
6. Grids use one `move` hint (all four directions), never two "Choose" hints.
7. Home and Movies keep their status rows as they were: no always-on legend there (Home shows the controller strip only while one is connected).

## Hint sets

| Set | Actions |
|-----|---------|
| `list` | Choose · Select · Close |
| `listAdjust` | Choose · Change · Select · Close |
| `form` | Choose · Select · Close |
| `arrange` | Choose app · Choose action · Apply · Close |
| `chooser` | Select · Close |
| `pick` | Choose · Select (non-dismissible) |
| `info` | Close |

## OK verb

The Select glyph’s label follows what OK actually does on the focused row:

- **Toggle** — on/off settings (Skip Intros, Keep Awake, language chips, …)
- **Open** — pushes another sheet (Add App, Audio, Pairing, …)
- **Confirm / Sleep / Turn Off / Copy / Update / Preview** — one-shot actions
- **Select** — default (open section, pick item)

Never show **Change** and **Toggle** together: if ←→ and OK do the same flip, hint **Toggle** only. Multi-value steppers hint **Change** (←→) and omit a redundant OK verb.

## Shell

Sheets over home: `tvPanel`, radius 44. Full-bleed screens (Settings, Setup, Profiles, Control Center) keep their layout but still show the footer bar.
