import 'dart:async';

import 'package:dio/dio.dart' as dio;
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/models/live_room.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_resolver.dart';

void main() {
  final host = LiveRoom(platform: 'bilibili', roomId: 'host-room');

  LiveRoom target({
    String platform = 'bilibili',
    String roomId = 'target-room',
    LiveStatus status = LiveStatus.live,
    Object? danmakuData = 'args',
  }) {
    return LiveRoom(
      platform: platform,
      roomId: roomId,
      liveStatus: status,
      danmakuData: danmakuData,
      nick: 'B 主播',
      title: 'B 标题',
    );
  }

  group('镜像弹幕地址解析', () {
    test('正常链接解析出 B 平台和房间号，并要求重新获取详情', () async {
      String? seenPlatform;
      String? seenRoomId;
      final resolver = MirrorDanmakuResolver(
        linkParser: (_, _) async => <String>[' 123 ', ' BILIBILI '],
        detailLoader: (platform, roomId) async {
          seenPlatform = platform;
          seenRoomId = roomId;
          return target(platform: platform, roomId: roomId);
        },
      );

      final result = await resolver.resolve(input: 'https://live.bilibili.com/123', host: host);

      expect(result.isSuccess, isTrue);
      expect(result.canConnect, isTrue);
      expect(result.room?.identityKey, 'bilibili:123');
      expect(seenPlatform, 'bilibili');
      expect(seenRoomId, '123');
    });

    test('空输入、无法识别、平台不支持、指向自己都在请求详情前拒绝', () async {
      var lookups = 0;
      Future<LiveRoom> loader(String platform, String roomId) async {
        lookups++;
        return target(platform: platform, roomId: roomId);
      }

      Future<MirrorDanmakuResolveResult> run(String input, List<String> parsed) {
        return MirrorDanmakuResolver(
          linkParser: (_, _) async => parsed,
          detailLoader: loader,
        ).resolve(input: input, host: host);
      }

      expect((await run('', <String>['1', 'bilibili'])).failure, MirrorDanmakuResolveFailure.emptyInput);
      expect((await run('nope', <String>[])).failure, MirrorDanmakuResolveFailure.invalidLink);
      expect((await run('iptv', <String>['1', 'iptv'])).failure, MirrorDanmakuResolveFailure.unsupportedPlatform);
      expect((await run('self', <String>['host-room', 'bilibili'])).failure, MirrorDanmakuResolveFailure.sameAsHost);
      expect(lookups, 0);
    });

    test('B 未开播仍返回可保存的房间，但不允许建立连接', () async {
      final resolver = MirrorDanmakuResolver(
        linkParser: (_, _) async => <String>['offline-room', 'bilibili'],
        detailLoader: (platform, roomId) async =>
            target(platform: platform, roomId: roomId, status: LiveStatus.offline),
      );

      final result = await resolver.resolve(input: 'offline', host: host);

      expect(result.isSuccess, isTrue);
      expect(result.canConnect, isFalse);
      expect(result.room?.identityKey, 'bilibili:offline-room');
    });

    test('B 没有可用弹幕参数时拒绝', () async {
      final resolver = MirrorDanmakuResolver(
        linkParser: (_, _) async => <String>['empty-room', 'bilibili'],
        detailLoader: (platform, roomId) async => target(platform: platform, roomId: roomId, danmakuData: null),
      );

      final result = await resolver.resolve(input: 'empty', host: host);

      expect(result.failure, MirrorDanmakuResolveFailure.danmakuUnavailable);
    });

    test('详情请求失败返回明确失败而不是可保存状态', () async {
      final resolver = MirrorDanmakuResolver(
        linkParser: (_, _) async => <String>['broken', 'bilibili'],
        detailLoader: (_, _) async => throw StateError('boom'),
      );

      final result = await resolver.resolve(input: 'broken', host: host);

      expect(result.failure, MirrorDanmakuResolveFailure.detailFailed);
    });

    test('详情请求超时', () async {
      final resolver = MirrorDanmakuResolver(
        linkParser: (_, _) async => <String>['slow', 'bilibili'],
        detailLoader: (_, _) => Completer<LiveRoom>().future,
        timeout: const Duration(milliseconds: 20),
      );

      final result = await resolver.resolve(input: 'slow', host: host);

      expect(result.failure, MirrorDanmakuResolveFailure.timeout);
    });

    test('取消解析返回 cancelled，不等待底层请求结束', () async {
      final cancelToken = dio.CancelToken();
      final resolver = MirrorDanmakuResolver(
        linkParser: (_, _) => Completer<List<String>>().future,
        timeout: const Duration(seconds: 1),
      );

      final pending = resolver.resolve(input: 'pending', host: host, cancelToken: cancelToken);
      cancelToken.cancel();

      expect((await pending).failure, MirrorDanmakuResolveFailure.cancelled);
    });

    test('已知身份的重试路径也做平台、自己和弹幕源校验', () async {
      final resolver = MirrorDanmakuResolver(
        detailLoader: (platform, roomId) async => target(platform: platform, roomId: roomId),
      );

      expect(
        (await resolver.resolveRoom(
          host: host,
          candidate: LiveRoom(platform: 'iptv', roomId: '1'),
        )).failure,
        MirrorDanmakuResolveFailure.unsupportedPlatform,
      );
      expect(
        (await resolver.resolveRoom(
          host: host,
          candidate: LiveRoom(platform: 'bilibili', roomId: 'host-room'),
        )).failure,
        MirrorDanmakuResolveFailure.sameAsHost,
      );
      final success = await resolver.resolveRoom(
        host: host,
        candidate: LiveRoom(platform: 'bilibili', roomId: 'next'),
      );
      expect(success.isSuccess, isTrue);
      expect(success.canConnect, isTrue);
    });
  });
}
