#!/usr/bin/env ruby
# frozen_string_literal: true

# ─────────────────────────────────────────────────────────────────────────────
# deck.rb — control the FIFINE Control Deck / D6 (0x0060) from a YAML file.
#
# The "simple" idea: in the YAML you describe each key with TEXT+background, a
# ready IMAGE or just a COLOR, plus a shell COMMAND to run when it is pressed.
# `deck.rb` paints the keys and (optionally) keeps listening for presses and
# firing the commands.
#
# USAGE:
#   sudo ruby deck.rb apply  [config.yml]   # paint all keys and set brightness
#   sudo ruby deck.rb run    [config.yml]   # paint + listen + run commands (Ctrl-C to quit)
#   sudo ruby deck.rb listen [config.yml]   # DEBUG: just print the pressed key index
#   sudo ruby deck.rb clear                 # clear all keys
#
# config.yml default = ./deck.yml (see deck.example.yml).
#
# Same ENV as fifine_d6_deck.rb (FIFINE_PID, FIFINE_RES, FIFINE_ROT, ...).
# IMPORTANT: close OpenDeck first (they fight over the device). Use sudo or the
# udev rule (41-fifine-d6-0060.rules).
#
# ── TODO (things stream decks usually do, left for later) ─────────────────────
#   [ ] Pages / profiles (several 15-key screens, a key to switch).
#   [ ] Per-key on/off state (toggle) with 2 images (e.g. mute on/off).
#   [ ] Live-reload the YAML when the file changes (file watch).
#   [ ] systemd (--user) daemon/service to start with the session.
#   [ ] Text over image (overlay), icon + caption, alignment/font/size.
#   [ ] Long-press / double-press / key sequences.
#   [ ] Encoders/dials (the 0x0060 has none, but the Mirabox family does).
#   [ ] Configurable display map (today the display assumes index == config).
#   [ ] Visual feedback on press (blink/highlight the key).
# ─────────────────────────────────────────────────────────────────────────────

require "yaml"
require_relative "lib/fifine_deck"

$stdout.sync = true # file log updates live (no buffering)

DEBOUNCE = 0.20 # s — ignore repeats of the same press within this interval

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def log(msg) = puts("[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}")

# KDE (systray) notification. Silent if notify-send is missing.
def notify(summary, body = "")
  Process.detach(Process.spawn("notify-send", "-a", "FIFINE Deck",
                               "-i", "input-keyboard", summary, body,
                               out: File::NULL, err: File::NULL))
rescue StandardError
  # no notify-send: ignore
end

# Paint a full screen (all keys with `background`, message on the center key).
# Used for the welcome screen and the "stopped" state on shutdown.
def show_splash(deck, text:, background:, color: "ffffff", brightness: nil, res:, hold: nil)
  bg  = FifineDeck::Render.color(background, size: res)
  msg = FifineDeck::Render.text(text, background: background, color: color, size: res)
  jpegs = {}
  FifineDeck::KEYS.times { |k| jpegs[k] = bg }
  jpegs[FifineDeck::KEYS / 2] = msg # center key (7 on a 3x5)
  deck.apply_images(jpegs, brightness: brightness)
  sleep hold if hold
end

def load_config(path)
  unless File.exist?(path)
    abort "Config not found: #{path}\n(create a deck.yml — see deck.example.yml)"
  end
  raw = YAML.safe_load_file(path) || {}
  settings = raw["settings"] || {}
  base_dir = File.dirname(File.expand_path(path))

  # normalize key indexes to Integer (YAML may give "0" or 0)
  keys = {}
  (raw["keys"] || {}).each do |k, spec|
    next if spec.nil?
    keys[Integer(k)] = spec
  end

  # optional keymap: physical pressed index (0-based, = byte9-1) -> config key.
  # Default = identity. Use `listen` to discover the physical index and adjust.
  keymap = {}
  (settings["keymap"] || {}).each { |from, to| keymap[Integer(from)] = Integer(to) }

  { settings: settings, keys: keys, keymap: keymap, base_dir: base_dir,
    res: Integer(settings["res"] || FifineDeck::RES) }
end

# Render ONE key's spec to JPEG. Precedence: image > icon > text > color.
def render_spec(spec, base_dir, res)
  bg = (spec["background"] || "000000").to_s
  if (img = spec["image"])
    path = File.absolute_path?(img) ? img : File.join(base_dir, img)
    FifineDeck::Render.image(path, size: res)
  elsif (ico = spec["icon"])
    begin
      FifineDeck::Render.icon(ico, background: bg, size: res)
    rescue RuntimeError => e
      warn "  ! #{e.message}\n    -> falling back to text"
      label = spec["text"] || Array(ico).first
      FifineDeck::Render.text(label.to_s, background: bg,
                              color: (spec["color"] || "ffffff").to_s, size: res)
    end
  elsif (txt = spec["text"])
    FifineDeck::Render.text(txt.to_s,
                            background: (spec["background"] || "000000").to_s,
                            color:      (spec["color"] || "ffffff").to_s,
                            font:       spec["font"],
                            size:       res)
  elsif (col = spec["color"] || spec["background"])
    FifineDeck::Render.color(col.to_s, size: res)
  else
    FifineDeck::Render.color("000000", size: res) # key declared but empty -> black
  end
end

def render_all(cfg)
  cfg[:keys].transform_values { |spec| render_spec(spec, cfg[:base_dir], cfg[:res]) }
end

def run_command(cmd)
  return if cmd.nil? || cmd.to_s.strip.empty?
  pid = Process.spawn("/bin/sh", "-c", cmd.to_s, pgroup: true)
  Process.detach(pid)
rescue StandardError => e
  warn "  ! failed to run #{cmd.inspect}: #{e.message}"
end

# ── commands ──────────────────────────────────────────────────────────────────
def cmd_apply(path)
  cfg = load_config(path)
  jpegs = render_all(cfg)
  FifineDeck::Deck.open do |deck|
    deck.apply_images(jpegs, brightness: cfg[:settings]["brightness"])
  end
  puts "Painted #{jpegs.size} key(s)."
end

def cmd_run(path)
  cfg = load_config(path)
  res = cfg[:res]
  jpegs = render_all(cfg)
  brightness = cfg[:settings]["brightness"]
  w = cfg[:settings]["welcome"] || {}
  g = cfg[:settings]["goodbye"] || {}
  last = Hash.new(0.0)

  # SIGINT (Ctrl-C) and SIGTERM (systemd/session) -> stop the loop and paint goodbye.
  stop = false
  %w[INT TERM].each { |sig| trap(sig) { stop = true } }

  FifineDeck::Deck.open do |deck|
    # welcome
    show_splash(deck, text: w["text"] || "Hi!",
                background: (w["background"] || "1e1e2e").to_s,
                color: (w["color"] || "ffffff").to_s,
                brightness: brightness, res: res, hold: 1.3)
    deck.apply_images(jpegs, brightness: brightness)
    log "Deck on: #{jpegs.size} keys painted. Listening for presses… (Ctrl-C/SIGTERM to quit)"
    notify("Deck on", "Listening for FIFINE D6 presses.")

    until stop
      next unless deck.wait_readable(0.3) # wake up to check `stop`
      idx = deck.read_press
      next unless idx
      ckey = cfg[:keymap].fetch(idx, idx)
      now = mono
      next if now - last[ckey] < DEBOUNCE
      last[ckey] = now
      spec = cfg[:keys][ckey]
      label = ckey == idx ? "key #{idx}" : "key #{idx} → config #{ckey}"
      if spec && spec["command"]
        log "#{label}: #{spec['command']}"
        run_command(spec["command"])
      else
        log "#{label}: (no command)"
      end
    end
  ensure
    # very visible "stopped" state: makes it clear ruby is no longer listening.
    # best-effort: if the device is gone, don't let that mask the original error.
    begin
      show_splash(deck, text: g["text"] || "Deck OFF",
                  background: (g["background"] || "2a0a0a").to_s,
                  color: (g["color"] || "ff6666").to_s,
                  brightness: g["brightness"] || 25, res: res) if deck
    rescue StandardError => e
      log "couldn't paint 'OFF' (#{e.class}: #{e.message})"
    end
    log "Deck stopped (no longer listening)."
    notify("Deck off", "Stopped listening for presses.")
  end
rescue EOFError
  abort "Device disconnected."
end

def cmd_listen(path)
  # Doesn't require a config; used to discover the physical key mapping.
  res_cfg = File.exist?(path) ? load_config(path) : nil
  keymap  = res_cfg ? res_cfg[:keymap] : {}
  FifineDeck::Deck.open do |deck|
    puts "Press keys to see the index (Ctrl-C to quit)."
    puts "Use this to build `settings.keymap` if the pressed key ≠ the painted key."
    loop do
      idx = deck.read_press
      next unless idx
      mapped = keymap.fetch(idx, idx)
      extra = mapped == idx ? "" : "  (mapped to config #{mapped})"
      puts "  press: physical index #{idx}#{extra}"
    end
  end
rescue Interrupt
  puts "\nBye."
rescue EOFError
  abort "Device disconnected."
end

def cmd_clear
  FifineDeck::Deck.open do |deck|
    deck.init!
    deck.clear_all
    deck.finish!
  end
  puts "Keys cleared."
end

# ── dispatch ──────────────────────────────────────────────────────────────────
config_path = ARGV[1] || "deck.yml"
begin
  case ARGV[0]
  when "apply"  then cmd_apply(config_path)
  when "run"    then cmd_run(config_path)
  when "listen" then cmd_listen(config_path)
  when "clear"  then cmd_clear
  else
    puts File.read(__FILE__)[/^# USAGE:.*?# ────/m].gsub(/^# ?/, "")
  end
rescue Errno::EACCES, Errno::EPERM
  abort "No permission to open the device. Run with sudo or install the udev rule " \
        "(41-fifine-d6-0060.rules)."
rescue RuntimeError => e
  abort "Error: #{e.message}"
end
