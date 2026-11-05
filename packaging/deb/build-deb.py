#!/usr/bin/env python3
"""Builds polaris-widget_<version>-1_all.deb with only the Python standard library.
Run from anywhere:  python3 packaging/deb/build-deb.py     (output: out/)"""
import gzip, hashlib, io, os, re, sys, tarfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, 'src')
VERSION = re.search(r'^Version:\s*(\S+)', open(os.path.join(ROOT, 'polaris.spec')).read(), re.M).group(1)
NAME, REV = 'polaris-widget', '1'
NOW = int(os.environ.get('SOURCE_DATE_EPOCH', time.time()))

def read(p, mode='rb'): return open(p, mode).read()

# (path inside the package, source bytes, mode)
unit = read(os.path.join(SRC, 'polaris-smart.service')).replace(b'/usr/libexec/polaris', b'/usr/lib/polaris')
files = [
    ('usr/bin/polaris', read(f'{SRC}/polaris'), 0o755),
    ('usr/bin/polaris-settings', read(f'{SRC}/polaris-settings'), 0o755),
    ('usr/share/polaris/conky.conf', read(f'{SRC}/conky.conf'), 0o644),
    ('usr/share/polaris/rings.lua', read(f'{SRC}/rings.lua'), 0o644),
    ('usr/lib/polaris/polaris-smart', read(f'{SRC}/polaris-smart'), 0o755),
    ('lib/systemd/system/polaris-smart.service', unit, 0o644),
    ('lib/systemd/system/polaris-smart.timer', read(f'{SRC}/polaris-smart.timer'), 0o644),
    ('usr/share/applications/polaris.desktop', read(f'{SRC}/polaris-app.desktop'), 0o644),
    ('usr/share/icons/hicolor/scalable/apps/polaris.svg', read(f'{SRC}/polaris.svg'), 0o644),
    ('etc/xdg/autostart/polaris.desktop', read(f'{SRC}/polaris.desktop'), 0o644),
    ('usr/share/doc/%s/README.md' % NAME, read(f'{ROOT}/README.md'), 0o644),
    ('usr/share/doc/%s/copyright' % NAME, (
        'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\n'
        'Upstream-Name: Polaris\nSource: https://github.com/fr3on/polaris\n\n'
        'Files: *\nCopyright: 2026 fr3on\nLicense: MIT\n\n'
        'License: MIT\n' + ''.join(' ' + (l if l.strip() else '.') + '\n' for l in read(f'{ROOT}/LICENSE', 'r').splitlines()[2:])
    ).encode(), 0o644),
    ('usr/share/doc/%s/changelog.gz' % NAME, gzip.compress((
        f'{NAME} ({VERSION}-{REV}) unstable; urgency=low\n\n  * First release.\n\n'
        ' -- fr3on <ahmed@0x200.com>  ' + time.strftime('%a, %d %b %Y %H:%M:%S +0000', time.gmtime(NOW)) + '\n').encode(), mtime=0), 0o644),
]
dirs = sorted({os.path.dirname('/'.join(p.split('/')[:i])) for p, _, _ in files for i in range(1, len(p.split('/')))} | {'etc', 'etc/xdg', 'etc/xdg/autostart'})
dirs = sorted({'/'.join(p.split('/')[:i]) for p, _, _ in files for i in range(1, len(p.split('/')))})

def tar_bytes(entries, with_dirs):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.GNU_FORMAT) as t:
        def meta(ti, mode):
            ti.uid = ti.gid = 0; ti.uname = ti.gname = 'root'; ti.mtime = NOW; ti.mode = mode; return ti
        if with_dirs:
            for d in dirs:
                ti = tarfile.TarInfo('./' + d + '/'); ti.type = tarfile.DIRTYPE; t.addfile(meta(ti, 0o755))
        for path, data, mode in entries:
            ti = tarfile.TarInfo('./' + path); ti.size = len(data); t.addfile(meta(ti, mode), io.BytesIO(data))
    return gzip.compress(buf.getvalue(), mtime=0)

data_tgz = tar_bytes(files, True)
installed_kb = sum(len(d) for _, d, _ in files) // 1024 + 1
control = f'''Package: {NAME}
Version: {VERSION}-{REV}
Section: utils
Priority: optional
Architecture: all
Maintainer: fr3on <ahmed@0x200.com>
Installed-Size: {installed_kb}
Depends: conky-all, python3, libx11-6, nvme-cli
Recommends: python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1 (>= 1.4), lm-sensors, pkexec | policykit-1
Suggests: x11-xserver-utils
Homepage: https://github.com/fr3on/polaris
Description: Transparent desktop widget that shows your machine's health in plain words
 Polaris sits on the desktop and shows a health score, CPU, memory, GPU, power,
 network, storage, temperatures and fans, plus insights: pending and security
 updates, reboot needed, failed services, NVMe wear and last backup.
 Sensors, network interface, GPU and fans are detected automatically.
'''.encode()
postinst = b'''#!/bin/sh
set -e
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q /usr/share/icons/hicolor || true
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload || true
  [ -e /sys/class/nvme/nvme0 ] && systemctl enable --now polaris-smart.timer || true
fi
exit 0
'''
prerm = b'''#!/bin/sh
set -e
if [ "$1" = remove ] && [ -d /run/systemd/system ]; then systemctl disable --now polaris-smart.timer || true; fi
exit 0
'''
md5 = ''.join('%s  %s\n' % (hashlib.md5(d).hexdigest(), p) for p, d, _ in files if not p.endswith('changelog.gz') or True).encode()
conffiles = b'/etc/xdg/autostart/polaris.desktop\n'
control_tgz = tar_bytes([('control', control, 0o644), ('md5sums', md5, 0o644), ('conffiles', conffiles, 0o644),
                         ('postinst', postinst, 0o755), ('prerm', prerm, 0o755)], False)

def ar(members):
    out = b'!<arch>\n'
    for name, data in members:
        out += (name + '/').ljust(16).encode() + str(NOW).ljust(12).encode() + b'0     0     100644  ' + str(len(data)).ljust(10).encode() + b'`\n' + data
        if len(data) % 2: out += b'\n'
    return out

deb = ar([('debian-binary', b'2.0\n'), ('control.tar.gz', control_tgz), ('data.tar.gz', data_tgz)])
os.makedirs(os.path.join(ROOT, 'out'), exist_ok=True)
path = os.path.join(ROOT, 'out', f'{NAME}_{VERSION}-{REV}_all.deb')
open(path, 'wb').write(deb)
print(path, len(deb), 'bytes')
