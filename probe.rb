#!/usr/bin/env ruby
# frozen_string_literal: true

# ─────────────────────────────────────────────────────────────────────────────
# probe.rb — explorer / debugger for Mirabox "Stream Dock" family decks.
#
# Helps you discover the settings deck.rb needs when adapting to ANOTHER device:
# transport params (report id / packet size), image resolution, rotation/mirror,
# the init/finish command sequences, and the key index mapping.
#
# Point it at any device with FIFINE_VID / FIFINE_PID (defaults 0x3142/0x0060).
# For a brand-new deck, start neutral:  FIFINE_ROT=0 FIFINE_FLIP_ROWS=0
#
# Run inside the dev shell (udev rule recommended so no sudo is needed):
#   nix-shell --run "ruby probe.rb doctor"
# ─────────────────────────────────────────────────────────────────────────────

require_relative "lib/fifine_deck"

D = FifineDeck

USAGE = <<~TXT
  probe.rb — explorer/debugger for Mirabox Stream Dock decks

  USAGE:
    ruby probe.rb info            list matching hidraw nodes + report params
    ruby probe.rb doctor          auto-detect what it can + checklist + env template
    ruby probe.rb blink           toggle brightness (does WRITE work at all?)
    ruby probe.rb probe           sweep init/finish sequences, painting a key red
    ruby probe.rb probe-res       sweep image resolutions
    ruby probe.rb orient [key]    paint an "F" to reveal rotation/mirror
    ruby probe.rb grid            paint each key a color (map DISPLAY indices)
    ruby probe.rb listen          print pressed indices (map PRESS indices)
    ruby probe.rb blank [name]    try a way to fully turn the deck "off" (no name = sweep all)
    ruby probe.rb wake            restore brightness (undo a blank)
    ruby probe.rb raw 43 52 ...   send one raw report (hex bytes)

  Override the target with FIFINE_VID / FIFINE_PID. New deck? start with
  FIFINE_ROT=0 FIFINE_FLIP_ROWS=0 and adjust as you learn.
TXT

# Full sequence init -> image (RAW device index, no flip) -> finish.
def send_raw(deck, key, jpeg, init:, finish:)
  init.each { |s| deck.run_step(s) }
  deck.clear_all
  deck.bat(key, jpeg.bytesize)
  deck.chunks(jpeg)
  finish.each { |s| deck.run_step(s) }
end

# Candidate init/finish sequences, informed by the reverse engineering.
SEQUENCES = [
  { init: %w[han],           finish: %w[ulend] },
  { init: %w[han],           finish: %w[ulend stp] },
  { init: %w[han],           finish: %w[stp] },
  { init: %w[dis lig80 han], finish: %w[ulend] },
  { init: %w[dis lig80 han], finish: %w[ulend stp] },
  { init: %w[dis han],       finish: %w[stp] },
  { init: %w[dis lig80],     finish: %w[stp] } # baseline mirajazz "293"
].freeze

def cmd_info
  cands = D::Device.matching
  if cands.empty?
    puts "No #{format('%<vid>04x:%<pid>04x', vid: D::VID, pid: D::PID)} hidraw found (plugged in? other app closed?)"
    return
  end
  cands.each do |c|
    puts "#{c[:node]}  vendor_page(0xFF00+)=#{c[:vendor_page]}  " \
         "output_report_id=#{c[:report_id_out].inspect}  output_bytes=#{c[:out_bytes].inspect}"
    puts "    #{c[:name]}"
  end
end

def cmd_doctor
  puts "── deck doctor ──"
  puts "Target VID:PID = #{format('%<vid>04x:%<pid>04x', vid: D::VID, pid: D::PID)} (override: FIFINE_VID/FIFINE_PID)"
  cands = D::Device.matching
  if cands.empty?
    puts "✗ No matching hidraw. Plug the device, close other apps, check udev/sudo."
    return
  end
  c   = cands.find { |x| x[:vendor_page] } || cands.last
  pk  = D::ENV_PACKET   || c[:out_bytes] || 512
  rid = D::ENV_REPORTID || c[:report_id_out] || 0
  doctor_detected(c, pk, rid)
  doctor_checklist
  doctor_env_template(pk, rid)
end

def doctor_detected(cand, packet, rid)
  puts "✓ node        : #{cand[:node]}  (#{cand[:name]})"
  puts "✓ report id   : #{rid}   (auto)"
  puts "✓ packet size : #{packet} bytes   (auto)"
  puts "✓ vendor page : #{cand[:vendor_page]}"
end

def doctor_checklist
  puts "\nVisual checks to run (watch the deck):"
  puts "  1) blink      — writing works at all? (backlight should pulse)"
  puts "  2) probe      — which init/finish sequence lights a key?"
  puts "  3) probe-res  — which JPEG resolution fills a key cleanly?"
  puts "  4) orient     — tune FIFINE_ROT/MIRROR until the 'F' is upright"
  puts "  5) grid + listen — map DISPLAY vs PRESS indices (set FIFINE_FLIP_ROWS / keymap)"
end

def doctor_env_template(packet, rid)
  puts "\nSuggested starting env (adjust as you learn):"
  puts "  export FIFINE_VID=#{format('0x%<v>04x', v: D::VID)} FIFINE_PID=#{format('0x%<v>04x', v: D::PID)}"
  puts "  export FIFINE_PACKET=#{packet} FIFINE_REPORTID=#{rid}"
  puts "  export FIFINE_RES=126 FIFINE_ROT=0 FIFINE_MIRROR=none FIFINE_FLIP_ROWS=0"
  puts "  export FIFINE_INIT=dis,lig0,han FIFINE_FINISH=ulend,stp"
  puts "  export FIFINE_ROWS=3 FIFINE_COLS=5 FIFINE_KEYS=15"
end

def cmd_blink
  D::Deck.open do |deck|
    %w[dis han].each { |s| deck.run_step(s) }
    6.times do |i|
      deck.lig(i.even? ? 0 : 100)
      puts "  brightness #{i.even? ? 0 : 100}% — did the backlight change?"
      sleep 0.8
    end
    deck.lig(80)
  end
end

def cmd_probe
  jpeg = D::Render.color("FF0000")
  SEQUENCES.each_with_index do |seq, n|
    D::Deck.open { |deck| send_raw(deck, 0, jpeg, init: seq[:init], finish: seq[:finish]) }
    print "  [#{n + 1}/#{SEQUENCES.size}] init=#{seq[:init].join('+')} " \
          "finish=#{seq[:finish].join('+')} — did a key turn red? [Enter=next, Ctrl-C=found it] "
    $stdin.gets
  end
  puts "If one worked, set FIFINE_INIT / FIFINE_FINISH to it."
end

def cmd_probe_res
  [64, 80, 96, 100, 105, 112, 126, 128].each do |res|
    jpeg = D::Render.color("FF0000", size: res)
    D::Deck.open { |deck| send_raw(deck, 0, jpeg, init: D::INIT_SEQ, finish: D::FIN_SEQ) }
    print "  res=#{res}px (init=#{D::INIT_SEQ.join('+')} finish=#{D::FIN_SEQ.join('+')}) " \
          "— filled the key cleanly? [Enter/Ctrl-C] "
    $stdin.gets
  end
  puts "Set FIFINE_RES to the size that looked right."
end

def cmd_orient(key = 0)
  jpeg = D::Render.text("F", background: "000000", color: "ffffff")
  D::Deck.open { |deck| send_raw(deck, key, jpeg, init: D::INIT_SEQ, finish: D::FIN_SEQ) }
  puts "Look at the 'F' (current ROT=#{D::ROT}, MIRROR=#{D::MIRROR}):"
  puts "  upside down -> FIFINE_ROT=180 | sideways -> 90/270 | mirrored -> FIFINE_MIRROR=x|y|both"
end

GRID_PALETTE = %w[FF0000 00FF00 0000FF FFFF00 FF00FF 00FFFF FF8000 8000FF
                  FFFFFF 808080 800000 008000 000080 808000 008080].freeze

def cmd_grid
  D::Deck.open do |deck|
    D::INIT_SEQ.each { |s| deck.run_step(s) }
    deck.clear_all
    # RAW device index (no flip) — reveals the device's display order.
    D::KEYS.times { |k| paint_raw(deck, k, GRID_PALETTE[k % GRID_PALETTE.size]) }
    D::FIN_SEQ.each { |s| deck.run_step(s) }
  end
  puts "Device index 0=red 1=green 2=blue 3=yellow ... — note where each lands physically."
  puts "If top/bottom rows are swapped vs a natural layout, FIFINE_FLIP_ROWS=1 fixes deck.rb."
end

def paint_raw(deck, key, hex)
  jpeg = D::Render.color(hex)
  deck.bat(key, jpeg.bytesize)
  deck.chunks(jpeg)
end

def cmd_listen
  D::Deck.open do |deck|
    puts "Press keys to see the physical index (Ctrl-C to stop)."
    loop do
      next unless deck.wait_readable(0.3)

      idx = deck.read_press
      puts "  press: physical index #{idx}" if idx
    end
  end
rescue Interrupt
  puts "\nbye."
end

def cmd_raw(hexbytes)
  bytes = hexbytes.map { |h| Integer(h, 16) }
  D::Deck.open { |deck| deck.write_report(bytes) }
end

# Ways to try to fully turn the deck "off" — `lig(0)` only dims on some units.
BLANK_STRATEGIES = [
  ["lig0",       "brightness 0"],
  ["clear",      "clear all keys"],
  ["clear-lig0", "clear all keys + brightness 0"],
  ["black",      "paint every key solid black + brightness 0"],
  ["dis",        "DIS (reset) command"],
  ["mod0",       "mode 0"],
  ["mod1",       "mode 1"]
].freeze

# Apply one blank strategy to an already-initialized deck.
def apply_blank(deck, name)
  case name
  when "lig0"        then deck.lig(0)
  when "clear"       then clear_commit(deck)
  when "clear-lig0"  then blank_clear_lig0(deck)
  when "black"       then blank_black(deck)
  when "dis"         then deck.dis
  when /\Amod(\d+)\z/ then deck.mod(Regexp.last_match(1).to_i)
  else abort "unknown blank strategy: #{name}"
  end
end

def clear_commit(deck)
  deck.clear_all
  deck.finish!
end

def blank_clear_lig0(deck)
  clear_commit(deck)
  deck.lig(0)
end

def blank_black(deck)
  deck.clear_all
  jpeg = D::Render.color("000000")
  D::KEYS.times do |k|
    deck.bat(k, jpeg.bytesize)
    deck.chunks(jpeg)
  end
  deck.finish!
  deck.lig(0)
end

def cmd_blank(name)
  D::Deck.open do |deck|
    if name && name != "all"
      deck.init!
      apply_blank(deck, name)
      puts "Applied '#{name}'. Not fully dark? try another, or `wake` to restore."
    else
      sweep_blank(deck)
    end
  end
rescue Interrupt
  puts "\n(stopped)"
end

def sweep_blank(deck)
  BLANK_STRATEGIES.each do |name, desc|
    deck.init!
    apply_blank(deck, name)
    print "  #{name.ljust(11)} (#{desc}) — fully dark now? [Enter=next, Ctrl-C=this one] "
    $stdin.gets
  end
  puts "Tell me which one went fully dark and I'll use it for lock/suspend."
end

def cmd_wake
  D::Deck.open do |deck|
    deck.init!
    deck.lig(80)
  end
  puts "Brightness restored to 80 (re-run your deck config to repaint keys)."
end

begin
  case ARGV[0]
  when "info"      then cmd_info
  when "doctor"    then cmd_doctor
  when "blink"     then cmd_blink
  when "probe"     then cmd_probe
  when "probe-res" then cmd_probe_res
  when "orient"    then cmd_orient(ARGV[1] ? Integer(ARGV[1]) : 0)
  when "grid"      then cmd_grid
  when "listen"    then cmd_listen
  when "blank"     then cmd_blank(ARGV[1])
  when "wake"      then cmd_wake
  when "raw"       then cmd_raw(ARGV[1..])
  else puts USAGE
  end
rescue Errno::EACCES, Errno::EPERM
  abort "No permission to open the device. Use the udev rule (or sudo)."
rescue RuntimeError => e
  abort "Error: #{e.message}"
end
