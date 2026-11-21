import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/index.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_config.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_resolver.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_store.dart';
import 'package:pure_live/domains/live/presentation/playback/controllers/mirror_danmaku_controller.dart';
import 'package:pure_live/domains/live/presentation/playback/services/mirror_danmaku_session.dart';

import 'mirror_danmaku_fakes.dart';

void main() {
  final hostRoom = LiveRoom(platform: 'bilibili', roomId: 'host-room', liveStatus: LiveStatus.live);
  final otherHostRoom = LiveRoom(platform: 'douyu', roomId: 'other-host', liveStatus: LiveStatus.live);

  late FakeMirrorDanmakuHost host;
  late Map<String, String> storage;
  late bool failWrites;
  late bool failRemoves;
  late Set<String> offlineRoomIds;
  late int lookups;
  late MirrorDanmakuStore store;
  late MirrorDanmakuResolver resolver;
  late List<FakeMirrorDanmakuEngine> engines;
  late Map<String, FakeMirrorDanmakuEngine> enginesByRoom;
  late RxBool hideDanmaku;
  late MirrorDanmakuController controller;

  LiveRoom targetRoom(String roomId) {
    return LiveRoom(
      platform: 'bilibili',
      roomId: roomId,
      liveStatus: offlineRoomIds.contains(roomId) ? LiveStatus.offline : LiveStatus.live,
      danmakuData: 'args',
      nick: 'N-$roomId',
      title: 'T-$roomId',
    );
  }

  MirrorDanmakuConfig configFor(String roomId, {bool enabled = true}) {
    return MirrorDanmakuConfig(
      platform: 'bilibili',
      roomId: roomId,
      sourceUrl: 'https://live.bilibili.com/$roomId',
      nick: 'N-$roomId',
      title: 'T-$roomId',
      enabled: enabled,
    );
  }

  void persistTargets(List<MirrorDanmakuConfig> configs) {
    storage[store.keyFor(hostRoom)] = jsonEncode(<String, Object?>{
      'version': MirrorDanmakuStore.payloadVersion,
      'targets': <Map<String, Object?>>[for (final config in configs) config.toJson()],
    });
  }

  MirrorDanmakuController buildController({int maxTargets = MirrorDanmakuController.defaultMaxTargets}) {
    return MirrorDanmakuController(
      host: host,
      store: store,
      resolver: resolver,
      engineFactory: (room) {
        final engine = FakeMirrorDanmakuEngine();
        engines.add(engine);
        enginesByRoom[room.roomId ?? ''] = engine;
        return engine;
      },
      filterPolicyProvider: () => const MirrorDanmakuFilterPolicy(),
      hideDanmaku: hideDanmaku,
      maxTargets: maxTargets,
    );
  }

  MirrorDanmakuTargetState targetState(String roomId) {
    final state = controller.state.value.targetFor('bilibili:$roomId');
    expect(state, isNotNull, reason: roomId);
    return state!;
  }

  setUp(() {
    host = FakeMirrorDanmakuHost(hostIdentity: hostRoom.identityKey);
    storage = <String, String>{};
    failWrites = false;
    failRemoves = false;
    offlineRoomIds = <String>{};
    lookups = 0;
    engines = <FakeMirrorDanmakuEngine>[];
    enginesByRoom = <String, FakeMirrorDanmakuEngine>{};
    hideDanmaku = false.obs;
    store = MirrorDanmakuStore(
      read: (key) => storage[key],
      write: (key, value) async {
        if (failWrites) return false;
        storage[key] = value;
        return true;
      },
      remove: (key) async {
        if (failRemoves) return false;
        storage.remove(key);
        return true;
      },
    );
    resolver = MirrorDanmakuResolver(
      linkParser: (input, _) async => <String>[input.trim(), 'bilibili'],
      detailLoader: (_, roomId) async {
        lookups++;
        return targetRoom(roomId);
      },
      timeout: const Duration(milliseconds: 200),
    );
    controller = buildController();
  });

  tearDown(() async {
    await controller.dispose();
    hideDanmaku.close();
  });

  group('多目标镜像弹幕控制器', () {
    test('进入 A 房间后同时连接所有目标，聊天分别直达宿主', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a'), configFor('target-b')]);

      await controller.attachHost(hostRoom);

      expect(lookups, 2);
      expect(engines, hasLength(2));
      expect(targetState('target-a').status, MirrorDanmakuStatus.connected);
      expect(targetState('target-b').status, MirrorDanmakuStatus.connected);
      expect(targetState('target-a').target?.nick, 'N-target-a');
      expect(controller.state.value.count, 2);

      enginesByRoom['target-a']!.emit(mirrorChat(message: 'from a'));
      enginesByRoom['target-b']!.emit(mirrorChat(message: 'from b'));

      expect(host.chats.map((message) => message.message), <String>['from a', 'from b']);
      expect(host.systemMessages, hasLength(2));
    });

    test('进入没有配置的 C 房间不继承 A 的目标，旧会话全部停止', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a'), configFor('target-b')]);
      await controller.attachHost(hostRoom);
      final oldEngines = List<FakeMirrorDanmakuEngine>.of(engines);

      host.hostIdentity = otherHostRoom.identityKey;
      await controller.attachHost(otherHostRoom);

      expect(oldEngines.every((engine) => engine.stopCount == 1), isTrue);
      expect(controller.state.value.isEmpty, isTrue);
      expect(storage.containsKey(store.keyFor(hostRoom)), isTrue);
    });

    test('A 切换后旧目标消息即使穿过旧回调也被宿主身份拦截', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a')]);
      await controller.attachHost(hostRoom);
      final staleCallback = enginesByRoom['target-a']!.onMessage!;

      host.hostIdentity = otherHostRoom.identityKey;
      await controller.attachHost(otherHostRoom);
      staleCallback(mirrorChat(message: 'late'));

      expect(host.chats, isEmpty);
    });

    test('宿主身份变化后当前目标消息也不再进入 A', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a')]);
      await controller.attachHost(hostRoom);

      host.hostIdentity = 'bilibili:another-room';
      enginesByRoom['target-a']!.emit(mirrorChat());

      expect(host.chats, isEmpty);
    });

    test('一个目标未开播不阻塞另一个；单独重试只影响该目标', () async {
      offlineRoomIds.add('target-offline');
      persistTargets(<MirrorDanmakuConfig>[configFor('target-live'), configFor('target-offline')]);

      await controller.attachHost(hostRoom);

      expect(engines, hasLength(1));
      expect(targetState('target-live').status, MirrorDanmakuStatus.connected);
      expect(targetState('target-offline').status, MirrorDanmakuStatus.offline);
      expect(enginesByRoom.containsKey('target-offline'), isFalse);

      offlineRoomIds.remove('target-offline');
      await controller.retry(identityKey: 'bilibili:target-offline');

      expect(targetState('target-offline').status, MirrorDanmakuStatus.connected);
      expect(enginesByRoom['target-live']!.stopCount, 0);
    });

    test('重复 attach 同一宿主是幂等的，不重复解析或建连', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a'), configFor('target-b')]);

      await controller.attachHost(hostRoom);
      await controller.attachHost(hostRoom);

      expect(lookups, 2);
      expect(engines, hasLength(2));
    });

    test('添加第二个目标只新增一个会话，重复目标被拒绝', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a')]);
      await controller.attachHost(hostRoom);
      expect(engines, hasLength(1));

      final preview = await controller.preview('target-b');
      final added = await controller.addAndApply(configFor('target-b'), resolved: preview);

      expect(added, isTrue);
      expect(controller.state.value.count, 2);
      expect(engines, hasLength(2));
      expect(targetState('target-b').status, MirrorDanmakuStatus.connected);
      expect(targetState('target-a').status, MirrorDanmakuStatus.connected);

      final duplicatePreview = await controller.preview('target-b');
      final duplicate = await controller.addAndApply(configFor('target-b'), resolved: duplicatePreview);

      expect(duplicate, isFalse);
      expect(controller.state.value.count, 2);
      expect(controller.state.value.message, i18n('mirror_danmaku_duplicate_target'));
    });

    test('达到目标上限后拒绝继续添加', () async {
      await controller.dispose();
      controller = buildController(maxTargets: 2);
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a')]);
      await controller.attachHost(hostRoom);

      final secondPreview = await controller.preview('target-b');
      expect(await controller.addAndApply(configFor('target-b'), resolved: secondPreview), isTrue);

      final thirdPreview = await controller.preview('target-c');
      final third = await controller.addAndApply(configFor('target-c'), resolved: thirdPreview);

      expect(third, isFalse);
      expect(controller.state.value.count, 2);
      expect(controller.state.value.message, i18n('mirror_danmaku_limit_reached', args: <String, String>{'max': '2'}));
      expect(enginesByRoom.containsKey('target-c'), isFalse);
    });

    test('添加目标时可以设置为停用，只保存不建连', () async {
      await controller.attachHost(hostRoom);
      final preview = await controller.preview('target-b');

      final added = await controller.addAndApply(configFor('target-b', enabled: false), resolved: preview);

      expect(added, isTrue);
      expect(targetState('target-b').status, MirrorDanmakuStatus.disabled);
      expect(engines, isEmpty);
      expect(controller.state.value.count, 1);
    });

    test('停用单个目标只断开该目标；重新启用后恢复，其他目标不受影响', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a'), configFor('target-b')]);
      await controller.attachHost(hostRoom);
      final engineA = enginesByRoom['target-a']!;
      final engineB = enginesByRoom['target-b']!;

      expect(await controller.setEnabled('bilibili:target-a', false), isTrue);

      expect(engineA.stopCount, 1);
      expect(engineB.stopCount, 0);
      expect(targetState('target-a').status, MirrorDanmakuStatus.disabled);
      expect(targetState('target-b').status, MirrorDanmakuStatus.connected);

      engineA.emit(mirrorChat(message: 'disabled late'));
      expect(host.chats, isEmpty);

      expect(await controller.setEnabled('bilibili:target-a', true), isTrue);

      expect(engines, hasLength(3));
      expect(targetState('target-a').status, MirrorDanmakuStatus.connected);
      expect(targetState('target-b').status, MirrorDanmakuStatus.connected);
      expect(engineB.stopCount, 0);
    });

    test('停用写盘失败时保持原状态并提示保存失败', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a')]);
      await controller.attachHost(hostRoom);
      final engine = enginesByRoom['target-a']!;

      failWrites = true;
      final disabled = await controller.setEnabled('bilibili:target-a', false);

      expect(disabled, isFalse);
      expect(engine.stopCount, 0);
      expect(targetState('target-a').status, MirrorDanmakuStatus.connected);
      expect(targetState('target-a').isEnabled, isTrue);
      expect(controller.state.value.message, i18n('mirror_danmaku_save_failed'));
    });

    test('删除单个目标只断开该目标并写回剩余列表；删除最后一个清空存储', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a'), configFor('target-b')]);
      await controller.attachHost(hostRoom);
      final engineA = enginesByRoom['target-a']!;
      final engineB = enginesByRoom['target-b']!;

      expect(await controller.removeTarget('bilibili:target-a'), isTrue);

      expect(engineA.stopCount, 1);
      expect(engineB.stopCount, 0);
      expect(controller.state.value.count, 1);
      expect(targetState('target-b').status, MirrorDanmakuStatus.connected);
      expect(store.readAll(hostRoom).map((config) => config.identityKey), <String>['bilibili:target-b']);

      expect(await controller.removeTarget('bilibili:target-b'), isTrue);

      expect(engineB.stopCount, 1);
      expect(controller.state.value.isEmpty, isTrue);
      expect(storage, isEmpty);
    });

    test('删除写盘失败时目标仍保留且会话不停止', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a'), configFor('target-b')]);
      await controller.attachHost(hostRoom);
      final engineA = enginesByRoom['target-a']!;

      failWrites = true;
      final removed = await controller.removeTarget('bilibili:target-a');

      expect(removed, isFalse);
      expect(engineA.stopCount, 0);
      expect(controller.state.value.count, 2);
      expect(controller.state.value.message, i18n('mirror_danmaku_remove_failed'));
    });

    test('添加写盘失败不报告已添加，也不启动新会话', () async {
      await controller.attachHost(hostRoom);
      final preview = await controller.preview('target-b');

      failWrites = true;
      final added = await controller.addAndApply(configFor('target-b'), resolved: preview);

      expect(added, isFalse);
      expect(controller.state.value.isEmpty, isTrue);
      expect(engines, isEmpty);
      expect(controller.state.value.message, i18n('mirror_danmaku_save_failed'));
    });

    test('回放、轮播和录制房间不自动解析或连接目标', () async {
      final rooms = <LiveRoom>[
        LiveRoom(platform: 'bilibili', roomId: 'replay-room', liveStatus: LiveStatus.replay),
        LiveRoom(platform: 'bilibili', roomId: 'carousel-room', liveStatus: LiveStatus.carousel),
        LiveRoom(platform: 'bilibili', roomId: 'record-room', liveStatus: LiveStatus.live, isRecord: true),
      ];

      for (final room in rooms) {
        host.hostIdentity = room.identityKey;
        storage[store.keyFor(room)] = jsonEncode(<String, Object?>{
          'version': MirrorDanmakuStore.payloadVersion,
          'targets': <Map<String, Object?>>[configFor('target-a').toJson()],
        });

        await controller.attachHost(room);

        expect(controller.state.value.count, 1, reason: room.roomId);
        expect(targetState('target-a').status, MirrorDanmakuStatus.idle, reason: room.roomId);
        expect(lookups, 0, reason: room.roomId);
        expect(engines, isEmpty, reason: room.roomId);
      }
    });

    test('A 从直播变为回放后断开所有已连接目标，旧消息也不再进入 A', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a'), configFor('target-b')]);
      await controller.attachHost(hostRoom);
      final engineA = enginesByRoom['target-a']!;
      final engineB = enginesByRoom['target-b']!;

      final replayHost = LiveRoom(
        platform: 'bilibili',
        roomId: 'host-room',
        liveStatus: LiveStatus.replay,
        danmakuData: 'args',
      );
      host.hostIdentity = replayHost.identityKey;
      await controller.attachHost(replayHost);

      expect(engineA.stopCount, 1);
      expect(engineB.stopCount, 1);
      expect(targetState('target-a').status, MirrorDanmakuStatus.idle);
      expect(targetState('target-b').status, MirrorDanmakuStatus.idle);

      engineA.emit(mirrorChat(message: 'late from replay boundary'));
      expect(host.chats, isEmpty);
    });

    test('关闭全局弹幕后断开全部目标，重新打开后恢复全部', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a'), configFor('target-b')]);
      await controller.attachHost(hostRoom);
      final firstEngines = List<FakeMirrorDanmakuEngine>.of(engines);

      hideDanmaku.value = true;
      await pumpEventQueue(times: 30);

      expect(firstEngines.every((engine) => engine.stopCount == 1), isTrue);
      expect(targetState('target-a').status, MirrorDanmakuStatus.idle);
      expect(targetState('target-b').status, MirrorDanmakuStatus.idle);

      hideDanmaku.value = false;
      await pumpEventQueue(times: 50);

      expect(engines, hasLength(4));
      expect(targetState('target-a').status, MirrorDanmakuStatus.connected);
      expect(targetState('target-b').status, MirrorDanmakuStatus.connected);
    });

    test('交给应用小窗时关闭路由不停止任何目标；小窗释放后才停止', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a'), configFor('target-b')]);
      await controller.attachHost(hostRoom);
      final runningEngines = List<FakeMirrorDanmakuEngine>.of(engines);
      host.keepsMirrorDanmakuForFloating = true;

      controller.onClose();
      await pumpEventQueue();

      expect(runningEngines.every((engine) => engine.stopCount == 0), isTrue);

      host.keepsMirrorDanmakuForFloating = false;
      await controller.dispose();

      expect(runningEngines.every((engine) => engine.stopCount == 1), isTrue);
    });

    test('普通关闭路由释放全部目标', () async {
      persistTargets(<MirrorDanmakuConfig>[configFor('target-a'), configFor('target-b')]);
      await controller.attachHost(hostRoom);
      final runningEngines = List<FakeMirrorDanmakuEngine>.of(engines);

      controller.onClose();
      await pumpEventQueue(times: 30);

      expect(runningEngines.every((engine) => engine.stopCount == 1), isTrue);
    });
  });
}
