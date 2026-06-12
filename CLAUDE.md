# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

A YAML-driven controller for the **FIFINE Control Deck / D6** (Mirabox/HotSpot
"Stream Dock" clone, USB `3142:0060`) talking directly to `/dev/hidraw` on
Linux. See `README.md` for the user-facing docs.

## Architecture

- `lib/fifine_deck.rb` — module `FifineDeck`:
  - `Device` — find the hidraw node via sysfs, parse the HID report descriptor.
  - `Deck` — transport + CRT protocol: `write_report`, named commands
    (`dis`/`lig`/`han`/`bat`/`stp`/`ulend`/`cle`…), `apply_images`, and
    `read_press` (+ `wait_readable`) for key input. `display_index` does the
    row-flip (see Hardware below).
  - `Render` — `color`/`text`/`icon`/`image` → JPEG via ImageMagick. Detects
    `magick` vs `convert`; finds a font (`fc-list`/`FIFINE_FONT`); resolves
    theme icons.
- `deck.rb` — CLI (`apply`/`run`/`listen`/`clear`), YAML loading, per-key render
  dispatch, the press loop, welcome/goodbye splashes, signals, notifications.
  Supports `layers:` (pages); a key with `layer: next|prev|<name>|<index>`
  switches via `Deck#paint` (repaint, no re-init). Top-level `keys:` = 1 layer.
- `probe.rb` — explorer/debugger built on the lib (`info`/`doctor`/`blink`/
  `probe`/`probe-res`/`orient`/`grid`/`listen`/`raw`) for adapting to other
  Mirabox decks; uses RAW device indices (no row-flip) so it reveals true order.
- `bin/` — daemon launchers, KDE tray (PySide6), helpers.
- `shell.nix` — dev shell (Ruby, ImageMagick, DejaVu font, Python/PySide6).

## Hardware facts (don't re-derive)

- Image = JPEG **126×126, Rot180**, report size **512**, report_id **0**.
- Write: init `DIS`+`LIG(0)`+`HAN` → `CLE` → `BAT <hi><lo><key+1>` + chunks →
  `ULEND`+`STP`.
- Read: input report starts with `"ACK"` (0x41 0x43 0x4B); **byte 9 = key index
  (1-based, 0 = refresh)**; proto v2 → one report per press; 0-based key = byte9−1.
- **Index mapping:** display (BAT) is bottom-up row-major (top-left = device 10);
  presses are natural top-down (top-left = 0). The config index is natural
  top-down; `Deck#display_index` row-flips only the display side.

## Conventions

- Ruby: `# frozen_string_literal: true`, two-space indent, small methods. Match
  the existing style.
- Comments and the personal `deck.yml` are in **pt-BR**; `README.md` and
  `deck.example.yml` are in **English**. Keep new user-facing docs in English.
- Don't fabricate brand logos; use installed system icons via `icon:`.

## Testing without hardware

Rendering needs no device — exercise it directly:

```sh
ruby -c deck.rb && ruby -c lib/fifine_deck.rb
ruby -e 'require_relative "lib/fifine_deck"; File.binwrite("/tmp/t.jpg",
  FifineDeck::Render.text("Hi", background:"1e1e2e"))'
```

`apply`/`run` render all keys first, then open the device, so render errors
surface before any hidraw access. There is no automated test suite.

## Gotchas

- `sudo` inside `nix-shell` drops the Nix PATH/env — prefer the udev rule for
  device access.
- `nix-shell -p imagemagick` has no fonts (`font (null)`); `shell.nix` fixes it.
- KDE Wayland: `yad`/GtkStatusIcon trays don't show — use the PySide6 tray
  (`QSystemTrayIcon`/SNI). Launch it with `QT_QPA_PLATFORM=xcb`.
- Only run one daemon (tray OR systemd OR plain) — they contend for the device.
