import 'dart:async';

import 'package:pure_live/core/index.dart';
import 'package:pure_live/domains/live/presentation/playback/controllers/mirror_danmaku_host.dart';
import 'package:pure_live/shared/platforms/live_danmaku.dart';

class FakeMirrorDanmakuEngine extends LiveDanmaku {
  FakeMirrorDanmakuEngine({this.startError});

  final Object? startError;
  final List<Object?> startedArgs = <Object?>[];
  int startCount = 0;
  int stopCount = 0;
  Completer<void>? startGate;
  Completer<void>? stopGate;

  @override
  Future<void> start(dynamic args) async {
    startCount++;
    startedArgs.add(args);
    final gate = startGate;
    if (gate != null) await gate.future;
    final error = startError;
    if (error != null) throw error;
    markConnected();
    onReady?.call();
  }

  @override
  Future<void> stop() async {
    stopCount++;
    final gate = stopGate;
    if (gate != null) await gate.future;
    markDisconnected();
  }

  void emit(LiveMessage message) => onMessage?.call(message);

  void reconnect(String reason) => onReconnect?.call(reason);

  void terminal(String reason) => onClose?.call(reason);
}

class FakeMirrorDanmakuHost implements MirrorDanmakuHost {
  FakeMirrorDanmakuHost({required this.hostIdentity});

  @override
  String hostIdentity;

  @override
  bool isHostCurrent = true;

  @override
  bool keepsMirrorDanmakuForFloating = false;

  final List<LiveMessage> chats = <LiveMessage>[];
  final List<String> systemMessages = <String>[];

  @override
  void applyMirrorChat(LiveMessage message) => chats.add(message);

  @override
  void addMirrorSystemMessage(String text) => systemMessages.add(text);
}

LiveMessage mirrorChat({
  String userName = 'B user',
  String message = 'hello',
  String userId = 'b-user',
  String messageId = 'm-1',
  List<LiveEmote> emotes = const <LiveEmote>[],
}) {
  return LiveMessage(
    type: LiveMessageType.chat,
    userName: userName,
    userId: userId,
    message: message,
    messageId: messageId,
    color: LiveMessageColor.white,
    emotes: emotes,
  );
}
