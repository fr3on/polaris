#!/bin/sh
# Polaris installer for any Linux with systemd. Installs dependencies automatically.
#   ./install.sh              install (uses sudo when needed)
#   ./install.sh --uninstall  remove
#   PREFIX=/usr ./install.sh  change the install prefix (default /usr/local)
#   NODEPS=1 ./install.sh     skip installing dependencies
#   DRYRUN=1 ./install.sh     print what would run, change nothing
set -e
PREFIX=${PREFIX:-/usr/local}
here=$(cd "$(dirname "$0")" && pwd)
SUDO=''; [ "$(id -u)" -ne 0 ] && SUDO='sudo'
run() { if [ "${DRYRUN:-0}" = 1 ]; then echo "+ $*"; else "$@"; fi }
say() { printf '==> %s\n' "$*"; }

if [ "$1" = "--uninstall" ]; then
  say "Removing Polaris from $PREFIX"
  $SUDO systemctl disable --now polaris-smart.timer 2>/dev/null || true
  run $SUDO rm -f "$PREFIX/bin/polaris" "$PREFIX/bin/polaris-settings" /usr/share/applications/polaris.desktop /usr/share/icons/hicolor/scalable/apps/polaris.svg /etc/xdg/autostart/polaris.desktop /etc/systemd/system/polaris-smart.service /etc/systemd/system/polaris-smart.timer
  run $SUDO rm -rf "$PREFIX/share/polaris" "$PREFIX/libexec/polaris"
  run $SUDO systemctl daemon-reload 2>/dev/null || true
  say "Done. Your settings stay in ~/.config/polaris (delete it to remove them)."
  exit 0
fi

# 1. dependencies, per package manager
if [ "${NODEPS:-0}" != 1 ]; then
  if command -v dnf >/dev/null 2>&1; then
    say "Installing dependencies with dnf"; run $SUDO dnf install -y conky python3 libX11 nvme-cli lm_sensors python3-gobject gtk4 libadwaita
  elif command -v apt-get >/dev/null 2>&1; then
    say "Installing dependencies with apt"; run $SUDO apt-get update -qq; run $SUDO apt-get install -y conky-all python3 libx11-6 nvme-cli lm-sensors python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
  elif command -v pacman >/dev/null 2>&1; then
    say "Installing dependencies with pacman"; run $SUDO pacman -S --needed --noconfirm conky python libx11 nvme-cli lm_sensors python-gobject gtk4 libadwaita
  elif command -v zypper >/dev/null 2>&1; then
    say "Installing dependencies with zypper"; run $SUDO zypper install -y conky python3 libX11-6 nvme-cli sensors python3-gobject typelib-1_0-Gtk-4_0 typelib-1_0-Adw-1
  else
    say "No known package manager found. Install by hand: conky (with Lua and Cairo), python3, nvme-cli, lm-sensors"
  fi
fi

# 2. files
say "Installing files into $PREFIX"
run $SUDO install -Dm0755 "$here/src/polaris" "$PREFIX/bin/polaris"
run $SUDO install -Dm0755 "$here/src/polaris-settings" "$PREFIX/bin/polaris-settings"
run $SUDO install -Dm0644 "$here/src/conky.conf" "$PREFIX/share/polaris/conky.conf"
run $SUDO install -Dm0644 "$here/src/rings.lua" "$PREFIX/share/polaris/rings.lua"
run $SUDO install -Dm0755 "$here/src/polaris-smart" "$PREFIX/libexec/polaris/polaris-smart"
tmp=$(mktemp -d)
sed "s#/usr/libexec/polaris#$PREFIX/libexec/polaris#" "$here/src/polaris-smart.service" > "$tmp/polaris-smart.service"
sed "s#/usr/bin/polaris#$PREFIX/bin/polaris#" "$here/src/polaris.desktop" > "$tmp/polaris.desktop"
sed -e "s#/usr/bin/polaris-settings#$PREFIX/bin/polaris-settings#" "$here/src/polaris-app.desktop" > "$tmp/polaris-app.desktop"
run $SUDO install -Dm0644 "$tmp/polaris-smart.service" /etc/systemd/system/polaris-smart.service
run $SUDO install -Dm0644 "$here/src/polaris-smart.timer" /etc/systemd/system/polaris-smart.timer
run $SUDO install -Dm0644 "$tmp/polaris.desktop" /etc/xdg/autostart/polaris.desktop
run $SUDO install -Dm0644 "$tmp/polaris-app.desktop" /usr/share/applications/polaris.desktop
run $SUDO install -Dm0644 "$here/src/polaris.svg" /usr/share/icons/hicolor/scalable/apps/polaris.svg
command -v gtk-update-icon-cache >/dev/null 2>&1 && run $SUDO gtk-update-icon-cache -q /usr/share/icons/hicolor || true
command -v update-desktop-database >/dev/null 2>&1 && run $SUDO update-desktop-database -q /usr/share/applications || true
rm -rf "$tmp"

# 3. disk-health timer (only useful when an NVMe disk exists)
if [ -e /sys/class/nvme/nvme0 ]; then
  say "Enabling the NVMe health timer"
  run $SUDO systemctl daemon-reload
  run $SUDO systemctl enable --now polaris-smart.timer
fi

say "Installed. Start it now with:  $PREFIX/bin/polaris &"
say "Check this machine with:       $PREFIX/bin/polaris --doctor"
