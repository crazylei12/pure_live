import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/index.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_config.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_resolver.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_store.dart';
import 'package:pure_live/domains/live/presentation/playback/controllers/mirror_danmaku_controller.dart';
import 'package:pure_live/domains/live/presentation/playback/dialogs/mirror_danmaku_dialog.dart';
import 'package:pure_live/domains/live/presentation/playback/services/mirror_danmaku_session.dart';

import 'mirror_danmaku_fakes.dart';

class _DialogHarness {
  _DialogHarness({required bool enabled}) {
    host = FakeMirrorDanmakuHost(hostIdentity: hostRoom.identityKey);
    store = MirrorDanmakuStore(
      read: (key) => storage[key],
      write: (key, value) async {
        if (failWrites) return false;
        storage[key] = value;
        return true;
      },
      remove: (key) async {
        storage.remove(key);
        return true;
      },
    );
    storage[store.keyFor(hostRoom)] = jsonEncode(
      MirrorDanmakuConfig(
        platform: 'bilibili',
        roomId: 'target-room',
        sourceUrl: sourceUrl,
        nick: 'B 主播',
        title: 'B 标题',
        enabled: enabled,
      ).toJson(),
    );
    controller = MirrorDanmakuController(
      host: host,
      store: store,
      resolver: MirrorDanmakuResolver(
        linkParser: (_, _) async => <String>['target-room', 'bilibili'],
        detailLoader: (_, _) async => LiveRoom(
          platform: 'bilibili',
          roomId: 'target-room',
          liveStatus: LiveStatus.live,
          danmakuData: 'args',
          nick: 'B 主播',
          title: 'B 标题',
        ),
        timeout: const Duration(milliseconds: 200),
      ),
      engineFactory: (_) {
        final engine = FakeMirrorDanmakuEngine();
        engines.add(engine);
        return engine;
      },
      filterPolicyProvider: () => const MirrorDanmakuFilterPolicy(),
    );
  }

  static const String sourceUrl = 'https://live.bilibili.com/target-room';

  final LiveRoom hostRoom = LiveRoom(platform: 'bilibili', roomId: 'host-room', liveStatus: LiveStatus.live);
  final Map<String, String> storage = <String, String>{};
  final List<FakeMirrorDanmakuEngine> engines = <FakeMirrorDanmakuEngine>[];
  late final FakeMirrorDanmakuHost host;
  late final MirrorDanmakuStore store;
  late final MirrorDanmakuController controller;
  bool failWrites = false;

  MirrorDanmakuConfig? get savedConfig {
    final raw = storage[store.keyFor(hostRoom)];
    if (raw == null) return null;
    return MirrorDanmakuConfig.fromJson(jsonDecode(raw));
  }
}

Widget _app(_DialogHarness harness) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => MirrorDanmakuEditor(mirror: harness.controller, hostRoom: harness.hostRoom),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

Future<void> _pumpFrames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('对话框在 attach 完成前按持久化配置初始化，保存不会重新启用', (tester) async {
    final harness = _DialogHarness(enabled: false);

    await tester.pumpWidget(_app(harness));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, _DialogHarness.sourceUrl);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await _pumpFrames(tester);
    await tester.tap(find.widgetWithText(FilledButton, i18n('mirror_danmaku_save')));
    await _pumpFrames(tester);

    expect(harness.savedConfig?.enabled, isFalse);
    expect(harness.controller.state.value.config?.enabled, isFalse);
    expect(harness.engines, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('停用写盘失败时开关保持启用并显示保存失败', (tester) async {
    final harness = _DialogHarness(enabled: true);

    await tester.pumpWidget(_app(harness));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await _pumpFrames(tester);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    harness.failWrites = true;
    await tester.tap(find.widgetWithText(OutlinedButton, i18n('mirror_danmaku_disable')));
    await _pumpFrames(tester);

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(harness.controller.state.value.config?.enabled, isTrue);
    expect(harness.savedConfig?.enabled, isTrue);
    expect(find.text(i18n('mirror_danmaku_save_failed')), findsOneWidget);
  });
}
