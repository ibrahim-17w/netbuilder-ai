import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hiding and showing the setup checklist survives a restart', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final first = SettingsService();
    await first.load();
    expect(first.readinessDismissed, isFalse);

    await first.dismissReadiness();
    expect(first.readinessDismissed, isTrue);

    final afterRestart = SettingsService();
    await afterRestart.load();
    expect(afterRestart.readinessDismissed, isTrue);

    await afterRestart.showReadiness();
    expect(afterRestart.readinessDismissed, isFalse);

    final afterSecondRestart = SettingsService();
    await afterSecondRestart.load();
    expect(afterSecondRestart.readinessDismissed, isFalse);
  });
}
