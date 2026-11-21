import 'dart:convert';

import 'package:pure_live/core/logging/core_log.dart';
import 'package:pure_live/core/models/live_room.dart';
import 'package:pure_live/core/storage/hive_pref_util.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_config.dart';

typedef MirrorDanmakuStringReader = String? Function(String key);
typedef MirrorDanmakuStringWriter = Future<bool> Function(String key, String value);
typedef MirrorDanmakuStringRemover = Future<bool> Function(String key);

/// Persists the ordered mirror-target list for one host room.
///
/// Writes use a versioned list payload. A target saved by the earlier
/// single-target version is still readable and is migrated on the next
/// successful write. The host's [LiveRoom.identityKey] is part of both keys, so
/// opening a third room can neither read nor delete another room's targets.
class MirrorDanmakuStore {
  MirrorDanmakuStore({
    MirrorDanmakuStringReader? read,
    MirrorDanmakuStringWriter? write,
    MirrorDanmakuStringRemover? remove,
  }) : _read = read ?? HivePrefUtil.getString,
       _write = write ?? HivePrefUtil.setString,
       _remove = remove ?? HivePrefUtil.remove;

  static const String keyPrefix = 'mirror_danmaku_v2:';
  static const String legacyKeyPrefix = 'mirror_danmaku_v1:';
  static const int payloadVersion = 2;

  final MirrorDanmakuStringReader _read;
  final MirrorDanmakuStringWriter _write;
  final MirrorDanmakuStringRemover _remove;

  String keyFor(LiveRoom host) => '$keyPrefix${host.identityKey}';

  String legacyKeyFor(LiveRoom host) => '$legacyKeyPrefix${host.identityKey}';

  List<MirrorDanmakuConfig> readAll(LiveRoom host) {
    final raw = _read(keyFor(host));
    if (raw != null && raw.trim().isNotEmpty) {
      return _decodeList(raw, host);
    }
    return _readLegacy(host);
  }

  List<MirrorDanmakuConfig> _readLegacy(LiveRoom host) {
    final raw = _read(legacyKeyFor(host));
    if (raw == null || raw.trim().isEmpty) return const <MirrorDanmakuConfig>[];
    try {
      final config = MirrorDanmakuConfig.fromJson(jsonDecode(raw));
      if (config == null || config.matchesHost(host)) return const <MirrorDanmakuConfig>[];
      return <MirrorDanmakuConfig>[config];
    } catch (error, stackTrace) {
      CoreLog.e('MirrorDanmakuStore: invalid legacy config for ${host.identityKey}', stackTrace);
      return const <MirrorDanmakuConfig>[];
    }
  }

  List<MirrorDanmakuConfig> _decodeList(String raw, LiveRoom host) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        CoreLog.e('MirrorDanmakuStore: invalid list payload for ${host.identityKey}', StackTrace.current);
        return const <MirrorDanmakuConfig>[];
      }
      final version = decoded['version'];
      if (version is! num || version.toInt() != payloadVersion) {
        CoreLog.e('MirrorDanmakuStore: unsupported list version for ${host.identityKey}', StackTrace.current);
        return const <MirrorDanmakuConfig>[];
      }
      final rawTargets = decoded['targets'];
      if (rawTargets is! List) {
        CoreLog.e('MirrorDanmakuStore: list payload has no targets for ${host.identityKey}', StackTrace.current);
        return const <MirrorDanmakuConfig>[];
      }
      final seen = <String>{};
      final targets = <MirrorDanmakuConfig>[];
      for (final item in rawTargets) {
        final config = MirrorDanmakuConfig.fromJson(item);
        if (config == null || config.matchesHost(host)) continue;
        if (!seen.add(config.identityKey)) continue;
        targets.add(config);
      }
      return targets;
    } catch (error, stackTrace) {
      CoreLog.e('MirrorDanmakuStore: invalid config list for ${host.identityKey}', stackTrace);
      return const <MirrorDanmakuConfig>[];
    }
  }

  Future<bool> writeAll(LiveRoom host, List<MirrorDanmakuConfig> configs) async {
    if (configs.isEmpty) return remove(host);
    final payload = jsonEncode(<String, dynamic>{
      'version': payloadVersion,
      'targets': <Map<String, dynamic>>[for (final config in configs) config.toJson()],
    });
    try {
      final written = await _write(keyFor(host), payload);
      if (!written) return false;
    } catch (error, stackTrace) {
      CoreLog.e('MirrorDanmakuStore: list write failed for ${host.identityKey}', stackTrace);
      return false;
    }
    try {
      // Best-effort cleanup: the list payload is already authoritative, so a
      // stale legacy key must not turn a successful write into a failure.
      await _remove(legacyKeyFor(host));
    } catch (error, stackTrace) {
      CoreLog.e('MirrorDanmakuStore: legacy cleanup failed for ${host.identityKey}', stackTrace);
    }
    return true;
  }

  Future<bool> remove(LiveRoom host) async {
    var removed = true;
    for (final key in <String>[keyFor(host), legacyKeyFor(host)]) {
      try {
        if (!await _remove(key)) removed = false;
      } catch (error, stackTrace) {
        CoreLog.e('MirrorDanmakuStore: remove failed for ${host.identityKey}', stackTrace);
        removed = false;
      }
    }
    return removed;
  }
}
