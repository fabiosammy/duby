# frozen_string_literal: true

# ─────────────────────────────────────────────────────────────────────────────
# lib/fifine_deck.rb — reusable core for the FIFINE Control Deck / D6 (0x0060)
#
# Extracts the "hardware-confirmed" part of fifine_d6_deck.rb and adds key-press
# READING (input reports), discovered by reverse-engineering mirajazz (the Rust
# crate that implements the same CRT/Mirabox protocol):
#
#   * WRITE (confirmed): HID report = [report_id] + "CRT\0\0" + <CMD>, padded
#     with zeros to the report size. Image = JPEG 126x126, Rot180.
#       init  = DIS + LIG(0) + HAN(handshake)
#       img   = CLE(all) + BAT(<hi><lo><key+1>) + JPEG in chunks
#       end   = ULEND + STP
#   * READ (mirajazz): a 512B input report starts with "ACK" (0x41 0x43 0x4B);
#     byte 9 = key index (1-based; 0 = state refresh). Byte 10 is the down/up
#     state only on protocols > 2 — the 0x0060 is v2, so each report is one full
#     press. 0-based key index = byte9 - 1.
#
# Used by deck.rb (the YAML runner). fifine_d6_deck.rb remains standalone.
# ─────────────────────────────────────────────────────────────────────────────

require "open3"

module FifineDeck
  # Defaults (overridable via ENV, identical to fifine_d6_deck.rb)
  VID    = Integer(ENV.fetch("FIFINE_VID", "0x3142"))
  PID    = Integer(ENV.fetch("FIFINE_PID", "0x0060"))
  RES    = Integer(ENV.fetch("FIFINE_RES", "126")) # confirmed combo on the 0x0060
  ROWS   = Integer(ENV.fetch("FIFINE_ROWS", "3"))
  COLS   = Integer(ENV.fetch("FIFINE_COLS", "5"))
  KEYS   = Integer(ENV.fetch("FIFINE_KEYS", (ROWS * COLS).to_s)) # 3x5 = 15
  ROT    = Integer(ENV.fetch("FIFINE_ROT", "180"))   # the 0x0060 displays rotated 180°
  MIRROR = ENV.fetch("FIFINE_MIRROR", "none")        # none/x/y/both
  # CONFIRMED on hardware (2026-06-12): the DISPLAY (BAT) is numbered bottom-up
  # (rows flipped), but PRESSES arrive in natural order (top-left = 0). So the
  # config index is "natural" and we row-flip only the display side. Turn it off
  # with FIFINE_FLIP_ROWS=0 if a future firmware changes this.
  FLIP_ROWS = ENV.fetch("FIFINE_FLIP_ROWS", "1") != "0"

  ENV_PACKET   = ENV["FIFINE_PACKET"]&.to_i
  ENV_REPORTID = ENV["FIFINE_REPORTID"]&.to_i
  FORCED       = ENV["FIFINE_HIDRAW"]
  INIT_SEQ = (ENV["FIFINE_INIT"]   || "dis,lig0,han").split(",").map(&:strip).reject(&:empty?)
  FIN_SEQ  = (ENV["FIFINE_FINISH"] || "ulend,stp").split(",").map(&:strip).reject(&:empty?)

  # ── Device discovery (hidraw via sysfs) ─────────────────────────────────────
  module Device
    module_function

    # Minimal HID report descriptor parser -> {report_id_out:, out_bytes:, vendor_page:}
    def parse_descriptor(desc)
      st = { rsize: 0, rcount: 0, rid: 0, out_rid: nil, out_bytes: nil, vendor: false }
      bytes = desc.bytes
      i = 0
      while i < bytes.length
        b = bytes[i]; i += 1
        bsize = (b & 0x3) == 3 ? 4 : (b & 0x3)
        val = (bytes[i, bsize] || []).each_with_index.reduce(0) { |a, (x, k)| a | (x << (8 * k)) }
        apply_descriptor_item(st, b & 0xFC, val)
        i += bsize
      end
      { report_id_out: st[:out_rid], out_bytes: st[:out_bytes], vendor_page: st[:vendor] }
    end

    # Folds one HID item (tag + value) into the parser state `st`.
    def apply_descriptor_item(st, tag, val)
      case tag
      when 0x04 then st[:vendor] = true if val >= 0xFF00 # vendor Usage Page
      when 0x74 then st[:rsize]  = val                   # Report Size
      when 0x94 then st[:rcount] = val                   # Report Count
      when 0x84 then st[:rid]    = val                   # Report ID
      when 0x90, 0x91 # Output (main item)
        st[:out_rid]   = st[:rid]
        st[:out_bytes] = st[:rcount] * st[:rsize] / 8
      end
    end

    def matching(vid = VID, pid = PID)
      Dir.glob("/sys/class/hidraw/hidraw*").filter_map do |sys|
        uevent = File.read(File.join(sys, "device/uevent")) rescue next
        next unless uevent =~ /HID_ID=\h+:0*(\h+):0*(\h+)/
        next unless ::Regexp.last_match(1).to_i(16) == vid && ::Regexp.last_match(2).to_i(16) == pid

        desc = File.binread(File.join(sys, "device/report_descriptor")) rescue "".b
        parse_descriptor(desc).merge(node: "/dev/#{File.basename(sys)}",
                                     name: uevent[/HID_NAME=(.+)/, 1])
      end
    end

    def pick(vid = VID, pid = PID)
      return { node: FORCED, report_id_out: nil, out_bytes: nil, vendor_page: nil } if FORCED && File.exist?(FORCED)

      cands = matching(vid, pid)
      if cands.empty?
        raise "No hidraw for #{format('%<vid>04x:%<pid>04x', vid: vid, pid: pid)} " \
              "(device plugged in? other app closed?)"
      end
      cands.find { |c| c[:vendor_page] } || cands.last
    end
  end

  # ── Transport + protocol (write and read) ───────────────────────────────────
  class Deck
    CRT      = [0x43, 0x52, 0x54, 0x00, 0x00].freeze
    READ_LEN = 1088 # >= any report size; the kernel returns 1 report per read

    def self.open(packet: nil, report_id: nil, mode: "r+b")
      d   = Device.pick
      pk  = packet    || ENV_PACKET   || d[:out_bytes] || 512
      rid = report_id || ENV_REPORTID || d[:report_id_out] || 0
      warn "→ #{d[:node]}  packet=#{pk}  report_id=#{rid}  res=#{RES}"
      deck = new(d[:node], packet: pk, report_id: rid, mode: mode)
      return deck unless block_given?

      begin
        yield deck
      ensure
        deck.close
      end
    end

    def initialize(node, packet:, report_id: 0, mode: "r+b")
      @io     = File.open(node, mode)
      @packet = packet
      @rid    = report_id
    end

    def close = @io.close

    def write_report(bytes)
      buf = [@rid] + bytes
      buf.fill(0x00, buf.length...(1 + @packet)) if buf.length < 1 + @packet
      @io.write(buf.pack("C*")); @io.flush
    end

    def cmd(*tail) = write_report(CRT + tail)

    # named commands
    def dis     = cmd(0x44, 0x49, 0x53)                               # DIS
    def lig(p)  = cmd(0x4C, 0x49, 0x47, 0x00, 0x00, p.clamp(0, 100))  # LIG <pct>
    def mod(m)  = cmd(0x4D, 0x4F, 0x44, 0x00, 0x00, 0x30 + m)         # MOD
    def stp     = cmd(0x53, 0x54, 0x50)                               # STP
    def ulend   = cmd(0x55, 0x4C, 0x45, 0x4E, 0x44)                   # ULEND
    def connect = cmd(0x43, 0x4F, 0x4E, 0x4E, 0x45, 0x43, 0x54)       # CONNECT
    def han     = write_report([0x48, 0x41, 0x4E])                    # <id>HAN (no CRT)
    def cle(key) = cmd(0x43, 0x4C, 0x45, 0x00, 0x00, 0x00, key == 0xFF ? 0xFF : key + 1)
    def clear_all = cle(0xFF)

    def bat(key, len) # image header
      cmd(0x42, 0x41, 0x54, 0x00, 0x00, (len >> 8) & 0xFF, len & 0xFF, key + 1)
    end

    # "Natural" index (0 = top-left, row-major) -> device DISPLAY index. On the
    # 0x0060 the display is numbered bottom-up; presses (read_press) already
    # arrive natural, so the flip lives only here.
    def display_index(key)
      return key unless FLIP_ROWS

      row, col = key.divmod(COLS)
      (ROWS - 1 - row) * COLS + col
    end

    def chunks(data)
      off = 0
      while off < data.bytesize
        write_report(data.byteslice(off, @packet).bytes)
        off += @packet
      end
    end

    # init/finish step name -> method (the parameterised lig/mod are handled below)
    SIMPLE_STEPS = { "dis" => :dis, "han" => :han, "connect" => :connect,
                     "stp" => :stp, "ulend" => :ulend, "cle" => :clear_all }.freeze

    def run_step(s)
      if (m = SIMPLE_STEPS[s])  then send(m)
      elsif s =~ /^lig(\d+)?$/  then lig((::Regexp.last_match(1) || "80").to_i)
      elsif s =~ /^mod(\d+)?$/  then mod((::Regexp.last_match(1) || "0").to_i)
      end
      sleep 0.01
    end

    def init!(seq = INIT_SEQ)   = seq.each { |s| run_step(s) }
    def finish!(seq = FIN_SEQ)  = seq.each { |s| run_step(s) }

    # Send ONE image (init -> image -> finish) — standalone shortcut.
    def send_image(key, jpeg, init: INIT_SEQ, finish: FIN_SEQ)
      init!(init)
      clear_all
      bat(display_index(key), jpeg.bytesize)
      chunks(jpeg)
      finish!(finish)
    end

    # Send SEVERAL images at once (init/clear only once). `jpegs` is a
    # Hash { key0based => jpeg_bytes }. `brightness` (0-100) is optional.
    def apply_images(jpegs, brightness: nil)
      init!
      lig(brightness) if brightness
      paint(jpegs)
    end

    # Repaint keys WITHOUT re-running init (smooth layer switches). Keys absent
    # from `jpegs` are cleared, so undefined keys go blank on the new layer.
    def paint(jpegs)
      clear_all
      jpegs.each { |k, jpeg| bat(display_index(k), jpeg.bytesize); chunks(jpeg) }
      finish!
    end

    # ── Key-press reading ────────────────────────────────────────────────────
    # Waits up to `timeout` seconds for data to read. Returns true if there is
    # something to read, false on timeout. Lets the loop check flags (e.g. stop).
    def wait_readable(timeout)
      !IO.select([@io], nil, nil, timeout).nil?
    end

    # Reads 1 input report (blocking). Returns the 0-based index of the pressed
    # key, or nil if the report is not a key event (refresh/unknown).
    def read_press
      data = @io.readpartial(READ_LEN)
      return nil unless data && data.bytesize >= 11
      return nil unless data.byteslice(0, 3) == "ACK" # 0x41 0x43 0x4B

      idx1 = data.getbyte(9) # 1-based; 0 = refresh
      return nil if idx1.nil? || idx1.zero?

      idx1 - 1
    end
  end

  # ── Render: solid color, text-on-background, ready image -> JPEG ─────────────
  module Render
    module_function

    # ImageMagick binary: prefers `magick` (IMv7), falls back to `convert` (IMv6).
    # Override with FIFINE_MAGICK.
    def bin
      return @bin if defined?(@bin)

      @bin = (ENV["FIFINE_MAGICK"] unless ENV["FIFINE_MAGICK"].to_s.empty?) ||
             %w[magick convert].find { |b| system(b, "-version", out: File::NULL, err: File::NULL) } ||
             "convert"
    end

    # Path to a usable .ttf/.otf font file. ImageMagick needs ONE font file; on
    # `nix-shell -p imagemagick` without a font package it fails with
    # `font (null)`. Order: FIFINE_FONT -> fc-list -> common dirs.
    def font_path
      return @font_path if defined?(@font_path)

      @font_path = (ENV["FIFINE_FONT"] unless ENV["FIFINE_FONT"].to_s.empty?) ||
                   pick_font(fc_list) || pick_font(scan_font_dirs)
    end

    def fc_list
      out, st = Open3.capture2("fc-list", "-f", "%{file}\n") # rubocop:disable Style/FormatStringToken
      st.success? ? out.lines.map(&:strip) : []
    rescue Errno::ENOENT
      []
    end

    def scan_font_dirs
      %W[/usr/share/fonts /run/current-system/sw/share/X11/fonts
         #{File.expand_path('~/.nix-profile/share/fonts')}
         /nix/var/nix/profiles/default/share/fonts].flat_map do |d|
        Dir.glob(File.join(d, "**", "*.{ttf,otf,TTF,OTF}"))
      end
    end

    # Preferred font filename patterns, best first (regular sans families).
    FONT_PREFS = [
      /DejaVuSans\.ttf$/i,
      /(LiberationSans-Regular|NotoSans-Regular|FreeSans)\.(ttf|otf)$/i,
      %r{/[^/]*sans[^/]*regular[^/]*\.(ttf|otf)$}i
    ].freeze

    # Prefers a known regular sans; otherwise the shortest name (the base family).
    def pick_font(list)
      files = list.select { |f| f =~ /\.(ttf|otf)$/i }
      return nil if files.empty?

      FONT_PREFS.each { |re| (hit = files.find { |f| f =~ re }) and return hit }
      files.min_by(&:length)
    end

    def font_help
      "No font found to render text.\n" \
      "  • On Nix, use the project's shell.nix:  nix-shell --run \"ruby deck.rb apply deck.yml\"\n" \
      "    or add a font package:                nix-shell -p ruby imagemagick dejavu_fonts --run \"...\"\n" \
      "  • Or point to a font:  FIFINE_FONT=/path/to/Font.ttf  (see: fc-list | grep -i dejavu)"
    end

    # ImageMagick flags for rotation/mirror (solid color ignores them; text/image use them)
    def orient_args
      a = []
      a += ["-rotate", ROT.to_s] unless ROT.zero?
      a << "-flop" if %w[x both].include?(MIRROR)
      a << "-flip" if %w[y both].include?(MIRROR)
      a
    end

    def convert(*args)
      out, st = Open3.capture2(bin, *args, "-quality", "90", "-strip", "jpg:-", binmode: true)
      raise "ImageMagick (#{bin}) failed — args: #{args.inspect}" unless st.success? && !out.empty?

      out
    end

    def color(hex, size: RES)
      convert("-size", "#{size}x#{size}", "xc:##{hex.delete('#')}")
    end

    # Centered text with auto-sized font (caption) over a solid background.
    def text(str, background: "000000", color: "ffffff", font: nil, size: RES)
      f = font || font_path
      raise font_help unless f

      inner = [size - 14, 16].max
      convert("-size", "#{inner}x#{inner}",
              "-background", "##{background.delete('#')}",
              "-fill", "##{color.delete('#')}",
              "-gravity", "center", "-font", f,
              "caption:#{str}",
              "-background", "##{background.delete('#')}", "-extent", "#{size}x#{size}",
              *orient_args)
    end

    # Ready image resized to fill the key.
    def image(path, size: RES)
      raise "image not found: #{path}" unless File.exist?(path)

      convert(path, "-resize", "#{size}x#{size}!", *orient_args)
    end

    # Icon directories (freedesktop + NixOS), in preference order.
    def icon_dirs
      dirs = [File.expand_path("~/.local/share/icons"),
              File.expand_path("~/.icons"),
              File.expand_path("~/.nix-profile/share/icons"),
              "/run/current-system/sw/share/icons"]
      (ENV["XDG_DATA_DIRS"] || "").split(":").each { |d| dirs << File.join(d, "icons") }
      dirs += ["/usr/share/icons", "/usr/share/pixmaps", "/run/current-system/sw/share/pixmaps"]
      dirs.uniq.select { |d| File.directory?(d) }
    end

    # Resolves an icon name (freedesktop theme) to a file. Also accepts a direct
    # path. Prefers a large colored PNG from hicolor/breeze; avoids
    # HighContrast/symbolic (monochrome). SVG only if there is no PNG.
    def find_icon(name)
      return name if File.exist?(name)

      cands = icon_dirs.flat_map { |d| Dir.glob(File.join(d, "**", "#{name}.{png,svg,PNG,SVG}")) }
      pngs = cands.select { |p| p =~ /\.png$/i }
      pool = pngs.empty? ? cands : pngs
      return nil if pool.empty?

      pool.max_by { |p| icon_score(p) }
    end

    def icon_score(path)
      s = path[/(\d+)x\d+/, 1].to_i # size in px (0 = scalable/no size)
      s = 384 if s.zero?
      s += 4000 if path =~ %r{/hicolor/}i
      s += 2000 if path =~ /(Papirus|breeze|Adwaita)/i
      s -= 100_000 if path =~ /(HighContrast|symbolic|mono)/i
      s
    end

    # Icon (from theme or path) centered over a solid background. `name` can be a
    # String or a list of candidates (tries each until one is found).
    def icon(name, background: "000000", size: RES)
      names = Array(name).map(&:to_s)
      path = names.filter_map { |n| find_icon(n) }.first
      unless path
        raise "icon #{names.inspect} not found in the themes. Use a file path, " \
              "or see: find #{icon_dirs.first} -iname '<name>.*'"
      end
      pad = (size * 0.12).round
      inner = size - 2 * pad
      convert("-size", "#{size}x#{size}", "xc:##{background.delete('#')}",
              "(", "-background", "none", "-density", "256", path,
              "-resize", "#{inner}x#{inner}", ")",
              "-gravity", "center", "-composite", *orient_args)
    end
  end
end
