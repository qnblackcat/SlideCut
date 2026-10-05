# SlideCutPlus

Touch the space key, slide to a letter and release to trigger an editing shortcut.
A rewrite of SlideCut for iOS 15+.

## Better support for Vietnamese Telex

With the original SlideCut, the letter key still reached the input method. When typing Telex,
Space+A after "ha" produced "hâ", Space+X added a tilde, Space+S added an acute accent…

SlideCutPlus stops the key before it reaches the input method, so shortcuts always fire and
never add diacritics to the current word. Also:

- **Space+N** moves back to right after the previous word (`abc def xyz|` → `abc def| xyz`), so a new word doesn't stick to the word on the right.
- **Space+V** adds a trailing space after pasting, so you can keep typing.

## Shortcuts

| Key | Action | Key | Action |
|---|---|---|---|
| X / C / V | Cut / Copy / Paste (+ space) | H J K L | ← ↓ ↑ → |
| A | Select all | N / M | Previous / next word |
| Z / Y | Undo / Redo | S | Select word |
| Q / P | Start / end of line | D | Translate |
| B / E | Start / end of document | Delete | Delete word backward |

**Supports iOS 15+** (rootless / roothide). iOS 14 rootful: build it yourself; iOS 13 and below: build with the Xcode 11 toolchain.

```bash
make package THEOS_PACKAGE_SCHEME=roothide   # or rootless
```
