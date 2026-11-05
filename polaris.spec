Name:           polaris
Version:        1.0.0
Release:        1%{?dist}
Summary:        Transparent desktop widget that shows your Linux machine's health in plain words
License:        MIT
BuildArch:      noarch
Source0:        %{name}-%{version}.tar.gz
Requires:       conky >= 1.19
Requires:       python3
Requires:       libX11
Requires:       nvme-cli
Requires:       python3-gobject
Requires:       gtk4
Requires:       libadwaita
Requires:       systemd
Recommends:     lm_sensors
Recommends:     polkit
Suggests:       smartmontools
BuildRequires:  systemd-rpm-macros

%description
polaris draws a transparent dashboard on the desktop with CPU, memory,
power, network, storage, temperatures, fans and plain-language insights
(pending updates, reboot needed, failed services, NVMe wear, last backup).
Sensors, network interface, GPU and fans are detected automatically; rows
for hardware that is missing are hidden.

Open Polaris from the app menu for the settings window (it also starts the widget), or run `polaris --settings`.
Drag the widget with Super + left mouse button. Settings:
  polaris --size 125     scale in percent (50 to 200)
  polaris --refresh 5    update every N seconds (1 to 60)
  polaris --reset        forget the saved position

%prep
%autosetup

%build

%install
install -Dm0755 src/polaris %{buildroot}%{_bindir}/polaris
install -Dm0755 src/polaris-settings %{buildroot}%{_bindir}/polaris-settings
install -Dm0644 src/polaris-app.desktop %{buildroot}%{_datadir}/applications/polaris.desktop
install -Dm0644 src/polaris.svg %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/polaris.svg
install -Dm0644 src/conky.conf %{buildroot}%{_datadir}/polaris/conky.conf
install -Dm0644 src/rings.lua %{buildroot}%{_datadir}/polaris/rings.lua
install -Dm0755 src/polaris-smart %{buildroot}%{_libexecdir}/polaris/polaris-smart
install -Dm0644 src/polaris-smart.service %{buildroot}%{_unitdir}/polaris-smart.service
install -Dm0644 src/polaris-smart.timer %{buildroot}%{_unitdir}/polaris-smart.timer
install -Dm0644 src/polaris.desktop %{buildroot}%{_sysconfdir}/xdg/autostart/polaris.desktop

%post
gtk-update-icon-cache -q %{_datadir}/icons/hicolor >/dev/null 2>&1 || :
update-desktop-database -q %{_datadir}/applications >/dev/null 2>&1 || :
%systemd_post polaris-smart.timer
systemctl enable --now polaris-smart.timer >/dev/null 2>&1 || :

%preun
%systemd_preun polaris-smart.timer

%postun
%systemd_postun_with_restart polaris-smart.timer

%files
%license LICENSE
%doc README.md
%{_bindir}/polaris
%{_bindir}/polaris-settings
%{_datadir}/polaris/
%{_datadir}/applications/polaris.desktop
%{_datadir}/icons/hicolor/scalable/apps/polaris.svg
%{_libexecdir}/polaris/
%{_unitdir}/polaris-smart.service
%{_unitdir}/polaris-smart.timer
%config(noreplace) %{_sysconfdir}/xdg/autostart/polaris.desktop

%changelog
* Thu Nov 05 2026 fr3on <ahmed@0x200.com> - 1.0.0-1
- First release
