import 'package:hisvpn/common/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ProtocolRegistrationPlan', () {
    test('builds registry writes for URL protocol registration', () {
      const plan = ProtocolRegistrationPlan(
        scheme: 'hisvpn',
        executable: r'C:\Program Files\HISVPN\HISVPN.exe',
      );

      expect(plan.protocolKey, r'Software\Classes\hisvpn');
      expect(plan.commandKey, r'shell\open\command');
      expect(plan.protocolValueName, 'URL Protocol');
      expect(plan.protocolValue, '');
      expect(plan.command, r'"C:\Program Files\HISVPN\HISVPN.exe" "%1"');
    });
  });

  group('LinuxProtocolRegistrationPlan', () {
    const plan = LinuxProtocolRegistrationPlan(
      schemes: protocolSchemes,
      executable: '/home/me/Apps/HISVPN.AppImage',
      applicationsDir: '/home/me/.local/share/applications',
    );

    test('writes a hidden desktop entry claiming every scheme', () {
      expect(
        plan.desktopPath,
        '/home/me/.local/share/applications/hisvpn-url-handler.desktop',
      );
      expect(
        plan.desktopEntry,
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=HISVPN\n'
        'NoDisplay=true\n'
        'Exec="/home/me/Apps/HISVPN.AppImage" %u\n'
        'MimeType=x-scheme-handler/clash;x-scheme-handler/clashmeta;'
        'x-scheme-handler/hisvpn;\n',
      );
    });

    test('makes the entry the default handler for every scheme', () {
      expect(plan.xdgMimeArguments, [
        'default',
        'hisvpn-url-handler.desktop',
        'x-scheme-handler/clash',
        'x-scheme-handler/clashmeta',
        'x-scheme-handler/hisvpn',
      ]);
    });

    test('escapes reserved characters in the executable path', () {
      const plan = LinuxProtocolRegistrationPlan(
        schemes: ['hisvpn'],
        executable: r'/opt/my "apps"/$HOME/100%/Fl`Clash\bin',
        applicationsDir: '/tmp',
      );

      expect(plan.exec, r'"/opt/my \"apps\"/\$HOME/100%%/Fl\`Clash\\bin" %u');
    });
  });
}
