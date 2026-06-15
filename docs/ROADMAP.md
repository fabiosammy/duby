# Roadmap

Tracked work for this project, exported from the in-code TODOs and from the
lint/complexity rules that were relaxed to ship CI green. Each item links to its
GitHub issue and points at the relevant code.

## Tech debt (quality) — done ✅

| # | Item | Outcome |
| - | ---- | ------- |
| [#1](https://github.com/fabiosammy/duby/issues/1) | Reduce method complexity and tighten the RuboCop `Metrics` gate | `cmd_run` → `Runner` class; gate lowered toward defaults (cyclo 40→8, len 110→18) |
| [#2](https://github.com/fabiosammy/duby/issues/2) | Revisit relaxed RuboCop / yamllint rules | `Style/KeywordParametersOrder` re-enabled; yamllint relaxations removed (long commands folded with `>-`, line-length=100, `---`/block maps) |

The remaining relaxed RuboCop cops (`PerlBackrefs`, `RescueModifier`, `Semicolon`,
`CommentedKeyword`, `IfUnlessModifier`, `StringLiteralsInInterpolation`,
`FormatStringToken`, `Naming/MethodParameterName`, `Layout/EmptyLineAfterGuardClause`,
`Layout/HashAlignment`) are deliberate for this compact script and documented
inline in `.rubocop.yml`.

## Features (from the `deck.rb` TODO header)

| # | Item | Where |
| - | ---- | ----- |
| [#3](https://github.com/fabiosammy/duby/issues/3) | Per-key on/off toggle state (two images) | `render_spec`, press handler in `cmd_run` |
| [#4](https://github.com/fabiosammy/duby/issues/4) | Live-reload the config on file change | `load_config`, `render_layers`, `cmd_run` |
| [#5](https://github.com/fabiosammy/duby/issues/5) | Text-over-image overlay + icon + caption + layout controls | `FifineDeck::Render`, `render_spec` |
| [#6](https://github.com/fabiosammy/duby/issues/6) | Long-press / double-press / key sequences | press handling in `cmd_run`, `Deck#read_press` |
| [#7](https://github.com/fabiosammy/duby/issues/7) | Encoder/dial support (Mirabox family) | `Deck#read_press` in `lib/fifine_deck.rb` |
| [#8](https://github.com/fabiosammy/duby/issues/8) | Configurable per-device display map | `Deck#display_index`, `probe.rb grid` |
| [#9](https://github.com/fabiosammy/duby/issues/9) | Visual feedback on key press | press handling in `cmd_run` |

Each issue body lists the concrete steps. The `deck.rb` TODO header annotates
every open item with its issue number.

## Done

- Layers / pages (`layers:` + `layer: next|prev|<name>`, focus-following).
- Self-healing daemon (reconnect on unplug, re-init on suspend/resume).
- KDE system-tray daemon (PySide6), autostart and `systemd --user` unit.
- CI: RuboCop, smoke test, shellcheck, ruff, yamllint, `nix-instantiate`.
