import 'dart:async';

import 'package:dio/dio.dart' as dio;
import 'package:pure_live/core/models/live_room.dart';
import 'package:pure_live/domains/live/data/link/live_url_tool.dart';
import 'package:pure_live/domains/live/data/platforms/sites.dart';
import 'package:pure_live/shared/platforms/huya/huya_danmaku.dart' show HuyaDanmakuArgs;

typedef MirrorDanmakuLinkParser = Future<List<String>> Function(String input, dio.CancelToken? cancelToken);
typedef MirrorDanmakuDetailLoader = Future<LiveRoom> Function(String platform, String roomId);

enum MirrorDanmakuResolveFailure {
  emptyInput,
  invalidLink,
  unsupportedPlatform,
  sameAsHost,
  detailFailed,
  danmakuUnavailable,
  timeout,
  cancelled,
}

class MirrorDanmakuResolveResult {
  const MirrorDanmakuResolveResult._({this.room, this.failure, this.canConnect = false, this.cause});

  factory MirrorDanmakuResolveResult.success({required LiveRoom room, required bool canConnect}) {
    return MirrorDanmakuResolveResult._(room: room, canConnect: canConnect);
  }

  factory MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure failure, {Object? cause}) {
    return MirrorDanmakuResolveResult._(failure: failure, cause: cause);
  }

  final LiveRoom? room;
  final MirrorDanmakuResolveFailure? failure;
  final bool canConnect;
  final Object? cause;

  bool get isSuccess => room != null;
}

/// Resolves the B-room input without owning the A room's playback.
///
/// The parser and detail loader are injectable so deterministic tests never
/// need a live platform. Validation mirrors the multiview transport contract:
/// unsupported platforms, the host room itself, and a live room without usable
/// danmaku arguments are rejected before a session can be opened.
class MirrorDanmakuResolver {
  MirrorDanmakuResolver({
    MirrorDanmakuLinkParser? linkParser,
    MirrorDanmakuDetailLoader? detailLoader,
    this.timeout = const Duration(seconds: 15),
  }) : _linkParser = linkParser ?? _defaultLinkParser,
       _detailLoader = detailLoader ?? _defaultDetailLoader;

  final MirrorDanmakuLinkParser _linkParser;
  final MirrorDanmakuDetailLoader _detailLoader;
  final Duration timeout;

  static Future<List<String>> _defaultLinkParser(String input, dio.CancelToken? cancelToken) {
    return LiveUrlTool.parseLiveUrl(input, cancelToken: cancelToken);
  }

  static Future<LiveRoom> _defaultDetailLoader(String platform, String roomId) {
    return Sites.of(platform).liveSite.getRoomDetail(LiveRoom(roomId: roomId, platform: platform));
  }

  Future<MirrorDanmakuResolveResult> resolve({
    required String input,
    required LiveRoom host,
    dio.CancelToken? cancelToken,
  }) async {
    final text = input.trim();
    if (text.isEmpty) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.emptyInput);
    }
    if (cancelToken?.isCancelled ?? false) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.cancelled);
    }

    try {
      final parsed = await _guard(_linkParser(text, cancelToken), cancelToken).timeout(timeout);
      if (cancelToken?.isCancelled ?? false) {
        return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.cancelled);
      }
      if (parsed.length < 2) {
        return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.invalidLink);
      }
      final platform = parsed[1].trim().toLowerCase();
      final roomId = parsed[0].trim();
      if (platform.isEmpty || roomId.isEmpty) {
        return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.invalidLink);
      }
      if (!Sites.supportsDanmakuTransport(platform)) {
        return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.unsupportedPlatform);
      }
      if (host.identityKey == '$platform:$roomId') {
        return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.sameAsHost);
      }
      return await resolveRoom(
        host: host,
        candidate: LiveRoom(roomId: roomId, platform: platform),
        cancelToken: cancelToken,
      );
    } on TimeoutException catch (error) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.timeout, cause: error);
    } on _MirrorDanmakuCancelled catch (error) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.cancelled, cause: error);
    } catch (error) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.invalidLink, cause: error);
    }
  }

  /// Revalidates a known identity, used by retry and by opening an existing
  /// saved target after the app restarted.
  Future<MirrorDanmakuResolveResult> resolveRoom({
    required LiveRoom host,
    required LiveRoom candidate,
    dio.CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.cancelled);
    }
    final platform = candidate.normalizedPlatformId;
    final roomId = candidate.normalizedRoomId;
    if (platform.isEmpty || roomId.isEmpty) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.invalidLink);
    }
    if (!Sites.supportsDanmakuTransport(platform)) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.unsupportedPlatform);
    }
    if (host.identityKey == '$platform:$roomId') {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.sameAsHost);
    }

    try {
      final detail = await _guard(_detailLoader(platform, roomId), cancelToken).timeout(timeout);
      if (cancelToken?.isCancelled ?? false) {
        return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.cancelled);
      }
      final resolved = detail.copyWith(platform: platform, roomId: roomId);
      if (resolved.identityKey == host.identityKey) {
        return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.sameAsHost);
      }
      if (!resolved.isLiveNow) {
        // Offline/banned/unknown targets stay configurable so the user can
        // retry manually later, but they never open a transport now.
        return MirrorDanmakuResolveResult.success(room: resolved, canConnect: false);
      }
      if (!_hasUsableDanmakuData(resolved.danmakuData)) {
        return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.danmakuUnavailable);
      }
      return MirrorDanmakuResolveResult.success(room: resolved, canConnect: true);
    } on TimeoutException catch (error) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.timeout, cause: error);
    } on _MirrorDanmakuCancelled catch (error) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.cancelled, cause: error);
    } catch (error) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.detailFailed, cause: error);
    }
  }

  static bool _hasUsableDanmakuData(dynamic data) {
    if (data == null) return false;
    if (data is String) return data.trim().isNotEmpty;
    if (data is HuyaDanmakuArgs) return data.topSid > 0;
    return true;
  }

  static Future<T> _guard<T>(Future<T> operation, dio.CancelToken? cancelToken) {
    if (cancelToken == null) return operation;
    final cancelled = Completer<T>();
    cancelToken.whenCancel.then((_) {
      if (!cancelled.isCompleted) {
        cancelled.completeError(const _MirrorDanmakuCancelled());
      }
    });
    return Future.any<T>([operation, cancelled.future]);
  }
}

class _MirrorDanmakuCancelled implements Exception {
  const _MirrorDanmakuCancelled();
}
