# HyprMac

A keyboard-first tiling window manager for macOS, inspired by [Hyprland](https://hyprland.org).

Caps Lock becomes a **Hypr** modifier, and from there you get BSP dwindle tiling, ten virtual
workspaces, directional focus and swapping, drag-to-edge insertion, and focus-follows-mouse. It
uses the Accessibility APIs only, so there is no need to disable System Integrity Protection.

Website and guides: **[hyprmac.app](https://hyprmac.app)**

[![HyprMac demo](docs/screenshots/demo-thumb.png)](https://github.com/user-attachments/assets/1f6f12ff-8e89-49ab-8be9-f2996025763a)

HyprMac is in active development. Bug reports are welcome.

## Requirements

- macOS 13 (Ventura) or later
- Accessibility permission, in System Settings → Privacy & Security → Accessibility
- For the default Caps Lock Hypr key: Caps Lock must stay set to **"⇪ Caps Lock"** in System
  Settings → Keyboard → Keyboard Shortcuts → Modifier Keys, not "No Action". HyprMac remaps it
  to F18 itself. Other Hypr keys, such as Tab, backtick, or F13–F20, do not use that pane.

## Install

Homebrew:

```sh
brew tap zacharytgray/hyprmac
brew install --cask hyprmac
```

Direct download: [HyprMac.dmg](https://github.com/zacharytgray/HyprMac/releases/latest/download/HyprMac.dmg).
That stable link starts working with the next release; until then, grab the versioned DMG from the
[releases page](https://github.com/zacharytgray/HyprMac/releases). Open the DMG and drag HyprMac to
Applications.

Build from source:

```sh
git clone https://github.com/zacharytgray/HyprMac.git
cd HyprMac

brew install xcodegen
xcodegen generate

export DEVELOPMENT_TEAM=YOUR_TEAM_ID
xcodebuild -project HyprMac.xcodeproj -scheme HyprMac -configuration Debug \
  -derivedDataPath build DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM build

cp -r build/Build/Products/Debug/HyprMac.app /Applications/
```

## Getting started

Follow the [install guide](https://hyprmac.app/guides/install/) for first-run setup, permissions,
and the recommended macOS settings. Once the app is running, press **Hypr+K** for the keybind
overlay, which always shows your current bindings.

## Default keybinds

Everything below is configurable in Settings → Keybinds, including which physical key acts as Hypr.
The full reference lives at [hyprmac.app/guides/keybinds](https://hyprmac.app/guides/keybinds/).

| Shortcut | Action |
|----------|--------|
| `Hypr + ←/→/↑/↓` | Focus window in direction |
| `Hypr + Shift + ←/→/↑/↓` | Swap window in direction |
| `Hypr + Ctrl + ←/→` | Move window to adjacent monitor |
| `Hypr + Ctrl + Shift + ←/→/↑/↓` | Resize focused window in direction |
| `Hypr + 1–9` / `Hypr + 0` | Switch to workspace 1–9 / workspace 10 |
| `Hypr + Shift + 1–9` / `Hypr + Shift + 0` | Move window to workspace 1–9 / workspace 10 |
| `Hypr + Tab` / `Hypr + Shift + Tab` | Cycle occupied workspaces on this monitor |
| `Hypr + F` | Move window to a dedicated workspace on its display |
| `Hypr + T` | Toggle floating and tiled |
| `Hypr + Shift + T` | Cycle focus through floating windows |
| `Hypr + J` | Toggle split direction |
| `Hypr + S` / `Hypr + Shift + S` | Toggle scratchpad / send window to scratchpad |
| `Hypr + W` | Close window |
| `Hypr + P` | Pause or resume tiling |
| `Hypr + K` | Show the keybind overlay |
| `Hypr + O` | Show workspace overview |
| `Hypr + Return` | Launch or focus Terminal |
| ``Hypr + ` `` | Warp the cursor to the menu bar |

With the mouse: hover to focus when focus-follows-mouse is on, drag a tiled window onto a target
edge to insert it there, and hold Hypr while dragging to swap two windows.

## Updating

HyprMac checks for updates on its own through Sparkle and offers to install them, or use the
menu bar icon → "Check for Updates...". Homebrew installs can run `brew upgrade --cask hyprmac`.
After any update, macOS may ask you to re-grant Accessibility permission, because the signature
changes with each release.

## Docs

- [Architecture](docs/architecture.md): subsystems, ownership rules, threading
- [Tiling algorithm](docs/tiling-algorithm.md): BSP dwindle, smart insert, two-pass layout
- [Keybinds and actions](docs/keybinds-and-actions.md): the `Action` enum and its JSON schema
- [Debugging](docs/debugging.md): Console filters, verbose logging, common recipes
- [Release pipeline](docs/release.md): how a release is built, signed, and published

## Contributing

Issues and pull requests are welcome. Before you open a pull request, run the test gate:

```sh
./scripts/test-isolated.sh --debug-variant
```

## Inspired by

- [Hyprland](https://hyprland.org): the Wayland compositor this project takes after
- [yabai](https://github.com/koekeishiya/yabai): macOS tiling window manager
- [AeroSpace](https://github.com/nikitabobko/AeroSpace): Swift tiling window manager with virtual workspaces
- [Amethyst](https://github.com/ianyh/Amethyst): macOS tiling window manager
- [skhd](https://github.com/koekeishiya/skhd): hotkey daemon

## License

[MIT](LICENSE)
