import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pure_live/core/models/live_room.dart';
import 'package:pure_live/core/storage/hive_pref_util.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_config.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_store.dart';

void main() {
  group('镜像弹幕存储', () {
    setUpAll(() async {
      await Hive.openBox<dynamic>('app_settings', bytes: Uint8List(0));
      await HivePrefUtil.init();
    });

    setUp(() async {
      await Hive.box<dynamic>('app_settings').clear();
    });

    tearDownAll(() async {
      await Hive.close();
    });

    test('每个 A 房间读写自己的目标列表，打开 C 房间不会误读或误删', () async {
      final store = MirrorDanmakuStore();
      final a = LiveRoom(platform: 'bilibili', roomId: '1');
      final c = LiveRoom(platform: 'douyu', roomId: '2');
      const first = MirrorDanmakuConfig(
        platform: 'huya',
        roomId: '333',
        sourceUrl: 'https://www.huya.com/333',
        nick: '主播',
        title: '标题',
      );
      const second = MirrorDanmakuConfig(platform: 'douyu', roomId: '444');

      expect(await store.writeAll(a, const <MirrorDanmakuConfig>[first, second]), isTrue);
      expect(store.readAll(a).map((config) => config.identityKey), <String>['huya:333', 'douyu:444']);
      expect(store.readAll(c), isEmpty);

      expect(await store.remove(c), isTrue);
      expect(store.readAll(a), hasLength(2));

      expect(await store.remove(a), isTrue);
      expect(store.readAll(a), isEmpty);
      expect(HivePrefUtil.getString(store.legacyKeyFor(a)), isNull);
    });

    test('旧版单目标配置可读取，并在下一次写入时迁移到列表键', () async {
      final store = MirrorDanmakuStore();
      final host = LiveRoom(platform: 'bilibili', roomId: 'host-room');
      const legacyConfig = MirrorDanmakuConfig(platform: 'huya', roomId: '333', enabled: false);
      await HivePrefUtil.setString(store.legacyKeyFor(host), jsonEncode(legacyConfig.toJson()));

      final migrated = store.readAll(host);
      expect(migrated, hasLength(1));
      expect(migrated.single.identityKey, 'huya:333');
      expect(migrated.single.enabled, isFalse);

      const current = MirrorDanmakuConfig(platform: 'douyu', roomId: '444');
      expect(await store.writeAll(host, const <MirrorDanmakuConfig>[current]), isTrue);
      expect(store.readAll(host).single.identityKey, 'douyu:444');
      expect(HivePrefUtil.getString(store.legacyKeyFor(host)), isNull);
    });

    test('列表键存在时优先使用列表，不因损坏回退到旧版配置', () async {
      final store = MirrorDanmakuStore();
      final host = LiveRoom(platform: 'bilibili', roomId: 'host-room');
      await HivePrefUtil.setString(
        store.legacyKeyFor(host),
        jsonEncode(const MirrorDanmakuConfig(platform: 'huya', roomId: '333').toJson()),
      );
      await HivePrefUtil.setString(store.keyFor(host), '{"version":99}');

      expect(store.readAll(host), isEmpty);
    });

    test('损坏的 JSON 当作未配置，不向调用方抛出', () async {
      final store = MirrorDanmakuStore();
      final host = LiveRoom(platform: 'bilibili', roomId: '1');
      await HivePrefUtil.setString(store.keyFor(host), '{not-json');

      expect(store.readAll(host), isEmpty);
    });

    test('读取列表时过滤自己的房间和重复目标', () {
      final storage = <String, String>{};
      final store = MirrorDanmakuStore(
        read: (key) => storage[key],
        write: (key, value) async {
          storage[key] = value;
          return true;
        },
        remove: (key) async {
          storage.remove(key);
          return true;
        },
      );
      final host = LiveRoom(platform: 'bilibili', roomId: '1');
      storage[store.keyFor(host)] = jsonEncode(<String, Object?>{
        'version': MirrorDanmakuStore.payloadVersion,
        'targets': <Map<String, Object?>>[
          const MirrorDanmakuConfig(platform: 'bilibili', roomId: '1').toJson(),
          const MirrorDanmakuConfig(platform: 'huya', roomId: '333').toJson(),
          const MirrorDanmakuConfig(platform: 'HUYA', roomId: '333').toJson(),
        ],
      });

      final targets = store.readAll(host);

      expect(targets, hasLength(1));
      expect(targets.single.identityKey, 'huya:333');
    });

    test('写入失败返回 false，读取仍是空列表', () async {
      final store = MirrorDanmakuStore(read: (_) => null, write: (_, _) async => false, remove: (_) async => true);
      final host = LiveRoom(platform: 'bilibili', roomId: '1');

      expect(
        await store.writeAll(host, const <MirrorDanmakuConfig>[MirrorDanmakuConfig(platform: 'huya', roomId: '333')]),
        isFalse,
      );
      expect(store.readAll(host), isEmpty);
    });

    test('删除失败返回 false，原配置不受影响', () async {
      var stored = jsonEncode(<String, Object?>{
        'version': MirrorDanmakuStore.payloadVersion,
        'targets': <Map<String, Object?>>[const MirrorDanmakuConfig(platform: 'huya', roomId: '333').toJson()],
      });
      final store = MirrorDanmakuStore(
        read: (_) => stored,
        write: (_, value) async {
          stored = value;
          return true;
        },
        remove: (_) async => false,
      );
      final host = LiveRoom(platform: 'bilibili', roomId: '1');

      expect(await store.remove(host), isFalse);
      expect(store.readAll(host).single.identityKey, 'huya:333');
    });
  });
}
