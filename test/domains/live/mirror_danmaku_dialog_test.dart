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

MirrorDanmakuConfig _configFor(String roomId, {bool enabled = true}) {
  return MirrorDanmakuConfig(
    platform: 'bilibili',
    roomId: roomId,
    sourceUrl: 'https://live.bilibili.com/$roomId',
    nick: 'N-$roomId',
    title: 'T-$roomId',
    enabled: enabled,
  );
}

class _DialogHarness {
  _DialogHarness({required List<MirrorDanmakuConfig> targets}) {
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
    storage[store.keyFor(hostRoom)] = jsonEncode(<String, Object?>{
      'version': MirrorDanmakuStore.payloadVersion,
      'targets': <Map<String, Object?>>[for (final target in targets) target.toJson()],
    });
    controller = MirrorDanmakuController(
      host: host,
      store: store,
      resolver: MirrorDanmakuResolver(
        linkParser: (input, _) async => <String>[input.trim(), 'bilibili'],
        detailLoader: (_, roomId) async => LiveRoom(
          platform: 'bilibili',
          roomId: roomId,
          liveStatus: LiveStatus.live,
          danmakuData: 'args',
          nick: 'N-$roomId',
          title: 'T-$roomId',
        ),
        timeout: const Duration(milliseconds: 200),
      ),
      engineFactory: (room) {
        final engine = FakeMirrorDanmakuEngine();
        engines.add(engine);
        enginesByRoom[room.roomId ?? ''] = engine;
        return engine;
      },
      filterPolicyProvider: () => const MirrorDanmakuFilterPolicy(),
      maxTargets: 4,
    );
  }

  final LiveRoom hostRoom = LiveRoom(platform: 'bilibili', roomId: 'host-room', liveStatus: LiveStatus.live);
  final Map<String, String> storage = <String, String>{};
  final List<FakeMirrorDanmakuEngine> engines = <FakeMirrorDanmakuEngine>[];
  final Map<String, FakeMirrorDanmakuEngine> enginesByRoom = <String, FakeMirrorDanmakuEngine>{};
  late final FakeMirrorDanmakuHost host;
  late final MirrorDanmakuStore store;
  late final MirrorDanmakuController controller;
  bool failWrites = false;

  List<MirrorDanmakuConfig> get savedConfigs {
    final raw = storage[store.keyFor(hostRoom)];
    if (raw == null) return const <MirrorDanmakuConfig>[];
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const <MirrorDanmakuConfig>[];
    final targets = decoded['targets'];
    if (targets is! List) return const <MirrorDanmakuConfig>[];
    final configs = <MirrorDanmakuConfig>[];
    for (final item in targets) {
      final config = MirrorDanmakuConfig.fromJson(item);
      if (config != null) configs.add(config);
    }
    return configs;
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

Future<void> _pumpFrames(WidgetTester tester, [int count = 12]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _openDialog(WidgetTester tester, _DialogHarness harness) async {
  await tester.pumpWidget(_app(harness));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await _pumpFrames(tester);
}

void main() {
  testWidgets('对话框按持久化配置显示目标列表，停用目标保持停用', (tester) async {
    final harness = _DialogHarness(
      targets: <MirrorDanmakuConfig>[_configFor('target-a', enabled: false), _configFor('target-b')],
    );

    await _openDialog(tester, harness);

    expect(find.text('N-target-a'), findsOneWidget);
    expect(find.text('N-target-b'), findsOneWidget);
    expect(
      tester.widget<Switch>(find.byKey(const ValueKey<String>('mirror-danmaku-target-switch-bilibili:target-a'))).value,
      isFalse,
    );
    expect(
      tester.widget<Switch>(find.byKey(const ValueKey<String>('mirror-danmaku-target-switch-bilibili:target-b'))).value,
      isTrue,
    );
    expect(harness.savedConfigs.first.enabled, isFalse);
    expect(harness.engines, hasLength(1));
  });

  testWidgets('单独停用目标会写回并只断开该目标', (tester) async {
    final harness = _DialogHarness(targets: <MirrorDanmakuConfig>[_configFor('target-a'), _configFor('target-b')]);
    await _openDialog(tester, harness);
    final engineB = harness.enginesByRoom['target-b']!;

    await tester.tap(find.byKey(const ValueKey<String>('mirror-danmaku-target-switch-bilibili:target-b')));
    await _pumpFrames(tester);

    expect(harness.savedConfigs.firstWhere((config) => config.roomId == 'target-b').enabled, isFalse);
    expect(engineB.stopCount, 1);
    expect(harness.enginesByRoom['target-a']!.stopCount, 0);
    expect(
      tester.widget<Switch>(find.byKey(const ValueKey<String>('mirror-danmaku-target-switch-bilibili:target-b'))).value,
      isFalse,
    );
  });

  testWidgets('解析并添加第二个目标后列表和会话同步增加', (tester) async {
    final harness = _DialogHarness(targets: <MirrorDanmakuConfig>[_configFor('target-a')]);
    await _openDialog(tester, harness);

    await tester.enterText(find.byType(TextField), 'target-b');
    await tester.pump();
    final previewButton = find.widgetWithText(OutlinedButton, i18n('mirror_danmaku_preview'));
    await tester.ensureVisible(previewButton);
    await tester.tap(previewButton);
    await _pumpFrames(tester);

    final addButton = find.widgetWithText(FilledButton, i18n('mirror_danmaku_add'));
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await _pumpFrames(tester);

    expect(harness.savedConfigs.map((config) => config.identityKey), contains('bilibili:target-b'));
    expect(find.text('N-target-b'), findsOneWidget);
    expect(harness.enginesByRoom.containsKey('target-b'), isTrue);
    expect(find.text(i18n('mirror_danmaku_added')), findsOneWidget);
  });

  testWidgets('重复添加同一目标提示已在列表中', (tester) async {
    final harness = _DialogHarness(targets: <MirrorDanmakuConfig>[_configFor('target-a')]);
    await _openDialog(tester, harness);

    await tester.enterText(find.byType(TextField), 'target-a');
    await tester.pump();
    final previewButton = find.widgetWithText(OutlinedButton, i18n('mirror_danmaku_preview'));
    await tester.ensureVisible(previewButton);
    await tester.tap(previewButton);
    await _pumpFrames(tester);

    final addButton = find.widgetWithText(FilledButton, i18n('mirror_danmaku_add'));
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await _pumpFrames(tester);

    expect(find.text(i18n('mirror_danmaku_duplicate_target')), findsOneWidget);
    expect(harness.savedConfigs, hasLength(1));
  });

  testWidgets('停用写盘失败时开关保持启用并显示保存失败', (tester) async {
    final harness = _DialogHarness(targets: <MirrorDanmakuConfig>[_configFor('target-a')]);
    await _openDialog(tester, harness);

    harness.failWrites = true;
    await tester.tap(find.byKey(const ValueKey<String>('mirror-danmaku-target-switch-bilibili:target-a')));
    await _pumpFrames(tester);

    expect(
      tester.widget<Switch>(find.byKey(const ValueKey<String>('mirror-danmaku-target-switch-bilibili:target-a'))).value,
      isTrue,
    );
    expect(harness.savedConfigs.single.enabled, isTrue);
    expect(harness.enginesByRoom['target-a']!.stopCount, 0);
    expect(find.text(i18n('mirror_danmaku_save_failed')), findsOneWidget);
  });
}
