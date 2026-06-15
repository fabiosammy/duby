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
# ── TODO (tracked as GitHub issues — see docs/ROADMAP.md) ─────────────────────
#   [x] Pages / profiles (layers) — `layers:` + a key with `layer: next|prev|<name>`.
#   [x] systemd (--user) daemon / KDE tray to start with the session.
#   [ ] #3  Per-key on/off state (toggle) with 2 images (e.g. mute on/off).
#   [ ] #4  Live-reload the YAML when the file changes (file watch).
#   [ ] #5  Text over image (overlay), icon + caption, alignment/font/size.
#   [ ] #6  Long-press / double-press / key sequences.
#   [ ] #7  Encoders/dials (the 0x0060 has none, but the Mirabox family does).
#   [ ] #8  Configurable display map (today only a row-flip via FIFINE_FLIP_ROWS).
#   [ ] #9  Visual feedback on press (blink/highlight the key).
# ─────────────────────────────────────────────────────────────────────────────

require "yaml"
require "open3"
require_relative "lib/fifine_deck"

$stdout.sync = true # file log updates live (no buffering)

DEBOUNCE = 0.20 # s — ignore repeats of the same press within this interval
FOCUS_POLL = 0.7 # s — how often to check the focused window (for focus_layers)

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
# CLOCK_BOOTTIME advances during suspend (CLOCK_MONOTONIC does not), so a big
# jump between loop iterations means the laptop was suspended/resumed.
def boot = Process.clock_gettime(Process::CLOCK_BOOTTIME)

# Errors that mean the device went away (unplugged / suspend / re-enumerated).
DEVICE_LOST = [EOFError, IOError, SystemCallError].freeze
RESUME_GAP = 3.0 # s — a loop gap larger than this implies a suspend/resume

def log(msg) = puts("[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}")

# Open the deck, retrying until it is available (or `stop_check` becomes true).
# Returns an open Deck, or nil if asked to stop while waiting.
def wait_for_device(stop_check)
  announced = false
  until stop_check.call
    begin
      return FifineDeck::Deck.open
    rescue RuntimeError, IOError, SystemCallError
      log "Waiting for the FIFINE D6 to be available…" unless announced
      announced = true
      sleep 0.5
    end
  end
  nil
end

# Class name of the currently focused window (via kdotool). nil if unavailable.
def active_window_class
  id, st = Open3.capture2("kdotool", "getactivewindow", err: File::NULL)
  return nil unless st.success?

  id = id.strip
  return nil if id.empty?

  cls, st2 = Open3.capture2("kdotool", "getwindowclassname", id, err: File::NULL)
  return nil unless st2.success?

  c = cls.strip
  c.empty? ? nil : c
rescue StandardError
  nil
end

# Maps a window class to a layer name using `focus_layers` (ordered list of
# [pattern, layer]). First case-insensitive substring match wins; "*" = default.
def layer_for_class(klass, focus_map)
  return nil unless klass

  default = nil
  focus_map.each do |pat, lname|
    if pat.to_s == "*"
      default = lname
      next
    end
    return lname if klass.downcase.include?(pat.to_s.downcase)
  end
  default
end

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
def show_splash(deck, text:, background:, res:, color: "ffffff", brightness: nil, hold: nil)
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
  { settings: settings, layers: parse_layers(raw), keymap: parse_keymap(settings),
    base_dir: File.dirname(File.expand_path(path)),
    res: Integer(settings["res"] || FifineDeck::RES) }
end

# layers: a list of { name, keys }. Backward compatible: a top-level `keys:`
# (with no `layers:`) becomes a single layer named "main".
def parse_layers(raw)
  raw_layers = raw["layers"] || [{ "name" => "main", "keys" => raw["keys"] || {} }]
  raw_layers.each_with_index.map { |ly, i| build_layer(ly, i) }
end

def build_layer(layer, idx)
  keys = {}
  (layer["keys"] || {}).each { |k, spec| keys[Integer(k)] = spec unless spec.nil? }
  { name: (layer["name"] || "layer#{idx}").to_s, keys: keys, brightness: layer["brightness"] }
end

# optional keymap: physical pressed index (0-based) -> config key (identity default).
def parse_keymap(settings)
  (settings["keymap"] || {}).each_with_object({}) { |(from, to), m| m[Integer(from)] = Integer(to) }
end

# Render ONE key's spec to JPEG. Precedence: image > icon > text > color.
def render_spec(spec, base_dir, res)
  bg = (spec["background"] || "000000").to_s
  if (img = spec["image"])
    FifineDeck::Render.image(resolve_path(img, base_dir), size: res)
  elsif spec["icon"]
    render_icon(spec, bg, res)
  elsif (txt = spec["text"])
    FifineDeck::Render.text(txt.to_s, background: bg,
                                      color: (spec["color"] || "ffffff").to_s, font: spec["font"], size: res)
  elsif (col = spec["color"] || spec["background"])
    FifineDeck::Render.color(col.to_s, size: res)
  else
    FifineDeck::Render.color("000000", size: res) # key declared but empty -> black
  end
end

def resolve_path(path, base_dir)
  File.absolute_path?(path) ? path : File.join(base_dir, path)
end

# Render an icon spec, falling back to its text/label if no icon is found.
def render_icon(spec, bg, res)
  FifineDeck::Render.icon(spec["icon"], background: bg, size: res)
rescue RuntimeError => e
  warn "  ! #{e.message}\n    -> falling back to text"
  label = spec["text"] || Array(spec["icon"]).first
  FifineDeck::Render.text(label.to_s, background: bg, color: (spec["color"] || "ffffff").to_s, size: res)
end

# Render each layer's keys to JPEGs: returns an array of { key => jpeg }.
def render_layers(cfg)
  cfg[:layers].map do |ly|
    ly[:keys].transform_values { |spec| render_spec(spec, cfg[:base_dir], cfg[:res]) }
  end
end

# Resolve a `layer:` value (next/prev/<name>/<index>) to a layer index, or nil.
def resolve_layer(val, current, layers)
  s = val.to_s.strip
  case s.downcase
  when "next"             then return (current + 1) % layers.size
  when "prev", "previous" then return (current - 1) % layers.size
  end
  if (idx = layers.index { |ly| ly[:name].casecmp?(s) })
    return idx
  end
  return s.to_i if s.match?(/\A\d+\z/) && s.to_i < layers.size

  nil
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
  layers = render_layers(cfg)
  FifineDeck::Deck.open { |deck| deck.apply_images(layers.first, brightness: cfg[:settings]["brightness"]) }
  puts apply_summary(cfg, layers.first.size)
end

def apply_summary(cfg, count)
  n = cfg[:layers].size
  extra = n > 1 ? " (layer '#{cfg[:layers].first[:name]}'; #{n} layers total)" : ""
  "Painted #{count} key(s)#{extra}."
end

# Drives a `run` session: holds the state and supervises the device — reconnects
# on unplug, re-inits on suspend/resume, follows the focused window, and
# dispatches key presses. Split into small methods (was one large cmd_run).
class Runner
  def initialize(cfg)
    @cfg = cfg
    @res = cfg[:res]
    @layers = render_layers(cfg)
    @brightness = cfg[:settings]["brightness"]
    @welcome = cfg[:settings]["welcome"] || {}
    @goodbye = cfg[:settings]["goodbye"] || {}
    # focus_layers: ordered [pattern, layer] pairs — follow the focused window.
    @focus_map = (cfg[:settings]["focus_layers"] || {}).to_a
    @last = Hash.new(0.0) # debounce, per config key
    @current = 0          # current layer index (persists across reconnects)
    @first = true
    @stop = false
  end

  # SIGINT (Ctrl-C) / SIGTERM (systemd/session) stop the loop; then paint goodbye.
  def run
    %w[INT TERM].each { |sig| trap(sig) { @stop = true } }
    serve until @stop
    log "Deck stopped (no longer listening)."
    notify("Deck off", "Stopped listening for presses.")
  end

  private

  # One device session: (re)acquire, paint the current layer, listen until the
  # device is lost / stop is requested / a suspend-resume is detected.
  def serve
    deck = wait_for_device(-> { @stop })
    return @stop = true unless deck

    begin
      greet(deck)
      deck.apply_images(@layers[@current], brightness: @brightness)
      log "Deck ready on layer '#{layer_name}' (#{@cfg[:layers].size} layer(s)). " \
          "Listening… (Ctrl-C/SIGTERM to quit)"
      case listen(deck)
      when :stop   then paint_goodbye(deck)
      when :resume then log "Resume detected; reinitializing the deck…"
      end
    rescue *DEVICE_LOST => e
      log "Device lost (#{e.class}: #{e.message}); waiting to reconnect…"
      notify("Deck disconnected", "Waiting for the device to come back…")
      sleep 0.5
    ensure
      deck.close rescue nil
    end
  end

  def greet(deck)
    return notify("Deck reconnected", "Reloaded the current layer.") unless @first

    show_splash(deck, text: @welcome["text"] || "Hi!", background: bg(@welcome, "1e1e2e"),
                      color: fg(@welcome, "ffffff"), brightness: @brightness, res: @res, hold: 1.3)
    @first = false
    notify("Deck on", "Listening for FIFINE D6 presses.")
  end

  # Read loop. Returns :stop (quit requested) or :resume (suspend/resume gap).
  def listen(deck)
    tick = boot
    @focus_tick = 0.0
    @last_class = nil
    until @stop
      ready = deck.wait_readable(0.3) # wake up to check @stop
      now = boot
      return :resume if now - tick > RESUME_GAP # process was frozen -> re-init

      tick = now
      poll_focus(deck, now)
      handle_press(deck) if ready
    end
    :stop
  end

  # Switch the layer to match the focused window, only when the app changes.
  def poll_focus(deck, now)
    return if @focus_map.empty? || now - @focus_tick < FOCUS_POLL

    @focus_tick = now
    klass = active_window_class
    return if klass.nil? || klass == @last_class

    @last_class = klass
    name = layer_for_class(klass, @focus_map)
    target = name && resolve_layer(name, @current, @cfg[:layers])
    switch_layer(deck, target, "focus '#{klass}'") if target && target != @current
  end

  def handle_press(deck)
    idx = deck.read_press
    return unless idx

    ckey = @cfg[:keymap].fetch(idx, idx)
    now = mono
    return if now - @last[ckey] < DEBOUNCE

    @last[ckey] = now
    dispatch(deck, ckey, idx)
  end

  def dispatch(deck, ckey, idx)
    spec = @cfg[:layers][@current][:keys][ckey]
    label = ckey == idx ? "key #{idx}" : "key #{idx} → config #{ckey}"
    if spec && spec["layer"]
      target = resolve_layer(spec["layer"], @current, @cfg[:layers])
      target ? switch_layer(deck, target, label) : log("#{label}: layer '#{spec['layer']}' not found")
    elsif spec && spec["command"]
      log "#{label}: #{spec['command']}"
      run_command(spec["command"])
    else
      log "#{label}: (no command)"
    end
  end

  def switch_layer(deck, target, label)
    @current = target
    b = @cfg[:layers][@current][:brightness]
    deck.lig(b) if b
    deck.paint(@layers[@current]) # smooth switch (no re-init)
    log "#{label}: → layer '#{layer_name}'"
  end

  # Very visible "stopped" state: makes it clear ruby isn't listening anymore.
  def paint_goodbye(deck)
    show_splash(deck, text: @goodbye["text"] || "Deck OFF", background: bg(@goodbye, "2a0a0a"),
                      color: fg(@goodbye, "ff6666"), brightness: @goodbye["brightness"] || 25, res: @res)
  rescue StandardError => e
    log "couldn't paint 'OFF' (#{e.class}: #{e.message})"
  end

  def layer_name = @cfg[:layers][@current][:name]
  def bg(spec, default) = (spec["background"] || default).to_s
  def fg(spec, default) = (spec["color"] || default).to_s
end

def cmd_run(path)
  Runner.new(load_config(path)).run
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
def main(argv)
  config_path = argv[1] || "deck.yml"
  case argv[0]
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

# Run only when executed directly, so `require`/tests can load the helpers.
main(ARGV) if $PROGRAM_NAME == __FILE__
