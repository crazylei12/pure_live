import 'package:pure_live/core/models/live_message.dart';

/// Room surface required by [MirrorDanmakuController].
///
/// The mirror session belongs to one host room and must never write into a
/// different room's history, renderer or floating layer.
abstract interface class MirrorDanmakuHost {
  String get hostIdentity;

  bool get isHostCurrent;

  bool get keepsMirrorDanmakuForFloating;

  void applyMirrorChat(LiveMessage message);

  void addMirrorSystemMessage(String text);
}
