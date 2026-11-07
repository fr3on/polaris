# Changelog

## 1.1.0 - 2026-11-07

- **Several GPUs and CPU sockets.** One row per NVIDIA card and per CPU socket for load, temperature and power. The hottest part drives the health score and is named in the header. With more than 8 cards, Usage and Thermals show an average and the busiest or hottest card instead.
- **Fixed: widget drew nothing on Lua 5.4** (conky 1.24), and the GPU average row failed on machines with more than 8 GPUs.
- **Safer settings window.** It no longer installs root-run files from a folder you can write to.
- **No shared `/tmp` files.** The lock and the update cache live in your own folders, and shell paths are quoted.
- **A hung NVIDIA driver can no longer freeze the widget** (`nvidia-smi` gets 5 seconds).
- **A damaged value in `settings.conf` is ignored** instead of breaking the widget or the settings window.
- **Reload works next to other conky widgets.** `polaris --doctor` tells you when the CPU power counter is root-only.
- **Installer refreshes the icon and desktop caches** (a mistyped `&&` skipped it).
- **GitHub Actions:** CI (Lua 5.4 and LuaJIT, Python, shell, deb, rpm) and release builds on version tags.

## 1.0.0 - 2026-11-05

- First release.
