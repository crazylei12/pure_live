import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/models/live_room.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_config.dart';

void main() {
  group('镜像弹幕配置', () {
    test('序列化只保留房间身份和展示字段，不含解析后的传输参数', () {
      const config = MirrorDanmakuConfig(
        platform: 'bilibili',
        roomId: '123',
        sourceUrl: 'https://live.bilibili.com/123',
        nick: '主播',
        title: '标题',
        enabled: false,
      );

      final json = config.toJson();

      expect(json['version'], MirrorDanmakuConfig.currentVersion);
      expect(json['platform'], 'bilibili');
      expect(json['roomId'], '123');
      expect(json['sourceUrl'], 'https://live.bilibili.com/123');
      expect(json['enabled'], isFalse);
      expect(json.keys, isNot(contains('danmakuData')));
      expect(json.keys, isNot(contains('token')));
      expect(json.keys, isNot(contains('cookie')));
    });

    test('合法 JSON 往返后归一化平台和房间号', () {
      final config = MirrorDanmakuConfig.fromJson(<String, Object?>{
        'version': 1,
        'platform': ' BILIBILI ',
        'roomId': ' 123 ',
        'sourceUrl': ' https://example.invalid/room ',
        'nick': ' 主播 ',
        'title': ' 标题 ',
        'enabled': false,
      });

      expect(config, isNotNull);
      expect(config!.platform, 'bilibili');
      expect(config.roomId, '123');
      expect(config.sourceUrl, 'https://example.invalid/room');
      expect(config.nick, '主播');
      expect(config.title, '标题');
      expect(config.enabled, isFalse);
    });

    test('版本不符、缺少身份或非对象输入都拒绝', () {
      expect(MirrorDanmakuConfig.fromJson(null), isNull);
      expect(
        MirrorDanmakuConfig.fromJson(<String, Object?>{'version': 2, 'platform': 'bilibili', 'roomId': '1'}),
        isNull,
      );
      expect(MirrorDanmakuConfig.fromJson(<String, Object?>{'version': 1, 'platform': '', 'roomId': '1'}), isNull);
      expect(MirrorDanmakuConfig.fromJson(<String, Object?>{'version': 1, 'platform': 'bilibili'}), isNull);
      expect(MirrorDanmakuConfig.fromJson('not a map'), isNull);
    });

    test('自己房间判断按归一化身份比较，不受大小写和空白影响', () {
      const config = MirrorDanmakuConfig(platform: ' BILIBILI ', roomId: ' 123 ');
      final host = LiveRoom(platform: 'bilibili', roomId: '123');

      expect(config.matchesHost(host), isTrue);
      expect(config.copyWith(roomId: '124').matchesHost(host), isFalse);
    });
  });
}
