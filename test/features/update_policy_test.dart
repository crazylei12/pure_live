import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pure_live/core/config/font_settings_controller.dart';
import 'package:pure_live/core/storage/hive_pref_util.dart';
import 'package:pure_live/core/index.dart';
import 'package:pure_live/features/about/about_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await Hive.openBox<dynamic>('app_settings', bytes: Uint8List(0));
    await HivePrefUtil.init();
  });
  tearDownAll(() async => Hive.close());
  setUp(() {
    Get.testMode = true;
    Get.put(SettingsService());
    Get.put<FontSettingsController>(_TestFontSettings());
  });
  tearDown(() async => Get.reset());

  test('home has no automatic update request or update timer', () {
    final source = File('lib/features/home/home_page.dart').readAsStringSync();
    expect(source, isNot(contains('checkUpdate')));
    expect(source, isNot(contains('_checkForStartupUpdate')));
    expect(source, isNot(contains('_updateCheckTimer')));
    expect(source, contains('VersionUtil.initPackageInfo'));
  });

  test('settings do not expose an automatic update switch', () {
    final source = File('lib/features/settings/pages/general_settings_page.dart').readAsStringSync();
    expect(source, isNot(contains('enableAutoCheckUpdate')));
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('manual update opens fork latest release on ${platform.name}', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

      await tester.pumpWidget(const GetMaterialApp(home: AboutPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text(i18n('online_update')));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.method, 'launch');
      expect(calls.single.arguments['url'], 'https://github.com/crazylei12/pure_live/releases/latest');
      expect(calls.single.arguments['useWebView'], isFalse);
      expect(find.byType(AboutPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }
}

class _TestFontSettings extends FontSettingsController {
  @override
  Future<void> ensureInitialized() async {}
}
