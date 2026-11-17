import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flame_barrage/flame_barrage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/index.dart';
import 'package:pure_live/core/network/http_client.dart';
import 'package:pure_live/domains/live/presentation/playback/services/mirror_danmaku_session.dart';

import 'mirror_danmaku_fakes.dart';

/// A valid 1x1 PNG: enough for the emote loader to register an atlas entry if
/// a session ever calls it again.
final Uint8List _pixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

final class _PngAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      _pixelPng,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final room = LiveRoom(platform: 'bilibili', roomId: 'target-room', liveStatus: LiveStatus.live, danmakuData: 'args');

  late FakeMirrorDanmakuEngine engine;
  late List<LiveMessage> messages;
  late List<String> terminals;
  late MirrorDanmakuSession session;

  MirrorDanmakuSession buildSession({
    MirrorDanmakuFilterPolicy policy = const MirrorDanmakuFilterPolicy(),
    Duration startTimeout = const Duration(seconds: 5),
    Duration stopTimeout = const Duration(seconds: 5),
  }) {
    return MirrorDanmakuSession(
      engineFactory: (_) => engine,
      filterPolicyProvider: () => policy,
      onChatMessage: messages.add,
      onReady: () {},
      onTerminalError: terminals.add,
      startTimeout: startTimeout,
      stopTimeout: stopTimeout,
    );
  }

  setUp(() {
    engine = FakeMirrorDanmakuEngine();
    messages = <LiveMessage>[];
    terminals = <String>[];
    session = buildSession();
  });

  group('镜像弹幕会话', () {
    test('只转发聊天，不把礼物、在线人数、SC、通知或撤回送进 A 房间', () async {
      await session.connect(room);
      final chat = mirrorChat();
      engine.emit(chat);
      for (final type in <LiveMessageType>[
        LiveMessageType.gift,
        LiveMessageType.online,
        LiveMessageType.superChat,
        LiveMessageType.notice,
        LiveMessageType.retraction,
      ]) {
        engine.emit(LiveMessage(type: type, userName: 'B user', message: 'ignored', color: LiveMessageColor.white));
      }

      expect(messages, hasLength(1));
      expect(messages.single, same(chat));
      expect(session.isConnected, isTrue);
    });

    test('屏蔽用户和关键词在进入 A 房间前生效', () async {
      session = buildSession(
        policy: const MirrorDanmakuFilterPolicy(
          blockedUsers: <String>{'blocked-user'},
          blockedKeywords: <String>['spoiler'],
        ),
      );
      await session.connect(room);

      engine.emit(mirrorChat(userName: 'Blocked-User', message: 'hello', messageId: 'm-blocked'));
      engine.emit(mirrorChat(userName: 'normal', message: 'this is a SPOILER', messageId: 'm-spoiler'));
      engine.emit(mirrorChat(userName: 'normal', message: 'clean', messageId: 'm-clean'));

      expect(messages, hasLength(1));
      expect(messages.single.message, 'clean');
    });

    test('重复弹幕折叠开启时只保留第一条', () async {
      session = buildSession(policy: const MirrorDanmakuFilterPolicy(collapseRepeated: true, repeatedWindowSeconds: 8));
      await session.connect(room);

      engine.emit(mirrorChat(message: 'same text', messageId: 'm-1'));
      engine.emit(mirrorChat(message: 'same text', messageId: 'm-2'));

      expect(messages, hasLength(1));
    });

    test('聊天表情留在消息上供侧栏渲染，不写入全局 atlas 覆盖 A 平台同 code 表情', () async {
      const code = '[mirror-atlas-probe]';
      const emotes = <LiveEmote>[LiveEmote(code: code, url: 'https://example.invalid/mirror-atlas-probe.png')];
      final previousAdapter = HttpClient.instance.dio.httpClientAdapter;
      HttpClient.instance.dio.httpClientAdapter = _PngAdapter();
      addTearDown(() {
        HttpClient.instance.dio.httpClientAdapter = previousAdapter;
        EmojiAtlas.instance.clear();
      });
      expect(EmojiAtlas.instance.find(code), isNull);

      await session.connect(room);
      engine.emit(mirrorChat(message: 'hello $code', emotes: emotes));
      engine.emit(
        LiveMessage(
          type: LiveMessageType.gift,
          userName: 'B user',
          message: 'gift',
          color: LiveMessageColor.white,
          emotes: emotes,
        ),
      );
      await pumpEventQueue(times: 50);

      expect(EmojiAtlas.instance.find(code), isNull);
      expect(messages, hasLength(1));
      expect(messages.single.emotes.single.code, code);
    });

    test('启动失败报告终端错误并释放引擎', () async {
      engine = FakeMirrorDanmakuEngine(startError: StateError('start failed'));
      session = buildSession();
      await session.connect(room);

      expect(terminals, hasLength(1));
      expect(terminals.single, contains('start failed'));
      expect(engine.stopCount, 1);
      expect(session.isConnected, isFalse);
    });

    test('启动超时报告终端错误，不会留下半连接会话', () async {
      engine = FakeMirrorDanmakuEngine()..startGate = Completer<void>();
      session = buildSession(startTimeout: const Duration(milliseconds: 20));
      await session.connect(room);

      expect(terminals, hasLength(1));
      expect(session.isConnected, isFalse);
      expect(engine.stopCount, 1);
    });

    test('断开后旧引擎的回调失效', () async {
      await session.connect(room);
      final staleMessage = engine.onMessage!;
      final oldEngine = engine;
      await session.disconnect();

      engine = FakeMirrorDanmakuEngine();
      session = buildSession();
      await session.connect(room);
      staleMessage(mirrorChat(message: 'late from old engine'));

      expect(oldEngine.stopCount, 1);
      expect(messages, isEmpty);
    });

    test('引擎主动关闭后清空会话并上报终端错误', () async {
      await session.connect(room);
      engine.terminal('socket closed');
      await pumpEventQueue();

      expect(terminals, contains('socket closed'));
      expect(session.isConnected, isFalse);
      expect(engine.stopCount, 1);
    });

    test('停止超时仍让 disconnect 完成', () async {
      engine = FakeMirrorDanmakuEngine()..stopGate = Completer<void>();
      session = buildSession(stopTimeout: const Duration(milliseconds: 20));
      await session.connect(room);

      await session.disconnect().timeout(const Duration(seconds: 1));

      expect(engine.stopCount, 1);
      expect(session.isConnected, isFalse);
    });

    test('没有可用弹幕参数的房间在连接前被拒绝', () async {
      final unsupported = LiveRoom(platform: 'bilibili', roomId: 'empty', liveStatus: LiveStatus.live);
      await session.connect(unsupported);

      expect(terminals, contains('unsupported'));
      expect(engine.startCount, 0);
    });
  });
}
