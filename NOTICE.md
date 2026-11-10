# Notice

**TypingIndicators** (this distribution)
<https://github.com/TheAstroMirth/TypingIndicators>

This repository packages the TypingIndicators plugin with installers, uninstallers
and documentation for Windows and macOS. The plugin itself was not written here.

## Original work

| | |
| --- | --- |
| Plugin | TypingIndicators |
| Author | **ItzMeShadow999** |
| Source | <https://github.com/ItzMeShadow999/TypingIndicators> |
| Licence | GNU General Public License v3.0 |
| Taken from | commit `ea623bdf879c6a5c00d01f1ae2b7246a0102f6ff` (3 November 2026) |

The plugin files are copyright of their author, ItzMeShadow999, and are included
under the terms of the GNU General Public License v3.0.

## What is included from the original, unmodified

| File | SHA-256 |
| --- | --- |
| `TypingIndicators/index.tsx` | `67ea755dcb75bf41173ff9f546e7f44a32cd3f52adf9197ada3cf12bcd9208bf` |
| `TypingIndicators/style.css` | `b7211c131399a076fcb511eda52c7e706cb81b6811a2baf8ff1d44c1b3130996` |
| `LICENSE` | the GNU General Public License v3.0 text, as shipped by the original project |

These files are byte-for-byte identical to the original at the commit above.
The plugin's name, description, settings and author metadata are unchanged.

## What is not included from the original

- `install.ps1` (the original Windows installer, which can install tools and clone a client)
- `Console-Script/TypingIndicators.js`
- the original `README.md`

## What this distribution adds

Written and maintained by [TheAstroMirth](https://github.com/TheAstroMirth),
copyright (c) 2026 TheAstroMirth, licensed under the GNU General Public License v3.0:

- `installers/windows/` - installer and uninstaller for Windows 10/11
- `installers/macos/` - installer and uninstaller for macOS (Apple Silicon and Intel)
- `README.md`, `NOTICE.md`, `screenshots/README.md` - documentation
- `.gitignore`, `.gitattributes` - repository housekeeping

## Changes to the original plugin

None. If a future compatibility fix ever requires changing a plugin file, the change
will be listed here with its date, as the licence requires.

## Other projects

The plugin is written against the plugin API of
[Vencord](https://github.com/Vendicated/Vencord) (GPL-3.0-or-later) and also builds in
[Equicord](https://github.com/Equicord/Equicord). Neither project is included here, and
the installers never download them.

Vencord, Equicord and Discord are names of their respective owners. This project is
not affiliated with or endorsed by any of them.
