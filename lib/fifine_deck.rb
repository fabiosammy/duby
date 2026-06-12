# frozen_string_literal: true

# ─────────────────────────────────────────────────────────────────────────────
# lib/fifine_deck.rb — núcleo reutilizável do FIFINE Control Deck / D6 (0x0060)
#
# Extrai a parte "confirmada no hardware" do fifine_d6_deck.rb e adiciona a
# LEITURA de toques (input reports), descoberta na engenharia reversa do
# mirajazz (crate Rust que implementa o mesmo protocolo CRT/Mirabox):
#
#   * ESCRITA (confirmada): report HID = [report_id] + "CRT\0\0" + <CMD>,
#     padding com zeros até o tamanho do report. Imagem = JPEG 126x126, Rot180.
#       init  = DIS + LIG(0) + HAN(handshake)
#       img   = CLE(all) + BAT(<hi><lo><key+1>) + JPEG em chunks
#       fim   = ULEND + STP
#   * LEITURA (mirajazz): input report de 512B começa com "ACK" (0x41 0x43 0x4B);
#     byte 9 = índice da tecla (1-based; 0 = refresh de estado). O byte 10 é o
#     estado (down/up) só em protocolos > 2 — o 0x0060 é v2, então cada report
#     equivale a um toque completo. Índice 0-based da tecla = byte9 - 1.
#
# Usado por deck.rb (runner de YAML). O fifine_d6_deck.rb continua autônomo.
# ─────────────────────────────────────────────────────────────────────────────

require "open3"

module FifineDeck
  # Defaults (sobrescrevíveis por ENV, idênticos ao fifine_d6_deck.rb)
  VID    = Integer(ENV.fetch("FIFINE_VID", "0x3142"))
  PID    = Integer(ENV.fetch("FIFINE_PID", "0x0060"))
  RES    = Integer(ENV.fetch("FIFINE_RES", "126"))   # combo confirmado no 0x0060
  ROWS   = Integer(ENV.fetch("FIFINE_ROWS", "3"))
  COLS   = Integer(ENV.fetch("FIFINE_COLS", "5"))
  KEYS   = Integer(ENV.fetch("FIFINE_KEYS", (ROWS * COLS).to_s)) # 3x5 = 15
  ROT    = Integer(ENV.fetch("FIFINE_ROT", "180"))   # 0x0060 exibe girado 180°
  MIRROR = ENV.fetch("FIFINE_MIRROR", "none")        # none/x/y/both
  # CONFIRMADO no hardware (2026-06-12): a EXIBIÇÃO (BAT) numera de baixo p/ cima
  # (linha invertida), mas os TOQUES chegam em ordem natural (topo-esquerda = 0).
  # Por isso o índice do config é "natural" e fazemos um flip de linha só na
  # exibição. Desligue com FIFINE_FLIP_ROWS=0 se um dia o firmware mudar.
  FLIP_ROWS = ENV.fetch("FIFINE_FLIP_ROWS", "1") != "0"

  ENV_PACKET   = ENV["FIFINE_PACKET"]&.to_i
  ENV_REPORTID = ENV["FIFINE_REPORTID"]&.to_i
  FORCED       = ENV["FIFINE_HIDRAW"]
  INIT_SEQ = (ENV["FIFINE_INIT"]   || "dis,lig0,han").split(",").map(&:strip).reject(&:empty?)
  FIN_SEQ  = (ENV["FIFINE_FINISH"] || "ulend,stp").split(",").map(&:strip).reject(&:empty?)

  # ── Descoberta do device (hidraw via sysfs) ─────────────────────────────────
  module Device
    module_function

    # Parser mínimo de HID report descriptor -> {report_id_out:, out_bytes:, vendor_page:}
    def parse_descriptor(desc)
      bytes = desc.bytes
      i = 0
      rsize = rcount = rid = 0
      out_rid = out_bytes = nil
      vendor_page = false
      while i < bytes.length
        b = bytes[i]; i += 1
        bsize = b & 0x3
        bsize = 4 if bsize == 3
        tag = b & 0xFC
        dat = bytes[i, bsize] || []
        val = dat.each_with_index.reduce(0) { |a, (x, k)| a | (x << (8 * k)) }
        i += bsize
        case tag
        when 0x04 then vendor_page = true if val >= 0xFF00 # Usage Page vendor
        when 0x74 then rsize  = val                        # Report Size
        when 0x94 then rcount = val                        # Report Count
        when 0x84 then rid    = val                        # Report ID
        when 0x90, 0x91                                    # Output (main item)
          out_rid = rid
          out_bytes = rcount * rsize / 8
        end
      end
      { report_id_out: out_rid, out_bytes: out_bytes, vendor_page: vendor_page }
    end

    def matching(vid = VID, pid = PID)
      Dir.glob("/sys/class/hidraw/hidraw*").filter_map do |sys|
        uevent = File.read(File.join(sys, "device/uevent")) rescue next
        next unless uevent =~ /HID_ID=\h+:0*(\h+):0*(\h+)/
        next unless $1.to_i(16) == vid && $2.to_i(16) == pid
        desc = File.binread(File.join(sys, "device/report_descriptor")) rescue "".b
        parse_descriptor(desc).merge(node: "/dev/#{File.basename(sys)}",
                                     name: uevent[/HID_NAME=(.+)/, 1])
      end
    end

    def pick(vid = VID, pid = PID)
      if FORCED && File.exist?(FORCED)
        return { node: FORCED, report_id_out: nil, out_bytes: nil, vendor_page: nil }
      end
      cands = matching(vid, pid)
      if cands.empty?
        raise "Nenhum hidraw para #{format('%04x:%04x', vid, pid)} " \
              "(device plugado? OpenDeck fechado?)"
      end
      cands.find { |c| c[:vendor_page] } || cands.last
    end
  end

  # ── Transporte + protocolo (escrita e leitura) ──────────────────────────────
  class Deck
    CRT      = [0x43, 0x52, 0x54, 0x00, 0x00].freeze
    READ_LEN = 1088 # >= qualquer tamanho de report; o kernel devolve 1 report/leitura

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

    # comandos nomeados
    def dis     = cmd(0x44, 0x49, 0x53)                               # DIS
    def lig(p)  = cmd(0x4C, 0x49, 0x47, 0x00, 0x00, p.clamp(0, 100))  # LIG <pct>
    def mod(m)  = cmd(0x4D, 0x4F, 0x44, 0x00, 0x00, 0x30 + m)         # MOD
    def stp     = cmd(0x53, 0x54, 0x50)                               # STP
    def ulend   = cmd(0x55, 0x4C, 0x45, 0x4E, 0x44)                   # ULEND
    def connect = cmd(0x43, 0x4F, 0x4E, 0x4E, 0x45, 0x43, 0x54)       # CONNECT
    def han     = write_report([0x48, 0x41, 0x4E])                    # <id>HAN (sem CRT)
    def cle(key) = cmd(0x43, 0x4C, 0x45, 0x00, 0x00, 0x00, key == 0xFF ? 0xFF : key + 1)
    def clear_all = cle(0xFF)

    def bat(key, len) # cabeçalho de imagem
      cmd(0x42, 0x41, 0x54, 0x00, 0x00, (len >> 8) & 0xFF, len & 0xFF, key + 1)
    end

    # Índice "natural" (0 = topo-esquerda, row-major) -> índice de EXIBIÇÃO do
    # device. No 0x0060 a exibição é de baixo p/ cima; os toques (read_press) já
    # chegam naturais, então o flip fica só aqui.
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

    def run_step(s)
      case s
      when "dis"          then dis
      when /^lig(\d+)?$/  then lig(($1 || "80").to_i)
      when "han"          then han
      when "connect"      then connect
      when /^mod(\d+)?$/  then mod(($1 || "0").to_i)
      when "stp"          then stp
      when "ulend"        then ulend
      when "cle"          then clear_all
      end
      sleep 0.01
    end

    def init!(seq = INIT_SEQ)   = seq.each { |s| run_step(s) }
    def finish!(seq = FIN_SEQ)  = seq.each { |s| run_step(s) }

    # Envia UMA imagem (init -> imagem -> finish) — atalho avulso.
    def send_image(key, jpeg, init: INIT_SEQ, finish: FIN_SEQ)
      init!(init)
      clear_all
      bat(display_index(key), jpeg.bytesize)
      chunks(jpeg)
      finish!(finish)
    end

    # Envia VÁRIAS imagens de uma vez (init/clear uma única vez). `jpegs` é um
    # Hash { key0based => jpeg_bytes }. `brightness` (0-100) é opcional.
    def apply_images(jpegs, brightness: nil)
      init!
      lig(brightness) if brightness
      clear_all
      jpegs.each { |k, jpeg| bat(display_index(k), jpeg.bytesize); chunks(jpeg) }
      finish!
    end

    # ── Leitura de toques ──────────────────────────────────────────────────
    # Espera até `timeout` segundos por dados para ler. Retorna true se há algo
    # a ler, false no timeout. Permite que o loop verifique flags (ex.: parar).
    def wait_readable(timeout)
      !IO.select([@io], nil, nil, timeout).nil?
    end

    # Lê 1 input report (bloqueante). Retorna o índice 0-based da tecla
    # pressionada, ou nil se o report não for de tecla (refresh/desconhecido).
    def read_press
      data = @io.readpartial(READ_LEN)
      return nil unless data && data.bytesize >= 11
      return nil unless data.byteslice(0, 3) == "ACK" # 0x41 0x43 0x4B
      idx1 = data.getbyte(9) # 1-based; 0 = refresh
      return nil if idx1.nil? || idx1.zero?
      idx1 - 1
    end
  end

  # ── Render: cor sólida, texto-com-fundo, imagem pronta -> JPEG ──────────────
  module Render
    module_function

    # Binário do ImageMagick: prefere `magick` (IMv7), cai para `convert` (IMv6).
    # Sobrescreva com FIFINE_MAGICK.
    def bin
      return @bin if defined?(@bin)
      @bin = (ENV["FIFINE_MAGICK"] unless ENV["FIFINE_MAGICK"].to_s.empty?) ||
             %w[magick convert].find { |b| system(b, "-version", out: File::NULL, err: File::NULL) } ||
             "convert"
    end

    # Caminho de um arquivo de fonte .ttf/.otf utilizável. O ImageMagick precisa
    # de UM arquivo de fonte; em `nix-shell -p imagemagick` sem pacote de fontes
    # ele falha com `font (null)`. Ordem: FIFINE_FONT -> fc-list -> dirs comuns.
    def font_path
      return @font_path if defined?(@font_path)
      @font_path = (ENV["FIFINE_FONT"] unless ENV["FIFINE_FONT"].to_s.empty?) ||
                   pick_font(fc_list) || pick_font(scan_font_dirs)
    end

    def fc_list
      out, st = Open3.capture2("fc-list", "-f", "%{file}\n")
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

    # Prefere uma sans regular conhecida; senão a de nome mais curto (família base).
    def pick_font(list)
      files = list.select { |f| f =~ /\.(ttf|otf)$/i }
      return nil if files.empty?
      files.find { |f| f =~ /DejaVuSans\.ttf$/i } ||
        files.find { |f| f =~ /(LiberationSans-Regular|NotoSans-Regular|FreeSans)\.(ttf|otf)$/i } ||
        files.find { |f| f =~ %r{/[^/]*sans[^/]*regular[^/]*\.(ttf|otf)$}i } ||
        files.min_by(&:length)
    end

    def font_help
      "Nenhuma fonte encontrada para renderizar texto.\n" \
      "  • No Nix, use o shell.nix do projeto:  nix-shell --run \"ruby deck.rb apply deck.yml\"\n" \
      "    ou adicione um pacote de fontes:     nix-shell -p ruby imagemagick dejavu_fonts --run \"...\"\n" \
      "  • Ou aponte uma fonte:  FIFINE_FONT=/caminho/Fonte.ttf  (veja: fc-list | grep -i dejavu)"
    end

    # flags do ImageMagick para rotação/espelho (cor sólida ignora; texto/imagem usam)
    def orient_args
      a = []
      a += ["-rotate", ROT.to_s] unless ROT.zero?
      a << "-flop" if %w[x both].include?(MIRROR)
      a << "-flip" if %w[y both].include?(MIRROR)
      a
    end

    def convert(*args)
      out, st = Open3.capture2(bin, *args, "-quality", "90", "-strip", "jpg:-", binmode: true)
      raise "falha no ImageMagick (#{bin}) — args: #{args.inspect}" unless st.success? && !out.empty?
      out
    end

    def color(hex, size: RES)
      convert("-size", "#{size}x#{size}", "xc:##{hex.delete('#')}")
    end

    # Texto centralizado com auto-ajuste de fonte (caption) sobre um fundo sólido.
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

    # Imagem pronta redimensionada para preencher a tecla.
    def image(path, size: RES)
      raise "imagem não encontrada: #{path}" unless File.exist?(path)
      convert(path, "-resize", "#{size}x#{size}!", *orient_args)
    end

    # Diretórios de ícones (freedesktop + NixOS), na ordem de preferência.
    def icon_dirs
      dirs = [File.expand_path("~/.local/share/icons"),
              File.expand_path("~/.icons"),
              File.expand_path("~/.nix-profile/share/icons"),
              "/run/current-system/sw/share/icons"]
      (ENV["XDG_DATA_DIRS"] || "").split(":").each { |d| dirs << File.join(d, "icons") }
      dirs += ["/usr/share/icons", "/usr/share/pixmaps", "/run/current-system/sw/share/pixmaps"]
      dirs.uniq.select { |d| File.directory?(d) }
    end

    # Resolve um nome de ícone (tema freedesktop) para um arquivo. Aceita também
    # um caminho direto. Prefere PNG colorido grande de hicolor/breeze; evita
    # HighContrast/symbolic (monocromáticos). SVG só se não houver PNG.
    def find_icon(name)
      return name if File.exist?(name)
      cands = icon_dirs.flat_map { |d| Dir.glob(File.join(d, "**", "#{name}.{png,svg,PNG,SVG}")) }
      pngs = cands.select { |p| p =~ /\.png$/i }
      pool = pngs.empty? ? cands : pngs
      return nil if pool.empty?
      pool.max_by { |p| icon_score(p) }
    end

    def icon_score(path)
      s = path[/(\d+)x\d+/, 1].to_i           # tamanho em px (0 = scalable/sem tamanho)
      s = 384 if s.zero?
      s += 4000 if path =~ %r{/hicolor/}i
      s += 2000 if path =~ /(Papirus|breeze|Adwaita)/i
      s -= 100_000 if path =~ /(HighContrast|symbolic|mono)/i
      s
    end

    # Ícone (do tema ou caminho) centralizado sobre um fundo sólido. `name` pode
    # ser uma String ou uma lista de candidatos (tenta cada um até achar).
    def icon(name, background: "000000", size: RES)
      names = Array(name).map(&:to_s)
      path = names.filter_map { |n| find_icon(n) }.first
      unless path
        raise "ícone #{names.inspect} não encontrado nos temas. Use um caminho de " \
              "arquivo, ou veja: find #{icon_dirs.first} -iname '<nome>.*'"
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
