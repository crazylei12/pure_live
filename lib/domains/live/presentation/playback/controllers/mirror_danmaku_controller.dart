import 'dart:async';

import 'package:dio/dio.dart' as dio;
import 'package:pure_live/core/index.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_config.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_resolver.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_store.dart';
import 'package:pure_live/domains/live/data/platforms/sites.dart';
import 'package:pure_live/domains/live/presentation/playback/controllers/mirror_danmaku_host.dart';
import 'package:pure_live/domains/live/presentation/playback/services/mirror_danmaku_session.dart';

enum MirrorDanmakuStatus { idle, disabled, resolving, connecting, connected, offline, failed }

class MirrorDanmakuState {
  const MirrorDanmakuState({this.config, this.target, this.status = MirrorDanmakuStatus.idle, this.message});

  final MirrorDanmakuConfig? config;
  final LiveRoom? target;
  final MirrorDanmakuStatus status;
  final String? message;

  bool get hasConfig => config != null;

  bool get isBusy => status == MirrorDanmakuStatus.resolving || status == MirrorDanmakuStatus.connecting;

  bool get isConnected => status == MirrorDanmakuStatus.connected;

  MirrorDanmakuState copyWith({
    MirrorDanmakuConfig? config,
    bool clearConfig = false,
    LiveRoom? target,
    bool clearTarget = false,
    MirrorDanmakuStatus? status,
    String? message,
    bool clearMessage = false,
  }) {
    return MirrorDanmakuState(
      config: clearConfig ? null : (config ?? this.config),
      target: clearTarget ? null : (target ?? this.target),
      status: status ?? this.status,
      message: clearMessage ? null : (message ?? this.message),
    );
  }
}

String mirrorDanmakuResolveFailureText(MirrorDanmakuResolveFailure? failure) {
  return switch (failure) {
    MirrorDanmakuResolveFailure.emptyInput => i18n('mirror_danmaku_invalid_input'),
    MirrorDanmakuResolveFailure.invalidLink => i18n('mirror_danmaku_invalid_link'),
    MirrorDanmakuResolveFailure.unsupportedPlatform => i18n('mirror_danmaku_unsupported_platform'),
    MirrorDanmakuResolveFailure.sameAsHost => i18n('mirror_danmaku_same_room'),
    MirrorDanmakuResolveFailure.detailFailed => i18n('mirror_danmaku_detail_failed'),
    MirrorDanmakuResolveFailure.danmakuUnavailable => i18n('mirror_danmaku_danmaku_unavailable'),
    MirrorDanmakuResolveFailure.timeout => i18n('mirror_danmaku_timeout'),
    MirrorDanmakuResolveFailure.cancelled => i18n('mirror_danmaku_cancelled'),
    null => i18n('mirror_danmaku_status_failed'),
  };
}

/// Owns the second danmaku transport for one A room.
///
/// It is not a global singleton: every [LivePlayController] owns one instance,
/// and every asynchronous result is fenced by the attached host identity and
/// the current epoch before it can touch the room.
class MirrorDanmakuController {
  MirrorDanmakuController({
    required this.host,
    MirrorDanmakuStore? store,
    MirrorDanmakuResolver? resolver,
    MirrorDanmakuEngineFactory? engineFactory,
    MirrorDanmakuFilterPolicyProvider? filterPolicyProvider,
    RxBool? hideDanmaku,
  }) : store = store ?? MirrorDanmakuStore(),
       resolver = resolver ?? MirrorDanmakuResolver() {
    _hideDanmaku = hideDanmaku;
    _session = MirrorDanmakuSession(
      engineFactory: engineFactory,
      filterPolicyProvider: filterPolicyProvider ?? MirrorDanmakuFilterPolicy.fromAppState,
      onChatMessage: _handleChat,
      onReady: _handleReady,
      onReconnect: _handleReconnect,
      onTerminalError: _handleTerminalError,
    );
    final hidden = _hideDanmaku;
    if (hidden != null) {
      _hideWorker = ever<bool>(hidden, _handleHideChanged);
    }
  }

  final MirrorDanmakuHost host;
  final MirrorDanmakuStore store;
  final MirrorDanmakuResolver resolver;
  final Rx<MirrorDanmakuState> state = const MirrorDanmakuState().obs;

  late final RxBool? _hideDanmaku;
  late final MirrorDanmakuSession _session;
  Worker? _hideWorker;
  dio.CancelToken? _resolveCancel;
  LiveRoom? _hostRoom;
  int _epoch = 0;
  bool _disposed = false;
  bool _connectedAnnounced = false;
  String? _lastFailureText;

  LiveRoom? get hostRoom => _hostRoom;

  bool get isAttached => _hostRoom != null;

  bool get globallyHidden => _hideDanmaku?.value ?? false;

  /// Reads the persisted target without changing the attached host.
  ///
  /// The editor uses this before [attachHost] finishes so its initial switch
  /// and URL cannot come from the previous room or empty defaults.
  MirrorDanmakuConfig? readSavedConfig(LiveRoom hostRoom) => store.read(hostRoom);

  /// Reads the host's persisted target and starts it when the host is live and
  /// the global danmaku switch is on. Repeated calls for the same host are
  /// idempotent.
  Future<void> attachHost(LiveRoom hostRoom) async {
    if (_disposed) return;
    if (host.hostIdentity != hostRoom.identityKey) return;

    final normalized = hostRoom.normalizedIdentityCopy();
    final current = _hostRoom;
    if (current != null && current.identityKey == normalized.identityKey) {
      // Refresh the stored detail so a room that turned into a replay/carousel
      // entry is judged by its current state, then let the gate stop the B
      // transport instead of keeping a stale live session alive.
      _hostRoom = normalized;
      await ensureConnected();
      return;
    }
    if (current != null) {
      await detachHost();
    }

    _hostRoom = normalized;
    _lastFailureText = null;
    _connectedAnnounced = false;
    final config = store.read(normalized);
    if (config == null) {
      state.value = const MirrorDanmakuState();
      return;
    }
    state.value = MirrorDanmakuState(
      config: config,
      status: config.enabled ? MirrorDanmakuStatus.idle : MirrorDanmakuStatus.disabled,
    );
    if (!config.enabled || !_canRun(normalized)) return;
    await _resolveAndConnect(++_epoch);
  }

  /// Stops the mirror transport and clears room-bound state. A late result from
  /// the previous host is rejected through [hostIdentity] as well as the epoch.
  Future<void> detachHost() async {
    _epoch++;
    _resolveCancel?.cancel();
    _resolveCancel = null;
    _hostRoom = null;
    _connectedAnnounced = false;
    _lastFailureText = null;
    state.value = const MirrorDanmakuState();
    await _session.disconnect();
  }

  /// Resolves a pasted link for the dialog without changing the saved target.
  Future<MirrorDanmakuResolveResult> preview(String input, {dio.CancelToken? cancelToken}) async {
    final current = _hostRoom;
    if (current == null || !_hostMatches(current)) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.detailFailed);
    }
    return resolver.resolve(input: input, host: current, cancelToken: cancelToken);
  }

  /// Persists the target first. A failed write never reports that the new
  /// target was enabled.
  Future<bool> saveAndApply(MirrorDanmakuConfig config, {MirrorDanmakuResolveResult? resolved}) async {
    final current = _hostRoom;
    if (_disposed || current == null || !_hostMatches(current)) return false;
    if (config.matchesHost(current)) {
      _reportTransient(i18n('mirror_danmaku_same_room'));
      return false;
    }

    final normalized = config.copyWith(platform: config.platform.trim().toLowerCase(), roomId: config.roomId.trim());
    if (normalized.platform.isEmpty || normalized.roomId.isEmpty) {
      _reportTransient(i18n('mirror_danmaku_invalid_link'));
      return false;
    }

    final saved = await store.write(current, normalized);
    if (!saved) {
      _reportTransient(i18n('mirror_danmaku_save_failed'));
      return false;
    }

    final epoch = ++_epoch;
    _resolveCancel?.cancel();
    _resolveCancel = null;
    _connectedAnnounced = false;
    _lastFailureText = null;
    final matchingPreview = _previewMatches(resolved, normalized);
    state.value = MirrorDanmakuState(
      config: normalized,
      target: matchingPreview ? resolved!.room : null,
      status: normalized.enabled ? MirrorDanmakuStatus.idle : MirrorDanmakuStatus.disabled,
    );
    await _session.disconnect();
    if (_disposed || epoch != _epoch) return true;
    if (!normalized.enabled) return true;
    if (!_canRun(current)) return true;

    if (matchingPreview) {
      final target = resolved!.room!;
      if (!resolved.canConnect) {
        state.value = state.value.copyWith(target: target, status: MirrorDanmakuStatus.offline, clearMessage: true);
        host.addMirrorSystemMessage(i18n('mirror_danmaku_offline_message'));
        return true;
      }
      await _connectTarget(target, epoch);
      return true;
    }

    await _resolveAndConnect(epoch, announceOffline: true);
    return true;
  }

  Future<bool> disable() async {
    final current = _hostRoom;
    final config = state.value.config;
    if (_disposed || current == null || config == null) return false;

    final updated = config.copyWith(enabled: false);
    final saved = await store.write(current, updated);
    if (!saved) {
      _reportTransient(i18n('mirror_danmaku_save_failed'));
      return false;
    }

    _epoch++;
    _resolveCancel?.cancel();
    _resolveCancel = null;
    _connectedAnnounced = false;
    _lastFailureText = null;
    state.value = state.value.copyWith(
      config: updated,
      status: MirrorDanmakuStatus.disabled,
      clearTarget: true,
      clearMessage: true,
    );
    await _session.disconnect();
    return true;
  }

  Future<bool> remove() async {
    final current = _hostRoom;
    if (_disposed || current == null) return false;

    final removed = await store.remove(current);
    if (!removed) {
      _reportTransient(i18n('mirror_danmaku_remove_failed'));
      return false;
    }

    _epoch++;
    _resolveCancel?.cancel();
    _resolveCancel = null;
    _connectedAnnounced = false;
    _lastFailureText = null;
    state.value = const MirrorDanmakuState();
    await _session.disconnect();
    return true;
  }

  Future<void> retry() async {
    final current = _hostRoom;
    final config = state.value.config;
    if (_disposed || current == null || config == null || !config.enabled) return;
    if (!_canRun(current)) return;

    final epoch = ++_epoch;
    _resolveCancel?.cancel();
    _resolveCancel = null;
    _lastFailureText = null;
    state.value = state.value.copyWith(status: MirrorDanmakuStatus.idle, clearMessage: true);
    await _session.disconnect();
    if (_disposed || epoch != _epoch || !_canRun(current)) return;
    await _resolveAndConnect(epoch, announceOffline: true);
  }

  /// Reconnects after a presentation/lifecycle recovery. A connected session is
  /// already current and stays untouched; a host that is no longer live (or is
  /// a replay/carousel entry) drops its stale B session instead.
  Future<void> ensureConnected() async {
    final current = _hostRoom;
    final config = state.value.config;
    if (_disposed || current == null || config == null || !config.enabled) return;
    if (!_canRun(current)) {
      // The session may still be connecting, so do not rely on isConnected:
      // bumping the epoch and queueing a disconnect invalidates any in-flight
      // connect before it can publish a live transport.
      _epoch++;
      _resolveCancel?.cancel();
      _resolveCancel = null;
      _connectedAnnounced = false;
      await _session.disconnect();
      if (_disposed) return;
      state.value = state.value.copyWith(status: MirrorDanmakuStatus.idle, clearMessage: true);
      return;
    }
    if (_session.isConnected || state.value.isBusy) return;
    await _resolveAndConnect(++_epoch);
  }

  Future<void> _resolveAndConnect(int epoch, {bool announceOffline = false}) async {
    final current = _hostRoom;
    final config = state.value.config;
    if (_disposed || current == null || config == null || !config.enabled) return;
    if (!_canRun(current)) return;

    _resolveCancel?.cancel();
    final cancel = dio.CancelToken();
    _resolveCancel = cancel;
    state.value = state.value.copyWith(status: MirrorDanmakuStatus.resolving, clearMessage: true);

    final result = await resolver.resolveRoom(
      host: current,
      candidate: LiveRoom(platform: config.platform, roomId: config.roomId),
      cancelToken: cancel,
    );
    if (_disposed || epoch != _epoch || !identical(_resolveCancel, cancel) || !_canRun(current)) return;
    _resolveCancel = null;

    if (!result.isSuccess) {
      _setFailure(result.failure);
      return;
    }
    final target = result.room!;
    state.value = state.value.copyWith(target: target);
    if (!result.canConnect) {
      state.value = state.value.copyWith(status: MirrorDanmakuStatus.offline, clearMessage: true);
      if (announceOffline) host.addMirrorSystemMessage(i18n('mirror_danmaku_offline_message'));
      return;
    }
    await _connectTarget(target, epoch);
  }

  Future<void> _connectTarget(LiveRoom target, int epoch) async {
    final current = _hostRoom;
    if (_disposed || current == null || !_canRun(current)) return;
    state.value = state.value.copyWith(target: target, status: MirrorDanmakuStatus.connecting, clearMessage: true);
    _connectedAnnounced = false;
    await _session.connect(target);
    if (_disposed || epoch != _epoch || !_canRun(current)) return;
    if (_session.isConnected) {
      state.value = state.value.copyWith(status: MirrorDanmakuStatus.connected, clearMessage: true);
    } else if (state.value.status == MirrorDanmakuStatus.connecting) {
      _setFailure(null);
    }
  }

  void _handleChat(LiveMessage message) {
    final current = _hostRoom;
    if (_disposed || current == null || !_canRun(current)) return;
    host.applyMirrorChat(message);
  }

  void _handleReady() {
    final current = _hostRoom;
    if (_disposed || current == null || !_canRun(current)) return;
    state.value = state.value.copyWith(status: MirrorDanmakuStatus.connected, clearMessage: true);
    if (_connectedAnnounced) return;
    _connectedAnnounced = true;
    _lastFailureText = null;
    host.addMirrorSystemMessage(i18n('mirror_danmaku_connected_message', args: {'name': _targetLabel()}));
  }

  void _handleReconnect(String reason) {
    final current = _hostRoom;
    if (_disposed || current == null || !_canRun(current)) return;
    state.value = state.value.copyWith(status: MirrorDanmakuStatus.connecting, clearMessage: true);
  }

  void _handleTerminalError(String reason) {
    final current = _hostRoom;
    if (_disposed || current == null || !_canRun(current)) return;
    final text = reason.trim().isEmpty ? i18n('mirror_danmaku_status_failed') : reason.trim();
    _setFailureText(text);
  }

  void _handleHideChanged(bool hidden) {
    if (_disposed) return;
    if (hidden) {
      _epoch++;
      _resolveCancel?.cancel();
      _resolveCancel = null;
      _connectedAnnounced = false;
      state.value = state.value.copyWith(status: MirrorDanmakuStatus.idle, clearTarget: true, clearMessage: true);
      unawaited(_session.disconnect());
      return;
    }
    unawaited(ensureConnected());
  }

  void _setFailure(MirrorDanmakuResolveFailure? failure) {
    _setFailureText(mirrorDanmakuResolveFailureText(failure));
  }

  void _setFailureText(String text) {
    state.value = state.value.copyWith(status: MirrorDanmakuStatus.failed, message: text);
    if (_lastFailureText == text) return;
    _lastFailureText = text;
    host.addMirrorSystemMessage(i18n('mirror_danmaku_connect_failed_message', args: {'reason': text}));
  }

  void _reportTransient(String text) {
    state.value = state.value.copyWith(message: text);
  }

  bool _canRun(LiveRoom current) {
    if (_disposed || globallyHidden || !_hostEligible(current)) return false;
    return _hostMatches(current);
  }

  bool _hostMatches(LiveRoom current) {
    return _hostRoom?.identityKey == current.identityKey &&
        host.hostIdentity == current.identityKey &&
        host.isHostCurrent;
  }

  bool _hostEligible(LiveRoom current) {
    // The mirror is only valid for a current live broadcast. Replay, catch-up
    // and carousel entries are playable, but injecting B's live chat into them
    // would be wrong; the same gate is used by the menu before it offers the
    // dialog, so this also prevents an unreachable connected state.
    if (!current.isLiveNow || current.isRecord == true || current.isCatchUpActive) return false;
    final platform = current.normalizedPlatformId;
    if (platform.isEmpty || platform == Sites.iptvSite || platform == Sites.ccSite) return false;
    return Sites.supportsDanmakuTransport(platform);
  }

  bool _previewMatches(MirrorDanmakuResolveResult? result, MirrorDanmakuConfig config) {
    final room = result?.room;
    return result != null &&
        result.isSuccess &&
        room != null &&
        room.normalizedPlatformId == config.platform &&
        room.normalizedRoomId == config.roomId;
  }

  String _targetLabel() {
    final target = state.value.target;
    final config = state.value.config;
    final nick = target?.nick?.trim() ?? '';
    if (nick.isNotEmpty) return nick;
    final title = target?.title?.trim() ?? '';
    if (title.isNotEmpty) return title;
    final platform = config?.platform ?? '';
    final platformName = platform.isNotEmpty && Sites.isSupported(platform) ? Sites.of(platform).name : platform;
    final roomId = config?.roomId ?? '';
    return '$platformName $roomId'.trim();
  }

  /// Deferred by [onClose] while the in-app floating window still owns the
  /// host room; the room calls this again when the floating resources die.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _resolveCancel?.cancel();
    _resolveCancel = null;
    _hideWorker?.dispose();
    _hideWorker = null;
    state.close();
    await _session.disconnect();
  }

  void onClose() {
    if (host.keepsMirrorDanmakuForFloating) return;
    unawaited(dispose());
  }
}
