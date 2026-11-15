#!/usr/bin/env ruby
# frozen_string_literal: true

# Hardware-free smoke test: exercises the render pipeline and YAML loading
# (no /dev/hidraw needed). Run with:  ruby test/smoke.rb
# Requires ImageMagick and a font available to it (see shell.nix).

require "fileutils"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
require File.join(ROOT, "deck.rb") # defines helpers; main is guarded so it won't run

@failures = []
def check(desc)
  ok = yield
  puts "#{ok ? '✓' : '✗'} #{desc}"
  @failures << desc unless ok
rescue StandardError => e
  puts "✗ #{desc} (#{e.class}: #{e.message})"
  @failures << desc
end

# A valid JPEG starts with FF D8 and ends with FF D9.
def jpeg?(bytes)
  bytes.is_a?(String) && bytes.bytesize > 100 &&
    bytes.byteslice(0, 2) == "\xFF\xD8".b && bytes.byteslice(-2, 2) == "\xFF\xD9".b
end

R = FifineDeck::Render

check("render solid color -> JPEG") { jpeg?(R.color("1e1e2e")) }
check("render text -> JPEG")        { jpeg?(R.text("Hi", background: "1e1e2e", color: "ffffff")) }
check("render image (mago.png) -> JPEG") do
  jpeg?(R.image(File.join(ROOT, "mago.png")))
end
check("display_index round-trips within range") do
  d = FifineDeck::Deck.allocate
  (0...FifineDeck::KEYS).map { |k| d.display_index(k) }.sort == (0...FifineDeck::KEYS).to_a
end
check("parse_descriptor reads report id / size / vendor page") do
  # synthetic HID descriptor: Usage Page (vendor FF00), Report Size 8,
  # Report Count 64, Output -> report_id 0, out_bytes 64, vendor_page true.
  desc = [0x06, 0x00, 0xFF, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02].pack("C*")
  FifineDeck::Device.parse_descriptor(desc) ==
    { report_id_out: 0, out_bytes: 64, vendor_page: true }
end

# End-to-end: load and render the example configs.
%w[deck.example.yml deck.layers.example.yml].each do |name|
  path = File.join(ROOT, name)
  check("#{name}: loads and renders every key to a JPEG") do
    cfg = load_config(path)
    jpegs = render_layers(cfg).flat_map(&:values)
    !jpegs.empty? && jpegs.all? { |j| jpeg?(j) }
  end
end

# Status keys: every state of the example config renders (needs ImageMagick).
check("deck.example.yml: every status state renders to a JPEG") do
  cfg = load_config(File.join(ROOT, "deck.example.yml"))
  board = StatusBoard.new(cfg, render_layers(cfg))
  !board.empty? && board.jpegs(0).values.all? { |j| jpeg?(j) }
end

# focus_layers / layer resolution logic.
check("layer_for_class maps via substring + '*' default") do
  fm = { "code" => "dev", "*" => "home" }.to_a
  layer_for_class("VSCode-ish Code", fm) == "dev" && layer_for_class("plasmashell", fm) == "home"
end

# ── status key state machine ─────────────────────────────────────────────────
# From here on the renderer is STUBBED (a state's "image" is just its spec), so
# the state machine is exercised without ImageMagick and states are comparable.
def render_spec(spec, _base_dir, _res) = "img:#{spec['text']}/#{spec['background']}"

STATES = {
  "busy" => { "text" => "···", "background" => "3a2f00" },
  "done" => { "text" => "ok", "background" => "0a2a0a", "hold" => 2 }
}.freeze

def status_key(source, states, track: nil)
  spec = { "text" => "Base", "background" => "111111", "track" => track,
           "status" => { "source" => source, "states" => states } }
  StatusKey.new(0, spec, "img:base", base_dir: ROOT, res: 126)
end

tmp = File.join(Dir.tmpdir, "duby-smoke-#{Process.pid}")
FileUtils.mkdir_p(tmp)

check("status: a file source drives the state, `hold` reverts to the base image") do
  file = File.join(tmp, "one.state")
  File.write(file, "busy\n")
  k = status_key({ "file" => file }, STATES)
  busy = k.tick(0.0)
  File.write(file, "DONE") # case/whitespace insensitive
  done = k.tick(1.0)
  [busy == "img:···/3a2f00", done == "img:ok/0a2a0a",
   k.tick(2.0).nil?,            # still within `hold: 2`
   k.tick(3.5) == "img:base",   # hold expired -> back to the key's own image
   k.tick(4.0).nil?].all?       # the file still says "done": stays on the base
end

check("status: no state (file gone / unknown name) falls back to the base image") do
  file = File.join(tmp, "two.state")
  File.write(file, "busy")
  k = status_key({ "file" => file }, STATES)
  busy = k.tick(0.0)
  File.delete(file)
  gone = k.tick(1.0)
  File.write(file, "busy")
  k.tick(2.0)
  File.write(file, "nonsense")
  [busy == "img:···/3a2f00", gone == "img:base", k.tick(3.0) == "img:base"].all?
end

check("status: after a `hold` expires, the same state shows again once the file resets") do
  file = File.join(tmp, "three.state")
  File.write(file, "done")
  k = status_key({ "file" => file }, STATES)
  k.tick(0.0)
  k.tick(2.5)              # hold expired -> base, "done" muted
  File.delete(file)
  k.tick(3.0)              # file gone: the mute lifts
  File.write(file, "done")
  k.tick(4.0) == "img:ok/0a2a0a"
end

check("status: a glob aggregates state files by priority") do
  File.write(File.join(tmp, "a.state"), "done")
  File.write(File.join(tmp, "b.state"), "busy")
  k = status_key({ "glob" => "#{tmp}/[ab].state", "priority" => %w[busy done] }, STATES)
  k.tick(0.0) == "img:···/3a2f00"
end

check("status: `track: true` follows the key's own process (busy -> done)") do
  k = status_key({}, STATES.reject { |name, _| name == "done" }
                          .merge("done" => { "text" => "ok", "background" => "0a2a0a" }),
                 track: true)
  k.started(spawn_command("exit 0"))
  busy = k.tick(0.0)
  done = nil
  40.times { (done = k.tick(0.0)) ? break : sleep(0.05) }
  busy == "img:···/3a2f00" && done == "img:ok/0a2a0a"
end

check("status: a state inherits the key's visual; its own selector wins") do
  base = { "icon" => "firefox", "background" => "111111", "command" => "x" }
  merge_state(base, { "text" => "···" }) == { "background" => "111111", "text" => "···" } &&
    merge_state(base, { "background" => "222222" }) ==
      { "icon" => "firefox", "background" => "222222" }
end

FileUtils.rm_rf(tmp)

if @failures.empty?
  puts "\nAll smoke checks passed."
  exit 0
else
  warn "\n#{@failures.size} check(s) failed."
  exit 1
end
