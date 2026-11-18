import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/models/live_room.dart';
import 'package:pure_live/domains/live/data/platforms/sites.dart';
import 'package:pure_live/domains/live/presentation/multiview/danmaku/multiview_danmaku_session.dart';
import 'package:pure_live/shared/platforms/kick/kick_api.dart';
import 'package:pure_live/shared/platforms/kick/kick_danmaku.dart';
import 'package:pure_live/shared/platforms/kick/kick_site.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _clientId = '11111111-2222-4333-8444-555555555555';
const _token = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJndWVzdDoxMTExIn0.c2lnbmF0dXJl';
const _socketUrl = 'wss://realtime.us-east-1.platform.kick.com/connection/websocket';

void main() {
  test('Kick chatroom ID is resolved from the channel response, not channel ID', () async {
    final calls = <Uri>[];
    final api = KickApi(
      request: (uri, _) async {
        calls.add(uri);
        return (
          status: 200,
          body: jsonEncode({
            'slug': 'fixture',
            'id': 676,
            'chatroom': {'id': 668},
          }),
        );
      },
    );
    expect(await api.chatroomId('fixture'), 668);
    expect(calls.single.path, '/api/v2/channels/fixture');
    expect(KickSite(api: api).getDanmaku(), isA<KickDanmaku>());
    if (Sites.supportedSiteIds.contains(Sites.kickSite)) {
      expect(MultiviewDanmakuSession.isSupportedPlatform('kick'), isTrue);
    } else {
      expect(MultiviewDanmakuSession.isSupportedPlatform('kick'), isFalse);
    }
  });

  test('Kick room detail carries its chat identity into the playback session', () async {
    final api = KickApi(
      request: (_, _) async => (
        status: 200,
        body: jsonEncode({
          'id': 676,
          'slug': 'fixture',
          'user': {'username': 'fixture'},
          'livestream': null,
        }),
      ),
    );
    final room = await KickSite(api: api).getRoomDetailForRefresh(LiveRoom(roomId: 'fixture', platform: 'kick'));
    expect(room.danmakuData, 'fixture');
    expect(room.liveStatus, LiveStatus.offline);
  });

  test('Kick realtime connection selects the centrifugo endpoint and rejects unsafe URLs', () async {
    KickApi apiWith(Object? url, {String provider = 'centrifugo'}) => KickApi(
      post: (_, _, _) async => (
        status: 200,
        body: jsonEncode({
          'data': {
            'connections': [
              {
                'provider': provider,
                'credentials': {'url': url},
              },
            ],
            'mode': 'websocket',
          },
        }),
      ),
    );
    final connection = await apiWith(_socketUrl).chatConnection(chatroomId: 668, clientId: _clientId);
    expect(connection.toString(), _socketUrl);
    for (final url in [
      'wss://evil.example/connection/websocket',
      'https://realtime.us-east-1.platform.kick.com/connection/websocket',
      'wss://realtime.us-east-1.platform.kick.com/other',
      'wss://realtime.us-east-1.platform.kick.com/connection/websocket?token=x',
      'wss://realtime.us-east-1.platform.kick.com:8443/connection/websocket',
    ]) {
      await expectLater(
        apiWith(url).chatConnection(chatroomId: 668, clientId: _clientId),
        throwsA(isA<KickException>()),
      );
    }
    await expectLater(
      apiWith(_socketUrl, provider: 'pusher').chatConnection(chatroomId: 668, clientId: _clientId),
      throwsA(isA<KickException>()),
    );
  });

  test('Kick realtime guest token must be a JWT', () async {
    KickApi apiWith(Object? token) => KickApi(
      post: (_, _, _) async => (
        status: 200,
        body: jsonEncode({
          'data': {'token': token},
        }),
      ),
    );
    expect(await apiWith(_token).chatToken(clientId: _clientId), _token);
    for (final token in ['', 'guest-token', 'eyJhbGciOiJIUzI1NiJ9.not-a-jwt']) {
      await expectLater(apiWith(token).chatToken(clientId: _clientId), throwsA(isA<KickException>()));
    }
  });

  test('Kick engine handshakes, delivers chat and releases socket', () async {
    final posts = <String>[];
    final api = KickApi(
      request: (_, _) async => (
        status: 200,
        body: jsonEncode({
          'slug': 'fixture',
          'chatroom': {'id': 668},
        }),
      ),
      post: (uri, body, _) async {
        posts.add(uri.path);
        if (uri.path.endsWith('/chat/connection')) {
          expect(uri.host, 'web.kick.com');
          expect(body['client'], {'id': _clientId, 'type': 'web'});
          return (
            status: 200,
            body: jsonEncode({
              'data': {
                'connections': [
                  {
                    'provider': 'centrifugo',
                    'credentials': {'url': _socketUrl},
                  },
                ],
                'mode': 'websocket',
              },
            }),
          );
        }
        expect(uri.path, '/api/v1/realtime/auth/connection');
        expect(body, {'client_id': _clientId});
        return (
          status: 200,
          body: jsonEncode({
            'data': {'token': _token},
          }),
        );
      },
    );
    final socket = _FakeChannel();
    final engine = KickDanmaku(
      api: api,
      clientId: () => _clientId,
      connector: (endpoint, {connectTimeout, protocols, headers, customClient}) {
        expect(endpoint, _socketUrl);
        return socket;
      },
    );
    var ready = 0;
    final messages = <String>[];
    engine.onReady = () => ready++;
    engine.onMessage = (message) => messages.add(message.message);
    await engine.start('fixture');
    expect(engine.isConnected, isFalse);
    final connect = jsonDecode(socket.sent.single) as Map<String, dynamic>;
    expect(connect['connect'], {'token': _token, 'name': 'js'});
    expect(connect['id'], 1);
    socket.incoming.add(
      jsonEncode({
        'id': 1,
        'connect': {
          'client': 'server-client',
          'version': '6.9.7 PRO',
          'expires': true,
          'ttl': 2699,
          'ping': 25,
          'pong': true,
        },
      }),
    );
    await Future<void>.delayed(Duration.zero);
    final subscribe = jsonDecode(socket.sent.last) as Map<String, dynamic>;
    expect(subscribe['subscribe'], {'channel': 'chatrooms.668.v2', 'flag': 1});
    expect(subscribe['id'], 2);
    socket.incoming.add(jsonEncode({'id': 2, 'subscribe': {}}));
    await Future<void>.delayed(Duration.zero);
    expect(engine.isConnected, isTrue);
    expect(ready, 1);
    socket.incoming.add('{}');
    await Future<void>.delayed(Duration.zero);
    expect(socket.sent.last, '{}');
    socket.incoming.add(
      jsonEncode({
        'push': {
          'channel': 'chatrooms.668.v2',
          'pub': {
            'data': {
              'event': r'App\Events\ChatMessageEvent',
              'data': jsonEncode({
                'id': 'msg-1',
                'chatroom_id': 668,
                'content': 'hello',
                'type': 'message',
                'sender': {'id': 1, 'username': 'viewer'},
              }),
            },
          },
        },
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(messages, ['hello']);
    expect(posts, ['/api/v1/realtime/channels/668/chat/connection', '/api/v1/realtime/auth/connection']);
    await engine.stop();
    expect(engine.isConnected, isFalse);
    expect(socket.closed, isTrue);
  });

  test('Kick missing or mismatched chatroom identity fails rather than guessing', () async {
    for (final body in [
      {
        'slug': 'other',
        'chatroom': {'id': 668},
      },
      {'slug': 'fixture', 'id': 676},
      {
        'slug': 'fixture',
        'chatroom': {'id': 0},
      },
    ]) {
      final api = KickApi(request: (_, _) async => (status: 200, body: jsonEncode(body)));
      await expectLater(api.chatroomId('fixture'), throwsA(isA<KickException>()));
    }
  });

  test('Centrifugo handshake, ping and chat push are scoped to chatroom', () {
    expect(KickDanmaku.parseFrame('{}', 668).ping, isTrue);
    expect(KickDanmaku.parseFrame(jsonEncode({'id': 1, 'connect': {}}), 668).connected, isTrue);
    expect(KickDanmaku.parseFrame(jsonEncode({'id': 2, 'subscribe': {}}), 668).subscribed, isTrue);
    expect(
      KickDanmaku.parseFrame(
        jsonEncode({
          'id': 2,
          'error': {'code': 1},
        }),
        668,
      ).error,
      isTrue,
    );
    expect(
      KickDanmaku.parseFrame(
        jsonEncode({
          'push': {
            'disconnect': {'code': 3005},
          },
        }),
        668,
      ).error,
      isTrue,
    );

    final message = {
      'id': 'abc-123',
      'chatroom_id': 668,
      'content': 'hello world',
      'type': 'message',
      'created_at': '2025-01-01T00:00:00Z',
      'sender': {
        'id': 9999,
        'username': 'hello_kiko',
        'identity': {'color': '#FF0000', 'badges': []},
      },
    };
    String frame(String channel) => jsonEncode({
      'push': {
        'channel': channel,
        'pub': {
          'data': {'event': r'App\Events\ChatMessageEvent', 'data': jsonEncode(message)},
        },
      },
    });
    final parsed = KickDanmaku.parseFrame(frame('chatrooms.668.v2'), 668).message;
    expect(parsed?.messageId, 'abc-123');
    expect(parsed?.userName, 'hello_kiko');
    expect(parsed?.userId, '9999');
    expect(parsed?.message, 'hello world');
    expect(parsed?.color.toString(), '#ff0000');
    expect(parsed?.sentAt?.toUtc().toIso8601String(), '2025-01-01T00:00:00.000Z');
    expect(KickDanmaku.parseFrame(frame('chatrooms.676.v2'), 668).message, isNull);
    message['chatroom_id'] = 676;
    expect(KickDanmaku.parseFrame(frame('chatrooms.668.v2'), 668).message, isNull);
  });

  test('legacy chat shape, malformed payload and non-chat events stay isolated', () {
    final legacy = KickDanmaku.parseFrame(
      jsonEncode({
        'push': {
          'channel': 'chatrooms.668.v2',
          'pub': {
            'data': {
              'event': r'App\Events\ChatMessageSentEvent',
              'data': jsonEncode({
                'message': {'id': 'old-1', 'message': 'legacy', 'chatroom_id': '668', 'created_at': 1677379978},
                'user': {'id': 21, 'username': 'viewer'},
              }),
            },
          },
        },
      }),
      668,
    );
    expect(legacy.message?.message, 'legacy');
    expect(legacy.message?.messageId, 'old-1');
    expect(legacy.message?.sentAt?.year, 2023);
    expect(KickDanmaku.parseFrame('{bad json', 668).message, isNull);
    expect(
      KickDanmaku.parseFrame(
        jsonEncode({
          'push': {
            'channel': 'chatrooms.668.v2',
            'pub': {
              'data': {'event': 'Other', 'data': '{}'},
            },
          },
        }),
        668,
      ).message,
      isNull,
    );
  });

  test('emote codes render as their emote names', () {
    // Production chat carries emotes as [emote:<id>:<name>]; the raw codes
    // flooded the danmaku list and scrolling overlay.
    final data = {
      'id': 'e-1',
      'chatroom_id': 668,
      'content': '[emote:37226:KEKW] lol [emote:37243:gachiGASM]',
      'type': 'message',
      'sender': {'id': 1, 'username': 'viewer'},
    };
    final parsed = KickDanmaku.parseFrame(
      jsonEncode({
        'push': {
          'channel': 'chatrooms.668.v2',
          'pub': {
            'data': {'event': r'App\Events\ChatMessageEvent', 'data': jsonEncode(data)},
          },
        },
      }),
      668,
    ).message;
    expect(parsed?.message, 'KEKW lol gachiGASM');
  });
}

class _FakeChannel implements WebSocketChannel {
  final StreamController<dynamic> incoming = StreamController<dynamic>();
  final List<String> sent = [];
  bool closed = false;
  late final WebSocketSink _sink = _FakeSink(sent, () => closed = true);

  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  WebSocketSink get sink => _sink;
  @override
  Future<void> get ready => Future<void>.value();
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
  @override
  String? get protocol => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this.sent, this.onClose);
  final List<String> sent;
  final void Function() onClose;
  @override
  void add(dynamic data) => sent.add(data as String);
  @override
  Future<void> close([int? closeCode, String? closeReason]) async => onClose();
  @override
  Future<void> get done => Future<void>.value();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
