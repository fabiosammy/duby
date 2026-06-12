#!/usr/bin/env ruby
# frozen_string_literal: true

# Hardware-free smoke test: exercises the render pipeline and YAML loading
# (no /dev/hidraw needed). Run with:  ruby test/smoke.rb
# Requires ImageMagick and a font available to it (see shell.nix).

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

# End-to-end: load and render the example configs.
%w[deck.example.yml deck.layers.example.yml].each do |name|
  path = File.join(ROOT, name)
  check("#{name}: loads and renders every key to a JPEG") do
    cfg = load_config(path)
    jpegs = render_layers(cfg).flat_map(&:values)
    !jpegs.empty? && jpegs.all? { |j| jpeg?(j) }
  end
end

# focus_layers / layer resolution logic.
check("layer_for_class maps via substring + '*' default") do
  fm = { "code" => "dev", "*" => "home" }.to_a
  layer_for_class("VSCode-ish Code", fm) == "dev" && layer_for_class("plasmashell", fm) == "home"
end

if @failures.empty?
  puts "\nAll smoke checks passed."
  exit 0
else
  warn "\n#{@failures.size} check(s) failed."
  exit 1
end
