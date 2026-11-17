import 'dart:convert';

import 'package:pure_live/core/logging/core_log.dart';
import 'package:pure_live/core/models/live_room.dart';
import 'package:pure_live/core/storage/hive_pref_util.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_config.dart';

typedef MirrorDanmakuStringReader = String? Function(String key);
typedef MirrorDanmakuStringWriter = Future<bool> Function(String key, String value);
typedef MirrorDanmakuStringRemover = Future<bool> Function(String key);

/// Persists at most one mirror target per host room.
///
/// The host's [LiveRoom.identityKey] is part of the storage key, so opening a
/// third room can neither read nor delete another room's mirror target.
class MirrorDanmakuStore {
  MirrorDanmakuStore({
    MirrorDanmakuStringReader? read,
    MirrorDanmakuStringWriter? write,
    MirrorDanmakuStringRemover? remove,
  }) : _read = read ?? HivePrefUtil.getString,
       _write = write ?? HivePrefUtil.setString,
       _remove = remove ?? HivePrefUtil.remove;

  static const String keyPrefix = 'mirror_danmaku_v1:';

  final MirrorDanmakuStringReader _read;
  final MirrorDanmakuStringWriter _write;
  final MirrorDanmakuStringRemover _remove;

  String keyFor(LiveRoom host) => '$keyPrefix${host.identityKey}';

  MirrorDanmakuConfig? read(LiveRoom host) {
    final raw = _read(keyFor(host));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return MirrorDanmakuConfig.fromJson(jsonDecode(raw));
    } catch (error, stackTrace) {
      CoreLog.e('MirrorDanmakuStore: invalid config for ${host.identityKey}', stackTrace);
      return null;
    }
  }

  Future<bool> write(LiveRoom host, MirrorDanmakuConfig config) async {
    try {
      return await _write(keyFor(host), jsonEncode(config.toJson()));
    } catch (error, stackTrace) {
      CoreLog.e('MirrorDanmakuStore: write failed for ${host.identityKey}', stackTrace);
      return false;
    }
  }

  Future<bool> remove(LiveRoom host) async {
    try {
      return await _remove(keyFor(host));
    } catch (error, stackTrace) {
      CoreLog.e('MirrorDanmakuStore: remove failed for ${host.identityKey}', stackTrace);
      return false;
    }
  }
}
