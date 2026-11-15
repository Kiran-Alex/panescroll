# Contributing to Panescroll

Thanks for helping! Panescroll is a small Swift package with no dependencies.

## Build and run

You need macOS 14 or later and Xcode 15 or later (or the Swift toolchain).

```bash
swift build                 # debug build
swift test                  # unit tests
./scripts/build-app.sh      # release build/Panescroll.app, signed if you have a certificate
open build/Panescroll.app
```

Grant Accessibility access when asked. The build script signs with your
"Apple Development" or "Developer ID" certificate if it finds one, so macOS
keeps that permission across rebuilds. Without a certificate the app is
ad-hoc signed, and you'll need to remove and re-add Panescroll in System Settings →
Privacy & Security → Accessibility after every rebuild.

To use your own bundle identifier:

```bash
BUNDLE_ID=com.example.panescroll ./scripts/build-app.sh
```

## Layout of the code

| File | What it does |
|---|---|
| `Sources/Panescroll/main.swift` | Only calls `PanescrollApp.run()` |
| `PanescrollApp.swift` | Entry point and the `--diagnose` / dev flags |
| `WindowManager.swift` | Finds windows, keeps the strips in sync, layout, animation, commands |
| `Strip.swift` | Pure strip geometry: scrolling, clamping, stack heights, layout grouping (unit-tested) |
| `AX.swift` | Accessibility API helpers and the `Window` wrapper |
| `Input.swift` | Shortcut parsing, global hotkeys, modifier + scroll event tap |
| `Config.swift` | Settings file (`~/.config/panescroll/config.json`) |
| `FrameStore.swift` | Saves each window's original frame so turning tiling off can restore it |
| `AppDelegate.swift` | Menu bar item, permission flow, wiring |
| `Panel*.swift`, `Settings.swift` | The menu bar panel and Settings window (SwiftUI) |

Coordinates: Panescroll works in Accessibility/CoreGraphics global coordinates
(origin at the top-left of the main display, y grows down). `NSScreen.axFrame`
and `axVisibleFrame` convert AppKit's bottom-left frames.

## Debugging

- `~/Library/Logs/Panescroll.log`: what Panescroll saw and did (windows found, shortcuts
  registered, permission changes). It's capped at about 1 MB.
- `Panescroll --diagnose`: prints the permission status and every window Panescroll can
  see, with role, size and whether it would be tiled. It's read-only.
- Debug builds only:
  - `swift run Panescroll --render-panel out.png [--shortcuts | --settings]`
    renders the panel or Settings window to an image.
  - `swift run Panescroll --test-layouts` applies every panel layout to your **real**
    windows and prints where each one ended up, then restores them. Quit the
    running Panescroll first.

## Screenshots

`docs/screenshot.png` is made from demo windows only, never real ones. The
debug build opens 5 windows with made-up content (`--demo-windows`). A second
instance tiles only that process (`--demo-layout <pid>`) and prints each
window's frame. Each window is captured on its own with `screencapture -l<id>`,
then the captures are composited at those frames.

## Things to keep in mind

- **Turning tiling off must always restore windows.** Any change to how
  windows are tracked has to keep `originalFrames` and `everSeen` correct.
- **Apps have minimum sizes.** Never assume a window took the size you asked
  for. Read it back (see `Window.apply` and `minSize`).
- **Panescroll ignores moves and resizes made without a mouse button held.** Its own
  moves arrive as AX notifications too, so user drags are told apart this way.
- Panescroll uses one private API, `_AXUIElementGetWindow`, looked up at runtime.
  Most macOS window managers depend on it.

## Pull requests

Keep them focused. Add tests for logic in `Strip.swift` or `Config.swift`.
For behaviour that needs real windows, describe how you tested it in the PR.

By contributing, you agree your work is licensed under the GPL-3.0 (see `LICENSE`).
