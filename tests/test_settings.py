"""Run: python3 tests/test_settings.py   (the settings window's non-GUI logic, with GTK stubbed out)"""
import importlib.machinery, importlib.util, os, stat, sys, tempfile, types

for n in ('gi', 'gi.repository'):
    sys.modules[n] = types.ModuleType(n)
sys.modules['gi'].require_version = lambda *a: None
for k in ('Adw', 'Gdk', 'GLib', 'Gtk'):
    setattr(sys.modules['gi.repository'], k, types.SimpleNamespace(Application=object))
home = tempfile.mkdtemp(); os.environ['HOME'] = home
src = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'polaris-settings')
loader = importlib.machinery.SourceFileLoader('polaris_settings', src)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader('polaris_settings', loader)); loader.exec_module(m)
fails = 0
def eq(a, b, msg):
    global fails
    if a != b: fails += 1; print('FAIL %s: got %r, want %r' % (msg, a, b))

# a damaged number keeps its default (it used to crash the window at float())
open(m.SET, 'w').write('temp_warn=abc\ntemp_hot=90\nunit=F\nnot_a_key=1\n')
s = m.load()
eq(s['temp_warn'], '75', 'damaged number falls back'); eq(s['temp_hot'], '90', 'good number kept'); eq(s['unit'], 'F', 'text field kept'); eq('not_a_key' in s, False, 'unknown key ignored')

# root-run files must come from a folder only root can change
d = tempfile.mkdtemp()
for n in ('polaris-smart', 'polaris-smart.service', 'polaris-smart.timer'): open(os.path.join(d, n), 'w').write('x')
eq(m.root_owned_dir(d), os.getuid() == 0 and not (os.stat(d).st_mode & 0o022), 'a folder owned by a normal user is refused')
eq(m.root_owned_dir('/nonexistent'), False, 'missing folder is refused')
m.here = lambda name: os.path.join(d, name)
m.os.path.exists = (lambda real: lambda p: False if 'polaris-smart.timer' in p and p.startswith('/') and 'systemd' in p else real(p))(os.path.exists)
eq(m.setup_command(), None if os.getuid() != 0 else m.setup_command(), 'no root install from a user-writable folder')

# the path is an argument, never part of the shell text
m.root_owned_dir = lambda _d: True
cmd = m.setup_command()
eq(cmd[:3], ['pkexec', 'sh', '-c'], 'runs through pkexec'); eq(cmd[-1], d, 'folder passed as an argument'); eq(d in cmd[3], False, 'folder is not spliced into the script')
evil = os.path.join(tempfile.mkdtemp(), 'a"; touch pwned; $(id) `id`; echo "'); os.mkdir(evil)
m.here = lambda name: os.path.join(evil, name)
c2 = m.setup_command(); eq(evil in c2[3], False, 'a hostile folder name cannot reach the shell text'); eq(c2[-1], evil, 'it stays one argument')

# autostart entry survives a path with spaces
m.shutil.which = lambda n: '/opt/my apps/polaris'
os.makedirs(os.path.dirname(m.AUTOSTART), exist_ok=True); m.set_autostart(True)
eq('Exec="/opt/my apps/polaris"' in open(m.AUTOSTART).read(), True, 'Exec path with spaces is quoted')
print('all passed' if not fails else '%d failed' % fails); sys.exit(1 if fails else 0)
