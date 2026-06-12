# FIFINE D6 — YAML stream deck controller

Control a **FIFINE Control Deck / D6** (a rebrand of the Mirabox / HotSpot
"Stream Dock" family, USB `3142:0060`) directly over `/dev/hidraw` on Linux —
no vendor app, no OpenDeck. You describe each key in a YAML file (text, an
icon, a ready image or a solid color) plus a shell command to run when the key
is pressed, and a small daemon paints the keys and listens for presses.

Built and tested on **NixOS + KDE Plasma (Wayland)**, but nothing is
distro-specific beyond the optional KDE integration.

> The HID protocol was reverse-engineered from the vendor's `libSDLibrary` and
> cross-checked against the [`mirajazz`](https://github.com/4ndv/mirajazz) Rust
> crate and the `opendeck-ampgd6` plugin. See [Hardware notes](#hardware-notes).

## Features

- **YAML-driven layout** — per key: `text`+`background`+`color`, an `icon`
  (freedesktop theme name, list of candidates, or path), a ready `image`, or a
  solid `color`; plus a `command` run on press.
- **Icon resolution** from the system icon theme (prefers colored
  `hicolor`/`breeze`, avoids monochrome `symbolic`), with automatic fallback to
  `text` when nothing is found.
- **Key-press listening** that runs your shell commands.
- **Welcome / goodbye splash screens** so it's obvious whether the deck is
  actively listening.
- **KDE system-tray daemon** (PySide6 / `QSystemTrayIcon`), autostart entry and
  a `systemd --user` unit.
- **Logging** to `deck.log` and **desktop notifications** on start/stop.

## Requirements

- A FIFINE D6 (USB `3142:0060`) and read/write access to its `/dev/hidraw*`
  node — install the udev rule (`41-fifine-d6-0060.rules`, in the parent
  directory) so it works **without `sudo`**.
- Ruby 3.x, ImageMagick (`magick` or `convert`), and a font available to
  ImageMagick.
- Optional KDE tray: Python 3 + PySide6.

Everything is provided by the bundled `shell.nix`:

```sh
nix-shell                       # drops you in a shell with all deps
nix-shell --run "ruby deck.rb run deck.yml"
```

`shell.nix` also wires `FONTCONFIG_FILE` to a DejaVu font, because a bare
`nix-shell -p imagemagick` ships no fonts and text rendering would otherwise
fail with `font (null)`.

## Quick start

```sh
cp deck.example.yml deck.yml      # then edit deck.yml
nix-shell --run "ruby deck.rb apply deck.yml"   # paint keys once
nix-shell --run "ruby deck.rb run   deck.yml"   # paint + listen (Ctrl-C to stop)
```

### Subcommands

| Command                         | Description                                            |
| ------------------------------- | ------------------------------------------------------ |
| `ruby deck.rb apply [cfg.yml]`  | Render and upload all keys, set brightness.            |
| `ruby deck.rb run   [cfg.yml]`  | Apply, then listen for presses and run commands.       |
| `ruby deck.rb listen [cfg.yml]` | Debug: print the physical pressed index (for keymaps). |
| `ruby deck.rb clear`            | Clear all keys.                                        |

The config path defaults to `./deck.yml`.

## Configuration

See [`deck.example.yml`](deck.example.yml) for a fully commented example.

```yaml
settings:
  brightness: 80
  welcome: { text: "Hi!",      background: "1e1e2e" }
  goodbye: { text: "Deck OFF", background: "2a0a0a", color: "ff6666", brightness: 25 }
  # keymap: { 0: 10 }   # optional: physical pressed index -> config key

keys:
  0:
    icon: ["firefox", "org.mozilla.firefox"]   # tries each; falls back to `text`
    text: "Firefox"
    background: "1e1e1e"
    command: "focus-or-launch firefox firefox"
  4:
    text: "GitHub"
    background: "24292e"
    command: "xdg-open https://github.com"
```

Key index is **natural top-down** (`0` = top-left, row-major):

```
 0  1  2  3  4
 5  6  7  8  9
10 11 12 13 14
```

A key's visual is chosen by precedence: **`image` > `icon` > `text` > `color`**.

> **Commands run under a non-interactive `/bin/sh -c`**, which does **not** load
> functions from your `.bashrc`/`.zshrc`. Helpers (e.g. a focus/launch wrapper)
> must be executables on your `PATH`. A reference implementation using `kdotool`
> is in [`bin/focus-or-launch`](bin/focus-or-launch).

### Useful command snippets (KDE / PipeWire)

| Action          | Command                                                                                                                                  |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Mic mute toggle | `wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle \|\| pactl set-source-mute @DEFAULT_SOURCE@ toggle`                                         |
| Maximize window | `gdbus call --session --dest org.kde.kglobalaccel --object-path /component/kwin --method org.kde.kglobalaccel.Component.invokeShortcut "Window Maximize"` |
| Lock session    | `loginctl lock-session`                                                                                                                  |
| Open a page     | `xdg-open https://example.com`                                                                                                           |

## Running as a daemon

Pick **one** approach (don't run several — they fight over the device).

### KDE system tray (recommended on KDE)

A PySide6 tray icon (`bin/deck-tray`) supervises `deck.rb run`: start/stop,
restart, open the log, quit. `yad`'s GtkStatusIcon does not show on Wayland, so
this uses Qt's `QSystemTrayIcon` (the KDE StatusNotifierItem protocol).

```sh
nix-shell --run "QT_QPA_PLATFORM=xcb python3 bin/deck-tray"   # try it
cp deck.desktop ~/.config/autostart/                          # start on login
```

### systemd --user (headless, auto-restart)

```sh
mkdir -p ~/.config/systemd/user
ln -sf "$PWD/systemd/deck.service" ~/.config/systemd/user/deck.service
systemctl --user daemon-reload
systemctl --user enable --now deck.service
```

Both deliver `SIGTERM` to the Ruby process on stop, which paints the
"Deck OFF" screen before exiting.

> `sudo` inside `nix-shell` loses the Nix `PATH`/environment, so prefer the udev
> rule over `sudo` for device access.

## Hardware notes

Reverse-engineered facts for the `3142:0060` revision (confirmed on hardware
unless noted):

- **Transport:** Mirabox "CRT" protocol. Each HID output report is
  `[report_id=0] + "CRT\0\0" + <CMD>` padded with zeros to the report size
  (512 bytes). Images are **JPEG, 126×126, rotated 180°**.
- **Image upload:** init `DIS` + `LIG(0)` + `HAN` (handshake) → `CLE` (clear) →
  `BAT <len_hi><len_lo><key+1>` + JPEG in chunks → finish `ULEND` + `STP`.
- **Key reads** (from `mirajazz`): input report starts with `"ACK"`
  (`0x41 0x43 0x4B`); byte 9 = key index (1-based, `0` = state refresh). This is
  a protocol-v2 device, so each report is one full press; 0-based key = byte9−1.
- **Index mapping:** the **display** (BAT) index is *bottom-up* row-major
  (top-left = device index 10), while **presses** report *natural top-down*
  row-major (top-left = 0). The controller row-flips only the display side
  (`Deck#display_index`), so the config index is natural top-down. Disable with
  `FIFINE_FLIP_ROWS=0`.

### Environment overrides

`FIFINE_PID`, `FIFINE_RES`, `FIFINE_ROT`, `FIFINE_MIRROR`, `FIFINE_ROWS`,
`FIFINE_COLS`, `FIFINE_FLIP_ROWS`, `FIFINE_PACKET`, `FIFINE_REPORTID`,
`FIFINE_HIDRAW`, `FIFINE_INIT`, `FIFINE_FINISH`, `FIFINE_MAGICK`, `FIFINE_FONT`.

## Troubleshooting

- **`font (null)` / text doesn't render** — no font available to ImageMagick.
  Use the bundled `shell.nix`, or set `FIFINE_FONT=/path/to/Font.ttf`.
- **`convert` is deprecated (IMv7)** — the renderer auto-detects `magick`;
  override with `FIFINE_MAGICK`.
- **Device not found / permission denied** — plug the device, close any other
  app using it, and install the udev rule (or run with `sudo`).
- **App icon falls back to text** — find the real name and add it to the `icon`
  list: `find ~/.nix-profile/share/icons /run/current-system/sw/share/icons -iname '<app>*'`.
- **Pressed key triggers the wrong command** — use `ruby deck.rb listen` to read
  the physical index and set `settings.keymap`.

## Layout

```
deck.rb              CLI runner (apply/run/listen/clear)
lib/fifine_deck.rb   device discovery, CRT protocol (read+write), JPEG rendering
deck.example.yml     commented example config
deck.yml             your config (default for the subcommands)
shell.nix            Nix dev shell (Ruby, ImageMagick, fonts, Python/PySide6)
bin/
  deck-daemon        run the listener in nix-shell, log to deck.log
  deck-stop          stop the daemon cleanly (paints "Deck OFF")
  deck-tray          KDE system-tray app (PySide6) that supervises the listener
  deck-tray-daemon   launch the tray inside nix-shell
  focus-or-launch    reference kdotool focus/launch helper
deck.desktop         KDE autostart entry
systemd/deck.service systemd --user unit
```

## Acknowledgements

Protocol understanding builds on the [`mirajazz`](https://github.com/4ndv/mirajazz)
crate and the `opendeck-ampgd6` plugin. This project talks to the device
directly and is not affiliated with FIFINE or Mirabox.
