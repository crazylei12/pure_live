import 'dart:async';
import 'dart:developer' as developer;

import 'package:media_core_danmaku/media_core_danmaku.dart';
import 'package:pure_live/core/index.dart';
import 'package:pure_live/core/player/core/live_message_normalization.dart';
import 'package:pure_live/domains/live/data/favorite_room_controller.dart';
import 'package:pure_live/domains/live/data/platforms/sites.dart';
import 'package:pure_live/shared/platforms/huya/huya_danmaku.dart' show HuyaDanmakuArgs;
import 'package:pure_live/shared/platforms/live_danmaku.dart';

typedef MirrorDanmakuEngineFactory = LiveDanmaku Function(LiveRoom room);

class MirrorDanmakuFilterPolicy {
  const MirrorDanmakuFilterPolicy({
    this.blockedUsers = const <String>{},
    this.blockedKeywords = const <String>[],
    this.collapseRepeated = false,
    this.repeatedWindowSeconds = 8,
    this.similarityEnabled = false,
    this.similarityThreshold = 85,
    this.similarityCacheSeconds = 30,
    this.similarityMaxCacheSize = 256,
  });

  final Set<String> blockedUsers;
  final List<String> blockedKeywords;
  final bool collapseRepeated;
  final int repeatedWindowSeconds;
  final bool similarityEnabled;
  final int similarityThreshold;
  final int similarityCacheSeconds;
  final int similarityMaxCacheSize;

  factory MirrorDanmakuFilterPolicy.fromAppState() {
    final favorite = FavoriteRoomController.to;
    final danmaku = SettingsService.to.danmaku;
    return MirrorDanmakuFilterPolicy(
      blockedUsers: favorite.blockedDanmakuUsers.map((user) => user.trim().toLowerCase()).toSet(),
      blockedKeywords: favorite.shieldList
          .map((keyword) => keyword.trim().toLowerCase())
          .where((keyword) => keyword.isNotEmpty)
          .toList(growable: false),
      collapseRepeated: danmaku.collapseRepeatedDanmaku.v,
      repeatedWindowSeconds: danmaku.repeatedDanmakuWindowSeconds.v,
      similarityEnabled: danmaku.enableDanmakuSimilarityFilter.v,
      similarityThreshold: danmaku.danmakuSimilarityThreshold.v,
      similarityCacheSeconds: danmaku.danmakuSimilarityCacheDuration.v,
      similarityMaxCacheSize: danmaku.danmakuSimilarityMaxCacheSize.v,
    );
  }
}

typedef MirrorDanmakuFilterPolicyProvider = MirrorDanmakuFilterPolicy Function();

/// A second, room-bound danmaku transport owned by one A room.
///
/// It deliberately does not reuse DanmakuController: that controller's token,
/// renderer and status messages belong to A. This session forwards chat only and
/// every callback is fenced by both its epoch and the engine instance.
class MirrorDanmakuSession {
  MirrorDanmakuSession({
    MirrorDanmakuEngineFactory? engineFactory,
    this.filterPolicyProvider = MirrorDanmakuFilterPolicy.fromAppState,
    this.onChatMessage,
    this.onReady,
    this.onReconnect,
    this.onTerminalError,
    this.startTimeout = const Duration(seconds: 20),
    this.stopTimeout = const Duration(seconds: 5),
  }) : engineFactory = engineFactory ?? _defaultEngineFactory;

  final MirrorDanmakuEngineFactory engineFactory;
  final MirrorDanmakuFilterPolicyProvider filterPolicyProvider;
  final void Function(LiveMessage message)? onChatMessage;
  final void Function()? onReady;
  final void Function(String reason)? onReconnect;
  final void Function(String reason)? onTerminalError;
  final Duration startTimeout;
  final Duration stopTimeout;

  static LiveDanmaku _defaultEngineFactory(LiveRoom room) {
    return Sites.of(room.normalizedPlatformId).liveSite.getDanmaku();
  }

  final DanmakuMessageGate _messageGate = DanmakuMessageGate();
  final DanmakuRepeatedFilter _repeatedFilter = DanmakuRepeatedFilter();
  final DanmakuSimilarityFilter _similarityFilter = DanmakuSimilarityFilter();

  LiveDanmaku? _engine;
  int _epoch = 0;
  String? _sessionKey;
  Future<void> _tail = Future<void>.value();

  String? get sessionKey => _sessionKey;

  bool get isConnected => _engine?.isConnected ?? false;

  static final RegExp _maskedName = RegExp(r'\*{2,}|＊{2,}');

  static bool supportsRoom(LiveRoom liveroom) {
    if (!Sites.supportsDanmakuTransport(liveroom.platform)) return false;
    final data = liveroom.danmakuData;
    if (data == null) return false;
    if (data is String && data.trim().isEmpty) return false;
    if (data is HuyaDanmakuArgs && data.topSid <= 0) return false;
    return true;
  }

  Future<void> connect(LiveRoom liveroom) {
    final key = '${liveroom.normalizedPlatformId}:${liveroom.normalizedRoomId}';
    if (_sessionKey == key && isConnected) return Future<void>.value();
    final request = ++_epoch;
    return _serialize(() async {
      if (request != _epoch) return;
      if (_sessionKey == key && isConnected) return;
      if (!supportsRoom(liveroom)) {
        onTerminalError?.call('unsupported');
        return;
      }

      await _disconnectInternal();
      if (request != _epoch) return;

      final engine = engineFactory(liveroom);
      _engine = engine;
      _installCallbacks(engine, key, request);
      try {
        await engine.start(liveroom.danmakuData).timeout(startTimeout);
      } catch (error, stackTrace) {
        developer.log(
          'MirrorDanmakuSession: connect failed for $key',
          name: 'MirrorDanmakuSession',
          error: error,
          stackTrace: stackTrace,
        );
        if (request == _epoch) {
          _sessionKey = null;
          _detachCallbacks(engine);
          onTerminalError?.call(error.toString());
        }
        await _stopEngineQuietly(engine);
        if (identical(_engine, engine)) _engine = null;
        return;
      }
      if (request == _epoch) {
        _sessionKey = key;
      } else {
        await _stopEngineQuietly(engine);
        if (identical(_engine, engine)) _engine = null;
      }
    });
  }

  Future<void> disconnect() {
    final request = ++_epoch;
    return _serialize(() async {
      if (request != _epoch) return;
      await _disconnectInternal();
    });
  }

  Future<void> _disconnectInternal() async {
    _sessionKey = null;
    final engine = _engine;
    _engine = null;
    _messageGate.clear();
    _repeatedFilter.clear();
    _similarityFilter.clear();
    if (engine == null) return;
    _detachCallbacks(engine);
    await _stopEngineQuietly(engine);
  }

  void _installCallbacks(LiveDanmaku engine, String key, int token) {
    engine.onMessage = (message) {
      if (token != _epoch || !identical(_engine, engine)) return;
      try {
        _handleMessage(message);
      } catch (error, stackTrace) {
        developer.log(
          'MirrorDanmakuSession: message handling failed',
          name: 'MirrorDanmakuSession',
          error: error,
          stackTrace: stackTrace,
        );
      }
    };

    engine.onReady = () {
      if (token != _epoch || !identical(_engine, engine)) return;
      _sessionKey = key;
      onReady?.call();
    };

    engine.onReconnect = (reason) {
      if (token != _epoch || !identical(_engine, engine)) return;
      onReconnect?.call(reason);
    };

    engine.onClose = (reason) {
      if (token != _epoch || !identical(_engine, engine)) return;
      _sessionKey = null;
      _engine = null;
      _detachCallbacks(engine);
      unawaited(_stopEngineQuietly(engine));
      onTerminalError?.call(reason);
    };
  }

  void _handleMessage(LiveMessage message) {
    if (message.type != LiveMessageType.chat) return;
    if (!_messageGate.accepts(normalizeLiveMessage(message))) return;

    final policy = filterPolicyProvider();
    final user = message.userName.trim().toLowerCase();
    if (user.isNotEmpty && !_maskedName.hasMatch(user) && policy.blockedUsers.contains(user)) return;
    final text = message.message.toLowerCase();
    if (policy.blockedKeywords.any(text.contains)) return;

    if (!_repeatedFilter.accepts(
      normalizeLiveMessage(message),
      enabled: policy.collapseRepeated,
      window: Duration(seconds: policy.repeatedWindowSeconds.clamp(1, 30)),
    )) {
      return;
    }

    if (!policy.similarityEnabled) {
      _similarityFilter.clear();
    } else {
      _similarityFilter.updateConfig(
        similarityThreshold: policy.similarityThreshold,
        cacheDuration: Duration(seconds: policy.similarityCacheSeconds),
        maxCacheSize: policy.similarityMaxCacheSize,
      );
      if (!message.isLocal && !_similarityFilter.shouldDisplay(message.message)) return;
    }

    // B's emotes stay on the forwarded message: the chat list resolves them
    // from `message.emotes` (code -> URL). EmojiAtlas is process-global and
    // keyed by emote code only, so registering B's network images here would
    // overwrite A's same-code platform images in the side list, the video
    // danmaku surface and the floating window.
    onChatMessage?.call(message);
  }

  Future<void> _stopEngineQuietly(LiveDanmaku engine) async {
    try {
      await engine.stop().timeout(stopTimeout);
    } catch (error, stackTrace) {
      developer.log(
        'MirrorDanmakuSession: engine stop failed',
        name: 'MirrorDanmakuSession',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _detachCallbacks(LiveDanmaku engine) {
    engine.onMessage = null;
    engine.onReady = null;
    engine.onReconnect = null;
    engine.onClose = null;
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.catchError((Object error, StackTrace stackTrace) {
      developer.log(
        'MirrorDanmakuSession: serialized operation failed',
        name: 'MirrorDanmakuSession',
        error: error,
        stackTrace: stackTrace,
      );
    });
    return next;
  }
}
