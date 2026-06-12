# shell.nix — ambiente para o deck.rb (FIFINE D6).
#
#   nix-shell --run "ruby deck.rb apply deck.yml"
#   nix-shell                       # entra no shell; depois: ruby deck.rb run deck.yml
#
# Traz Ruby + ImageMagick + fontconfig + fonte DejaVu, e (via makeFontsConf)
# aponta o FONTCONFIG_FILE para a fonte — sem isso o ImageMagick falha ao
# renderizar texto com `font (null)` dentro do nix-shell.
#
# python3 + pyside6 são para a bandeja do KDE (bin/deck-tray), que usa
# QSystemTrayIcon (SNI) — o que de fato aparece no systray do Plasma Wayland.
#
# OBS sobre device: escrever no deck precisa de acesso ao /dev/hidraw*. Prefira
# instalar a regra udev (../41-fifine-d6-0060.rules) para rodar SEM sudo — pois
# `sudo` dentro do nix-shell perde o PATH/ambiente do Nix. Se for de sudo mesmo,
# use:  sudo -E env PATH="$PATH" ruby deck.rb apply deck.yml

{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = with pkgs; [
    bash ruby imagemagick fontconfig dejavu_fonts
    python3 python3Packages.pyside6
  ];

  FONTCONFIG_FILE = pkgs.makeFontsConf {
    fontDirectories = [ pkgs.dejavu_fonts ];
  };
}
