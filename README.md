# SlideCutPlus

Touch the space key, slide to a letter and release to trigger an editing shortcut.
A from-scratch rewrite inspired by SlideCut (r_plus), for rootless and roothide jailbreaks.

## Better support for Vietnamese Telex

With the original SlideCut, the letter key still reached the input method. When typing Telex,
Space+A after "ha" produced "hâ", Space+X added a tilde, Space+S added an acute accent…

SlideCutPlus stops the key before it reaches the input method (the `kbd` daemon), so shortcuts
always fire and never compose diacritics into the current word. Also:

- **Space+N** moves back to right after the previous word's last letter (`abc def xyz|` → `abc def| xyz`), so a new word can be typed without sticking to the word on the right.
- **Space+V** adds a trailing space after pasting, so you can keep typing.

## Shortcuts

| Key | Action | Key | Action |
|---|---|---|---|
| X / C / V | Cut / Copy / Paste | H J K L | ← ↓ ↑ → |
| A | Select all | N / M | Previous / next word |
| Z / Y | Undo / Redo | S | Select word |
| Q / P | Start / end of line | D | Define |
| B / E | Start / end of document | Delete | Delete word backward |

Works in Safari and web views too.

## Compatibility

Officially supported: **iOS 15 and later** (rootless / roothide).

The package is built for iOS 14+, so it will also install on a future rootless / roothide jailbreak for iOS 14. Older setups are not supported, but you can build it yourself:

- **iOS 14 rootful**: build without `THEOS_PACKAGE_SCHEME` (`make package`).
- **iOS 13 and below**: build with the Xcode 11 toolchain (required for the old arm64e ABI) and lower the deployment target in the `Makefile` and `control` accordingly.

## Build

```bash
export THEOS=~/theos
make package THEOS_PACKAGE_SCHEME=roothide   # or rootless
```
