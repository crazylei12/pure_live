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

    test('每个 A 房间只读写自己的 B 配置，打开 C 房间不会误读或误删', () async {
      final store = MirrorDanmakuStore();
      final a = LiveRoom(platform: 'bilibili', roomId: '1');
      final c = LiveRoom(platform: 'douyu', roomId: '2');
      const config = MirrorDanmakuConfig(
        platform: 'huya',
        roomId: '333',
        sourceUrl: 'https://www.huya.com/333',
        nick: '主播',
        title: '标题',
      );

      expect(await store.write(a, config), isTrue);
      expect(store.read(a)?.identityKey, 'huya:333');
      expect(store.read(c), isNull);

      expect(await store.remove(c), isTrue);
      expect(store.read(a)?.identityKey, 'huya:333');

      expect(await store.remove(a), isTrue);
      expect(store.read(a), isNull);
    });

    test('损坏的 JSON 当作未配置，不向调用方抛出', () async {
      final store = MirrorDanmakuStore();
      final host = LiveRoom(platform: 'bilibili', roomId: '1');
      await HivePrefUtil.setString(store.keyFor(host), '{not-json');

      expect(store.read(host), isNull);
    });

    test('写入失败返回 false，读取仍是空配置', () async {
      final store = MirrorDanmakuStore(read: (_) => null, write: (_, _) async => false, remove: (_) async => true);
      final host = LiveRoom(platform: 'bilibili', roomId: '1');

      expect(await store.write(host, const MirrorDanmakuConfig(platform: 'huya', roomId: '333')), isFalse);
      expect(store.read(host), isNull);
    });

    test('删除失败返回 false，原配置不受影响', () async {
      var stored = '{"version":1,"platform":"huya","roomId":"333"}';
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
      expect(store.read(host)?.identityKey, 'huya:333');
    });
  });
}
