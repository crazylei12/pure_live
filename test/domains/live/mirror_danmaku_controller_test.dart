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
  final otherRoom = LiveRoom(platform: 'douyu', roomId: 'other-room', liveStatus: LiveStatus.live);

  late FakeMirrorDanmakuHost host;
  late Map<String, String> storage;
  late bool failWrites;
  late bool targetLive;
  late int lookups;
  late MirrorDanmakuStore store;
  late MirrorDanmakuResolver resolver;
  late List<FakeMirrorDanmakuEngine> engines;
  late RxBool hideDanmaku;
  late MirrorDanmakuController controller;

  LiveRoom targetRoom() {
    return LiveRoom(
      platform: 'bilibili',
      roomId: 'target-room',
      liveStatus: targetLive ? LiveStatus.live : LiveStatus.offline,
      danmakuData: 'args',
      nick: 'B 主播',
      title: 'B 标题',
    );
  }

  void persistTarget({bool enabled = true}) {
    storage[store.keyFor(hostRoom)] = jsonEncode(
      MirrorDanmakuConfig(
        platform: 'bilibili',
        roomId: 'target-room',
        sourceUrl: 'https://live.bilibili.com/target-room',
        nick: 'B 主播',
        title: 'B 标题',
        enabled: enabled,
      ).toJson(),
    );
  }

  setUp(() {
    host = FakeMirrorDanmakuHost(hostIdentity: hostRoom.identityKey);
    storage = <String, String>{};
    failWrites = false;
    targetLive = true;
    lookups = 0;
    engines = <FakeMirrorDanmakuEngine>[];
    hideDanmaku = false.obs;
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
    resolver = MirrorDanmakuResolver(
      linkParser: (_, _) async => <String>['target-room', 'bilibili'],
      detailLoader: (_, _) async {
        lookups++;
        return targetRoom();
      },
      timeout: const Duration(milliseconds: 200),
    );
    controller = MirrorDanmakuController(
      host: host,
      store: store,
      resolver: resolver,
      engineFactory: (_) {
        final engine = FakeMirrorDanmakuEngine();
        engines.add(engine);
        return engine;
      },
      filterPolicyProvider: () => const MirrorDanmakuFilterPolicy(),
      hideDanmaku: hideDanmaku,
    );
  });

  tearDown(() async {
    await controller.dispose();
    hideDanmaku.close();
  });

  group('镜像弹幕控制器', () {
    test('进入有配置的 A 房间后解析并连接 B，B 聊天直达宿主', () async {
      persistTarget();

      await controller.attachHost(hostRoom);

      expect(lookups, 1);
      expect(engines, hasLength(1));
      expect(controller.state.value.status, MirrorDanmakuStatus.connected);
      expect(controller.state.value.target?.identityKey, 'bilibili:target-room');
      expect(host.systemMessages, isNotEmpty);

      final chat = mirrorChat();
      engines.single.emit(chat);

      expect(host.chats, hasLength(1));
      expect(host.chats.single, same(chat));
    });

    test('进入没有配置的 C 房间不继承 A 的 B', () async {
      persistTarget();
      await controller.attachHost(hostRoom);
      final oldEngine = engines.single;

      host.hostIdentity = otherRoom.identityKey;
      await controller.attachHost(otherRoom);

      expect(oldEngine.stopCount, 1);
      expect(controller.state.value.config, isNull);
      expect(controller.state.value.target, isNull);
      expect(storage.containsKey(store.keyFor(hostRoom)), isTrue);
    });

    test('A 切换后旧 B 消息即使穿过旧回调也被宿主身份拦截', () async {
      persistTarget();
      await controller.attachHost(hostRoom);
      final staleCallback = engines.single.onMessage!;

      host.hostIdentity = otherRoom.identityKey;
      await controller.attachHost(otherRoom);
      staleCallback(mirrorChat(message: 'late'));

      expect(host.chats, isEmpty);
    });

    test('宿主身份变化后当前 B 消息也不再进入 A', () async {
      persistTarget();
      await controller.attachHost(hostRoom);
      final engine = engines.single;

      host.hostIdentity = 'bilibili:another-room';
      engine.emit(mirrorChat());

      expect(host.chats, isEmpty);
    });

    test('B 未开播只保存状态，不创建引擎；重试恢复后连接', () async {
      targetLive = false;
      persistTarget();

      await controller.attachHost(hostRoom);

      expect(engines, isEmpty);
      expect(controller.state.value.status, MirrorDanmakuStatus.offline);

      targetLive = true;
      await controller.retry();

      expect(engines, hasLength(1));
      expect(controller.state.value.status, MirrorDanmakuStatus.connected);
    });

    test('重复 attach 同一宿主是幂等的，不重复解析或建连', () async {
      persistTarget();

      await controller.attachHost(hostRoom);
      await controller.attachHost(hostRoom);

      expect(lookups, 1);
      expect(engines, hasLength(1));
    });

    test('回放、轮播和录制房间不自动解析或连接 B', () async {
      final rooms = <LiveRoom>[
        LiveRoom(platform: 'bilibili', roomId: 'replay-room', liveStatus: LiveStatus.replay),
        LiveRoom(platform: 'bilibili', roomId: 'carousel-room', liveStatus: LiveStatus.carousel),
        LiveRoom(platform: 'bilibili', roomId: 'record-room', liveStatus: LiveStatus.live, isRecord: true),
      ];

      for (final room in rooms) {
        host.hostIdentity = room.identityKey;
        storage[store.keyFor(room)] = jsonEncode(const MirrorDanmakuConfig(platform: 'huya', roomId: '333').toJson());

        await controller.attachHost(room);

        expect(controller.state.value.config, isNotNull, reason: room.roomId);
        expect(controller.state.value.status, MirrorDanmakuStatus.idle, reason: room.roomId);
        expect(lookups, 0, reason: room.roomId);
        expect(engines, isEmpty, reason: room.roomId);
      }
    });

    test('A 从直播变为回放后断开已连接的 B，旧消息也不再进入 A', () async {
      persistTarget();
      await controller.attachHost(hostRoom);
      final engine = engines.single;
      expect(controller.state.value.status, MirrorDanmakuStatus.connected);

      final replayHost = LiveRoom(
        platform: 'bilibili',
        roomId: 'host-room',
        liveStatus: LiveStatus.replay,
        danmakuData: 'args',
      );
      host.hostIdentity = replayHost.identityKey;
      await controller.attachHost(replayHost);

      expect(engine.stopCount, 1);
      expect(controller.state.value.status, MirrorDanmakuStatus.idle);

      engine.emit(mirrorChat(message: 'late from replay boundary'));
      expect(host.chats, isEmpty);
    });

    test('停用会写回 enabled=false 并断开；删除会清空当前房间配置', () async {
      persistTarget();
      await controller.attachHost(hostRoom);
      final engine = engines.single;

      expect(await controller.disable(), isTrue);
      expect(engine.stopCount, 1);
      expect(controller.state.value.status, MirrorDanmakuStatus.disabled);
      expect(controller.state.value.config?.enabled, isFalse);

      expect(await controller.remove(), isTrue);
      expect(controller.state.value.config, isNull);
      expect(storage, isEmpty);
    });

    test('写入失败不报告已启用，也不启动 B', () async {
      failWrites = true;
      final preview = await controller.preview('link');
      await controller.attachHost(hostRoom);

      final saved = await controller.saveAndApply(
        const MirrorDanmakuConfig(platform: 'bilibili', roomId: 'target-room'),
        resolved: preview,
      );

      expect(saved, isFalse);
      expect(controller.state.value.config, isNull);
      expect(engines, isEmpty);
      expect(controller.state.value.message, isNotEmpty);
    });

    test('关闭全局弹幕后断开，重新打开后恢复', () async {
      persistTarget();
      await controller.attachHost(hostRoom);
      final firstEngine = engines.single;

      hideDanmaku.value = true;
      await pumpEventQueue(times: 20);

      expect(firstEngine.stopCount, 1);
      expect(controller.state.value.status, MirrorDanmakuStatus.idle);

      hideDanmaku.value = false;
      await pumpEventQueue(times: 50);

      expect(engines, hasLength(2));
      expect(controller.state.value.status, MirrorDanmakuStatus.connected);
    });

    test('交给应用小窗时关闭路由不停止 B；小窗释放后才停止', () async {
      persistTarget();
      await controller.attachHost(hostRoom);
      final engine = engines.single;
      host.keepsMirrorDanmakuForFloating = true;

      controller.onClose();
      await pumpEventQueue();

      expect(engine.stopCount, 0);

      host.keepsMirrorDanmakuForFloating = false;
      await controller.dispose();

      expect(engine.stopCount, 1);
    });

    test('普通关闭路由释放 B', () async {
      persistTarget();
      await controller.attachHost(hostRoom);
      final engine = engines.single;

      controller.onClose();
      await pumpEventQueue(times: 20);

      expect(engine.stopCount, 1);
    });
  });
}
