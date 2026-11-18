import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:pure_live/core/models/live_message.dart';
import 'package:pure_live/core/network/web_socket_util.dart';
import 'package:pure_live/shared/platforms/live_danmaku.dart';
import 'package:pure_live/shared/platforms/kick/kick_api.dart';
import 'package:pure_live/shared/platforms/kick/kick_link.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef KickChatFrame = ({bool connected, bool subscribed, bool ping, bool error, LiveMessage? message});

/// Read-only public chatroom subscription over Kick's Centrifugo gateway.
///
/// The channel's numeric ID is not its chatroom ID; the latter is resolved from
/// the current channel response. A guest client ID is minted per session and
/// exchanged for a short-lived JWT before every WebSocket connect.
class KickDanmaku extends LiveDanmaku {
  KickDanmaku({KickApi? api, WebSocketConnector? connector, String Function()? clientId})
    : _api = api ?? KickApi(),
      _connector = connector ?? _connectSocket,
      _newClientId = clientId ?? _uuidV4 {
    heartbeatTime = 30000;
  }

  static WebSocketChannel _connectSocket(
    String endpoint, {
    Duration? connectTimeout,
    Iterable<String>? protocols,
    Map<String, dynamic>? headers,
    io.HttpClient? customClient,
  }) => IOWebSocketChannel.connect(
    endpoint,
    connectTimeout: connectTimeout,
    protocols: protocols,
    headers: headers,
    customClient: customClient,
  );

  static final Random _random = Random.secure();

  static String _uuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  final KickApi _api;
  final WebSocketConnector _connector;
  final String Function() _newClientId;
  WebScoketUtils? _socket;
  Timer? _subscriptionTimer;
  int _generation = 0;
  int _requestId = 0;
  String? _pendingToken;

  @override
  Future<void> start(dynamic args) async {
    final slug = args is String ? KickLink.normalize(args) : null;
    if (slug == null) throw const KickException(KickFailure.identity);
    final generation = ++_generation;
    final previous = _socket;
    _socket = null;
    _subscriptionTimer?.cancel();
    _subscriptionTimer = null;
    _pendingToken = null;
    markDisconnected();
    await previous?.close();
    if (generation != _generation) return;
    final chatroomId = await _api.chatroomId(slug);
    if (generation != _generation) return;
    final clientId = _newClientId();
    final endpoint = await _api.chatConnection(chatroomId: chatroomId, clientId: clientId);
    if (generation != _generation) return;
    final token = await _api.chatToken(clientId: clientId);
    if (generation != _generation) return;
    _pendingToken = token;
    final socket = WebScoketUtils(
      url: endpoint.toString(),
      heartBeatTime: heartbeatTime,
      connector: _connector,
      onReady: () {
        final current = _socket;
        if (current != null) unawaited(_handshake(current, generation, chatroomId, clientId));
      },
      onMessage: (raw) {
        if (generation != _generation) return;
        final frame = parseFrame(raw, chatroomId);
        if (frame.ping) {
          _socket?.sendMessage('{}');
          return;
        }
        if (frame.error) {
          markDisconnected();
          _socket?.reconnect();
          return;
        }
        if (frame.connected) {
          _socket?.sendMessage(
            jsonEncode({
              'subscribe': {'channel': 'chatrooms.$chatroomId.v2', 'flag': 1},
              'id': ++_requestId,
            }),
          );
          return;
        }
        if (frame.subscribed) {
          _subscriptionTimer?.cancel();
          _subscriptionTimer = null;
          markConnected();
          onReady?.call();
          return;
        }
        if (isConnected && frame.message != null) onMessage?.call(frame.message!);
      },
      onReconnect: () {
        _subscriptionTimer?.cancel();
        _subscriptionTimer = null;
        markDisconnected();
        onReconnect?.call('Kick chat reconnecting');
      },
      onClose: (message) {
        _subscriptionTimer?.cancel();
        _subscriptionTimer = null;
        markDisconnected();
        onClose?.call('Kick chat connection failed: $message');
      },
    );
    _socket = socket;
    await socket.connect();
  }

  Future<void> _handshake(WebScoketUtils socket, int generation, int chatroomId, String clientId) async {
    markDisconnected();
    _subscriptionTimer?.cancel();
    _subscriptionTimer = null;
    var token = _pendingToken;
    _pendingToken = null;
    if (token == null) {
      try {
        token = await _api.chatToken(clientId: clientId);
      } catch (_) {
        if (generation == _generation && identical(socket, _socket)) socket.reconnect();
        return;
      }
    }
    if (generation != _generation || !identical(socket, _socket)) return;
    _requestId = 0;
    socket.sendMessage(
      jsonEncode({
        'connect': {'token': token, 'name': 'js'},
        'id': ++_requestId,
      }),
    );
    _subscriptionTimer = Timer(const Duration(seconds: 10), () {
      if (generation == _generation && !isConnected) socket.reconnect();
    });
  }

  @override
  Future<void> stop() async {
    ++_generation;
    _subscriptionTimer?.cancel();
    _subscriptionTimer = null;
    _pendingToken = null;
    final socket = _socket;
    _socket = null;
    markDisconnected();
    onMessage = null;
    onReady = null;
    onReconnect = null;
    onClose = null;
    await socket?.close();
  }

  static final _emoteCode = RegExp(r'\[emote:\d+:([^\]\s]+)\]');

  static KickChatFrame parseFrame(Object? raw, int chatroomId) {
    const ignored = (connected: false, subscribed: false, ping: false, error: false, message: null);
    if (raw is! String || raw.length > 128 * 1024) return ignored;
    final text = raw.trim();
    // Centrifugo's keepalive ping/pong frames are an empty JSON object.
    if (text == '{}') return (connected: false, subscribed: false, ping: true, error: false, message: null);
    try {
      final envelope = _object(jsonDecode(text));
      if (envelope == null) return ignored;
      if (envelope['error'] != null) {
        return (connected: false, subscribed: false, ping: false, error: true, message: null);
      }
      if (envelope['connect'] != null) {
        return (connected: true, subscribed: false, ping: false, error: false, message: null);
      }
      if (envelope['subscribe'] != null) {
        return (connected: false, subscribed: true, ping: false, error: false, message: null);
      }
      final push = _object(envelope['push']);
      if (push == null) return ignored;
      if (push['disconnect'] != null) {
        return (connected: false, subscribed: false, ping: false, error: true, message: null);
      }
      if (push['channel'] != 'chatrooms.$chatroomId.v2') return ignored;
      final event = _object(_object(push['pub'])?['data']);
      if (event == null) return ignored;
      if (event['event'] != r'App\Events\ChatMessageEvent' && event['event'] != r'App\Events\ChatMessageSentEvent') {
        return ignored;
      }
      final data = event['data'];
      final payload = _object(data is String ? jsonDecode(data) : data);
      if (payload == null) return ignored;
      final legacy = _object(payload['message']);
      final message = legacy ?? payload;
      final sender = _object(payload['sender']) ?? _object(payload['user']);
      if (sender == null) return ignored;
      final room = message['chatroom_id'];
      if (room != null && int.tryParse(room.toString()) != chatroomId) return ignored;
      final type = message['type'];
      if (type != null && type != '' && type != 'message' && type != 'reply') return ignored;
      // Kick sends emotes inline as [emote:<id>:<name>]; show the name.
      final content = ((legacy == null ? message['content'] : message['message'])?.toString() ?? '')
          .replaceAllMapped(_emoteCode, (match) => match.group(1)!)
          .trim();
      final userName = sender['username']?.toString().trim() ?? '';
      if (content.isEmpty || content.length > 16000 || userName.isEmpty || userName.length > 256) return ignored;
      final identity = _object(sender['identity']);
      final colorText = identity?['color']?.toString().replaceFirst('#', '') ?? '';
      final color = int.tryParse(colorText, radix: 16);
      final stamp = message['created_at'];
      final sentAt = stamp is int
          ? DateTime.fromMillisecondsSinceEpoch(stamp * 1000)
          : stamp is String
          ? DateTime.tryParse(stamp)
          : null;
      return (
        connected: false,
        subscribed: false,
        ping: false,
        error: false,
        message: LiveMessage(
          type: LiveMessageType.chat,
          userName: userName,
          userId: sender['id']?.toString() ?? '',
          message: content,
          messageId: message['id']?.toString() ?? '',
          sentAt: sentAt,
          color: color == null ? LiveMessageColor.white : LiveMessageColor.numberToColor(color),
        ),
      );
    } catch (_) {
      return ignored;
    }
  }

  static Map<String, dynamic>? _object(Object? value) {
    if (value is! Map) return null;
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
}
