#!/usr/bin/env ruby
# frozen_string_literal: true

# ─────────────────────────────────────────────────────────────────────────────
# deck.rb — controla o FIFINE Control Deck / D6 (0x0060) a partir de um YAML.
#
# Ideia "simples": no YAML você descreve cada tecla com um TEXTO+fundo, uma
# IMAGEM pronta ou só uma COR, e um COMANDO de shell para rodar quando ela for
# pressionada. O `deck.rb` pinta as teclas e (opcionalmente) fica escutando os
# toques e disparando os comandos.
#
# USO:
#   sudo ruby deck.rb apply  [config.yml]   # pinta todas as teclas e ajusta brilho
#   sudo ruby deck.rb run    [config.yml]   # pinta + escuta toques + roda comandos (Ctrl-C p/ sair)
#   sudo ruby deck.rb listen [config.yml]   # DEBUG: só imprime o índice da tecla tocada
#   sudo ruby deck.rb clear                 # apaga todas as teclas
#
# config.yml default = ./deck.yml (veja deck.example.yml).
#
# Mesmas ENV do fifine_d6_deck.rb (FIFINE_PID, FIFINE_RES, FIFINE_ROT, ...).
# IMPORTANTE: feche o OpenDeck antes (brigam pelo device). Use sudo ou a regra
# udev (41-fifine-d6-0060.rules).
#
# ── TODO (coisas que stream decks costumam fazer e que ficam para depois) ─────
#   [ ] Páginas / perfis (várias telas de 15 teclas, tecla para alternar).
#   [ ] Estado liga/desliga por tecla (toggle) com 2 imagens (ex.: mute on/off).
#   [ ] Recarregar o YAML ao vivo quando o arquivo mudar (file watch).
#   [ ] Daemon/serviço systemd (--user) para subir junto com a sessão.
#   [ ] Texto sobre imagem (overlay), ícones + legenda, alinhamento/fonte/tamanho.
#   [ ] Long-press / double-press / sequências de teclas.
#   [ ] Encoders/diais (o 0x0060 não tem, mas a família Mirabox tem).
#   [ ] Mapa de exibição configurável (hoje exibição assume índice == config).
#   [ ] Feedback visual ao pressionar (piscar/realçar a tecla).
# ─────────────────────────────────────────────────────────────────────────────

require "yaml"
require_relative "lib/fifine_deck"

$stdout.sync = true # log em arquivo atualiza ao vivo (sem buffer)

DEBOUNCE = 0.20 # s — ignora repetições do mesmo toque dentro desse intervalo

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def log(msg) = puts("[#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}")

# Notificação no KDE (systray). Silencioso se notify-send não existir.
def notify(summary, body = "")
  Process.detach(Process.spawn("notify-send", "-a", "FIFINE Deck",
                               "-i", "input-keyboard", summary, body,
                               out: File::NULL, err: File::NULL))
rescue StandardError
  # sem notify-send: ignora
end

# Pinta uma tela cheia (todas as teclas com `background`, mensagem no centro).
# Usado para boas-vindas e para o estado "parado" ao encerrar.
def show_splash(deck, text:, background:, color: "ffffff", brightness: nil, res:, hold: nil)
  bg  = FifineDeck::Render.color(background, size: res)
  msg = FifineDeck::Render.text(text, background: background, color: color, size: res)
  jpegs = {}
  FifineDeck::KEYS.times { |k| jpegs[k] = bg }
  jpegs[FifineDeck::KEYS / 2] = msg # tecla central (7 num 3x5)
  deck.apply_images(jpegs, brightness: brightness)
  sleep hold if hold
end

def load_config(path)
  unless File.exist?(path)
    abort "Config não encontrada: #{path}\n(crie um deck.yml — veja deck.example.yml)"
  end
  raw = YAML.safe_load_file(path) || {}
  settings = raw["settings"] || {}
  base_dir = File.dirname(File.expand_path(path))

  # normaliza chaves de teclas para Integer (YAML pode trazer "0" ou 0)
  keys = {}
  (raw["keys"] || {}).each do |k, spec|
    next if spec.nil?
    keys[Integer(k)] = spec
  end

  # keymap opcional: índice físico tocado (0-based, = byte9-1) -> tecla do config.
  # Default = identidade. Use `listen` para descobrir o índice físico e ajustar.
  keymap = {}
  (settings["keymap"] || {}).each { |from, to| keymap[Integer(from)] = Integer(to) }

  { settings: settings, keys: keys, keymap: keymap, base_dir: base_dir,
    res: Integer(settings["res"] || FifineDeck::RES) }
end

# Renderiza a especificação de UMA tecla em JPEG. Precedência: image > text > color.
def render_spec(spec, base_dir, res)
  bg = (spec["background"] || "000000").to_s
  if (img = spec["image"])
    path = File.absolute_path?(img) ? img : File.join(base_dir, img)
    FifineDeck::Render.image(path, size: res)
  elsif (ico = spec["icon"])
    begin
      FifineDeck::Render.icon(ico, background: bg, size: res)
    rescue RuntimeError => e
      warn "  ! #{e.message}\n    -> caindo para texto"
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
    FifineDeck::Render.color("000000", size: res) # tecla declarada mas vazia -> preta
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
  warn "  ! falha ao executar #{cmd.inspect}: #{e.message}"
end

# ── comandos ────────────────────────────────────────────────────────────────
def cmd_apply(path)
  cfg = load_config(path)
  jpegs = render_all(cfg)
  FifineDeck::Deck.open do |deck|
    deck.apply_images(jpegs, brightness: cfg[:settings]["brightness"])
  end
  puts "Pintei #{jpegs.size} tecla(s)."
end

def cmd_run(path)
  cfg = load_config(path)
  res = cfg[:res]
  jpegs = render_all(cfg)
  brightness = cfg[:settings]["brightness"]
  w = cfg[:settings]["welcome"] || {}
  g = cfg[:settings]["goodbye"] || {}
  last = Hash.new(0.0)

  # SIGINT (Ctrl-C) e SIGTERM (systemd/sessão) -> para o loop e pinta o "tchau".
  stop = false
  %w[INT TERM].each { |sig| trap(sig) { stop = true } }

  FifineDeck::Deck.open do |deck|
    # boas-vindas
    show_splash(deck, text: w["text"] || "Olá!",
                background: (w["background"] || "1e1e2e").to_s,
                color: (w["color"] || "ffffff").to_s,
                brightness: brightness, res: res, hold: 1.3)
    deck.apply_images(jpegs, brightness: brightness)
    log "Deck ligado: #{jpegs.size} teclas pintadas. Escutando toques… (Ctrl-C/SIGTERM para sair)"
    notify("Deck ligado", "Escutando os toques do FIFINE D6.")

    until stop
      next unless deck.wait_readable(0.3) # acorda p/ checar `stop`
      idx = deck.read_press
      next unless idx
      ckey = cfg[:keymap].fetch(idx, idx)
      now = mono
      next if now - last[ckey] < DEBOUNCE
      last[ckey] = now
      spec = cfg[:keys][ckey]
      label = ckey == idx ? "tecla #{idx}" : "tecla #{idx} → config #{ckey}"
      if spec && spec["command"]
        log "#{label}: #{spec['command']}"
        run_command(spec["command"])
      else
        log "#{label}: (sem comando)"
      end
    end
  ensure
    # estado "parado" bem visível: deixa claro que o ruby não escuta mais.
    # best-effort: se o device sumiu, não deixa isso mascarar o erro original.
    begin
      show_splash(deck, text: g["text"] || "Deck OFF",
                  background: (g["background"] || "2a0a0a").to_s,
                  color: (g["color"] || "ff6666").to_s,
                  brightness: g["brightness"] || 25, res: res) if deck
    rescue StandardError => e
      log "não consegui pintar o 'OFF' (#{e.class}: #{e.message})"
    end
    log "Deck parado (não estou mais escutando)."
    notify("Deck desligado", "Parei de escutar os toques.")
  end
rescue EOFError
  abort "Device desconectado."
end

def cmd_listen(path)
  # Não exige config; serve para descobrir o mapeamento físico das teclas.
  res_cfg = File.exist?(path) ? load_config(path) : nil
  keymap  = res_cfg ? res_cfg[:keymap] : {}
  FifineDeck::Deck.open do |deck|
    puts "Pressione as teclas para ver o índice (Ctrl-C para sair)."
    puts "Use isto para montar `settings.keymap` se a tecla tocada ≠ a tecla pintada."
    loop do
      idx = deck.read_press
      next unless idx
      mapped = keymap.fetch(idx, idx)
      extra = mapped == idx ? "" : "  (mapeada p/ config #{mapped})"
      puts "  toque: índice físico #{idx}#{extra}"
    end
  end
rescue Interrupt
  puts "\nTchau."
rescue EOFError
  abort "Device desconectado."
end

def cmd_clear
  FifineDeck::Deck.open do |deck|
    deck.init!
    deck.clear_all
    deck.finish!
  end
  puts "Teclas apagadas."
end

# ── dispatch ────────────────────────────────────────────────────────────────
config_path = ARGV[1] || "deck.yml"
begin
  case ARGV[0]
  when "apply"  then cmd_apply(config_path)
  when "run"    then cmd_run(config_path)
  when "listen" then cmd_listen(config_path)
  when "clear"  then cmd_clear
  else
    puts File.read(__FILE__)[/^# USO:.*?# ────/m].gsub(/^# ?/, "")
  end
rescue Errno::EACCES, Errno::EPERM
  abort "Sem permissão para abrir o device. Rode com sudo ou instale a regra udev " \
        "(41-fifine-d6-0060.rules)."
rescue RuntimeError => e
  abort "Erro: #{e.message}"
end
