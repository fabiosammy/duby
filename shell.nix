# shell.nix — environment for deck.rb (FIFINE D6).
#
#   nix-shell --run "ruby deck.rb apply deck.yml"
#   nix-shell                       # enter the shell; then: ruby deck.rb run deck.yml
#
# Provides Ruby + ImageMagick + fontconfig + the DejaVu font, and (via
# makeFontsConf) points FONTCONFIG_FILE at the font — without it ImageMagick
# fails to render text with `font (null)` inside the nix-shell.
#
# python3 + pyside6 are for the KDE tray (bin/deck-tray), which uses
# QSystemTrayIcon (SNI) — what actually shows up in the Plasma Wayland systray.
#
# NOTE about the device: writing to the deck needs access to /dev/hidraw*.
# Prefer installing the udev rule (../41-fifine-d6-0060.rules) to run WITHOUT
# sudo — because `sudo` inside nix-shell loses the Nix PATH/environment. If you
# must use sudo:  sudo -E env PATH="$PATH" ruby deck.rb apply deck.yml

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
