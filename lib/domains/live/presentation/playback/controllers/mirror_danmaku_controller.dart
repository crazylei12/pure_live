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

class MirrorDanmakuTargetState {
  const MirrorDanmakuTargetState({
    required this.config,
    this.target,
    this.status = MirrorDanmakuStatus.idle,
    this.message,
  });

  final MirrorDanmakuConfig config;
  final LiveRoom? target;
  final MirrorDanmakuStatus status;
  final String? message;

  String get identityKey => config.identityKey;

  bool get isEnabled => config.enabled;

  bool get isBusy => status == MirrorDanmakuStatus.resolving || status == MirrorDanmakuStatus.connecting;

  bool get isConnected => status == MirrorDanmakuStatus.connected;
}

class MirrorDanmakuState {
  const MirrorDanmakuState({this.targets = const <MirrorDanmakuTargetState>[], this.message});

  final List<MirrorDanmakuTargetState> targets;
  final String? message;

  bool get isEmpty => targets.isEmpty;

  bool get isNotEmpty => targets.isNotEmpty;

  int get count => targets.length;

  MirrorDanmakuTargetState? targetFor(String identityKey) {
    for (final target in targets) {
      if (target.identityKey == identityKey) return target;
    }
    return null;
  }

  MirrorDanmakuState copyWith({List<MirrorDanmakuTargetState>? targets, String? message, bool clearMessage = false}) {
    return MirrorDanmakuState(
      targets: targets ?? this.targets,
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

/// Owns the mirrored danmaku transports for one A room.
///
/// It is not a global singleton: every [LivePlayController] owns one instance.
/// Each target has its own session and epoch, so one slow or failed B room
/// cannot cancel or re-target another B room. Every asynchronous result is
/// additionally fenced by the attached host identity before it can touch A.
class MirrorDanmakuController {
  MirrorDanmakuController({
    required this.host,
    MirrorDanmakuStore? store,
    MirrorDanmakuResolver? resolver,
    MirrorDanmakuEngineFactory? engineFactory,
    MirrorDanmakuFilterPolicyProvider? filterPolicyProvider,
    RxBool? hideDanmaku,
    int maxTargets = defaultMaxTargets,
  }) : store = store ?? MirrorDanmakuStore(),
       resolver = resolver ?? MirrorDanmakuResolver(),
       // The factory stays private while callers pass it by a public name.
       // ignore: prefer_initializing_formals
       _engineFactory = engineFactory,
       _filterPolicyProvider = filterPolicyProvider ?? MirrorDanmakuFilterPolicy.fromAppState,
       maxTargets = maxTargets.clamp(1, defaultMaxTargets).toInt() {
    _hideDanmaku = hideDanmaku;
    final hidden = _hideDanmaku;
    if (hidden != null) {
      _hideWorker = ever<bool>(hidden, _handleHideChanged);
    }
  }

  /// Matches the app's existing multiview upper bound. Each target opens its
  /// own transport, so more than this would multiply socket/message load.
  static const int defaultMaxTargets = 9;

  final MirrorDanmakuHost host;
  final MirrorDanmakuStore store;
  final MirrorDanmakuResolver resolver;
  final int maxTargets;
  final Rx<MirrorDanmakuState> state = const MirrorDanmakuState().obs;

  final MirrorDanmakuEngineFactory? _engineFactory;
  final MirrorDanmakuFilterPolicyProvider _filterPolicyProvider;
  final List<_MirrorDanmakuRuntime> _runtimes = <_MirrorDanmakuRuntime>[];

  late final RxBool? _hideDanmaku;
  Worker? _hideWorker;
  LiveRoom? _hostRoom;
  bool _disposed = false;

  LiveRoom? get hostRoom => _hostRoom;

  bool get isAttached => _hostRoom != null;

  bool get globallyHidden => _hideDanmaku?.value ?? false;

  /// Reads persisted targets for [hostRoom], capped to [maxTargets], without
  /// changing the attached host.
  List<MirrorDanmakuConfig> readSavedConfigs(LiveRoom hostRoom) {
    return store.readAll(hostRoom).take(maxTargets).toList(growable: false);
  }

  /// Reads the host's persisted targets and starts every enabled one when the
  /// host is live and the global danmaku switch is on. Repeated calls for the
  /// same host are idempotent.
  Future<void> attachHost(LiveRoom hostRoom) async {
    if (_disposed) return;
    if (host.hostIdentity != hostRoom.identityKey) return;

    final normalized = hostRoom.normalizedIdentityCopy();
    final current = _hostRoom;
    if (current != null && current.identityKey == normalized.identityKey) {
      // Refresh the stored detail so a room that turned into a replay/carousel
      // entry is judged by its current state, then let the gate stop the B
      // transports instead of keeping a stale live session alive.
      _hostRoom = normalized;
      await ensureConnected();
      return;
    }
    if (current != null) {
      await detachHost();
    }

    _hostRoom = normalized;
    _runtimes
      ..clear()
      ..addAll(readSavedConfigs(normalized).map(_createRuntime));
    _publish();
    if (!_canRun(normalized)) return;
    await _startEnabledTargets();
  }

  /// Stops every mirror transport and clears room-bound state. Late results
  /// from the previous host are rejected through [hostIdentity] as well as each
  /// runtime's epoch and identity.
  Future<void> detachHost() async {
    _hostRoom = null;
    final runtimes = List<_MirrorDanmakuRuntime>.of(_runtimes);
    _runtimes.clear();
    _publish();
    await Future.wait(runtimes.map(_disposeRuntime));
  }

  /// Resolves a pasted link for the dialog without changing saved targets.
  Future<MirrorDanmakuResolveResult> preview(String input, {dio.CancelToken? cancelToken}) async {
    final current = _hostRoom;
    if (current == null || !_hostMatches(current)) {
      return MirrorDanmakuResolveResult.failed(MirrorDanmakuResolveFailure.detailFailed);
    }
    return resolver.resolve(input: input, host: current, cancelToken: cancelToken);
  }

  /// Appends one target after persisting the complete list. A failed write
  /// never reports that the new target was added or enabled.
  Future<bool> addAndApply(MirrorDanmakuConfig config, {MirrorDanmakuResolveResult? resolved}) async {
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
    if (_runtimes.any((runtime) => runtime.config.identityKey == normalized.identityKey)) {
      _reportTransient(i18n('mirror_danmaku_duplicate_target'));
      return false;
    }
    if (_runtimes.length >= maxTargets) {
      _reportTransient(i18n('mirror_danmaku_limit_reached', args: <String, String>{'max': '$maxTargets'}));
      return false;
    }

    final configs = <MirrorDanmakuConfig>[for (final runtime in _runtimes) runtime.config, normalized];
    final saved = await store.writeAll(current, configs);
    if (!saved) {
      _reportTransient(i18n('mirror_danmaku_save_failed'));
      return false;
    }
    if (_disposed) return true;

    final runtime = _createRuntime(normalized);
    _runtimes.add(runtime);
    final epoch = ++runtime.epoch;
    _publish();
    if (!normalized.enabled) return true;

    final matchingPreview = _previewMatches(resolved, normalized);
    final previewRoom = matchingPreview ? resolved!.room : null;
    if (previewRoom != null) {
      runtime.target = previewRoom;
      if (!resolved!.canConnect) {
        runtime.status = MirrorDanmakuStatus.offline;
        runtime.message = null;
        _publish();
        host.addMirrorSystemMessage(
          i18n('mirror_danmaku_offline_message', args: <String, String>{'name': _labelFor(runtime)}),
        );
        return true;
      }
      if (!_canRun(current)) return true;
      await _connectTarget(runtime, previewRoom, epoch);
      return true;
    }

    if (!_canRun(current)) return true;
    await _resolveAndConnect(runtime, epoch, announceOffline: true);
    return true;
  }

  /// Writes one target's enabled flag and starts or stops only that transport.
  Future<bool> setEnabled(String identityKey, bool enabled) async {
    final current = _hostRoom;
    if (_disposed || current == null || !_hostMatches(current)) return false;
    final index = _runtimes.indexWhere((runtime) => runtime.config.identityKey == identityKey);
    if (index < 0) return false;
    final runtime = _runtimes[index];
    if (runtime.config.enabled == enabled) return true;

    final configs = <MirrorDanmakuConfig>[
      for (var i = 0; i < _runtimes.length; i++)
        i == index ? runtime.config.copyWith(enabled: enabled) : _runtimes[i].config,
    ];
    final saved = await store.writeAll(current, configs);
    if (!saved) {
      _reportTransient(i18n('mirror_danmaku_save_failed'));
      return false;
    }
    if (_disposed || runtime.disposed) return true;

    runtime.config = configs[index];
    final epoch = ++runtime.epoch;
    runtime.resolveCancel?.cancel();
    runtime.resolveCancel = null;
    runtime.connectedAnnounced = false;
    runtime.lastFailureText = null;
    runtime.target = null;
    runtime.message = null;
    runtime.status = enabled ? MirrorDanmakuStatus.idle : MirrorDanmakuStatus.disabled;
    _publish();
    await runtime.session.disconnect();
    if (_disposed || runtime.disposed || epoch != runtime.epoch) return true;
    if (!enabled || !_canRun(current)) return true;
    await _resolveAndConnect(runtime, epoch);
    return true;
  }

  /// Removes one target and stops only its transport. Removing the last target
  /// also deletes the room's storage entry.
  Future<bool> removeTarget(String identityKey) async {
    final current = _hostRoom;
    if (_disposed || current == null || !_hostMatches(current)) return false;
    final index = _runtimes.indexWhere((runtime) => runtime.config.identityKey == identityKey);
    if (index < 0) return false;

    final configs = <MirrorDanmakuConfig>[
      for (var i = 0; i < _runtimes.length; i++)
        if (i != index) _runtimes[i].config,
    ];
    final saved = configs.isEmpty ? await store.remove(current) : await store.writeAll(current, configs);
    if (!saved) {
      _reportTransient(i18n('mirror_danmaku_remove_failed'));
      return false;
    }
    if (_disposed) return true;

    final runtime = _runtimes.removeAt(index);
    _publish();
    await _disposeRuntime(runtime);
    return true;
  }

  /// Re-resolves one target, or every enabled target when [identityKey] is
  /// omitted. Other targets are left untouched.
  Future<void> retry({String? identityKey}) async {
    final current = _hostRoom;
    if (_disposed || current == null || !_hostMatches(current)) return;
    final targets = _runtimes
        .where(
          (runtime) => runtime.config.enabled && (identityKey == null || runtime.config.identityKey == identityKey),
        )
        .toList(growable: false);
    await Future.wait(targets.map((runtime) => _startTarget(runtime, announceOffline: true)));
  }

  /// Reconnects after a presentation/lifecycle recovery. Connected targets are
  /// current and stay untouched; a host that is no longer live (or is a
  /// replay/carousel entry) drops all stale B sessions instead.
  Future<void> ensureConnected() async {
    final current = _hostRoom;
    if (_disposed || current == null) return;
    if (!_canRun(current)) {
      // A session may still be connecting, so do not rely on isConnected:
      // bumping each runtime's epoch and queueing a disconnect invalidates any
      // in-flight connect before it can publish a live transport.
      await _stopAllForGate();
      return;
    }
    final targets = _runtimes
        .where(
          (runtime) => !runtime.disposed && runtime.config.enabled && !runtime.isBusy && !runtime.session.isConnected,
        )
        .toList(growable: false);
    if (targets.isEmpty) return;
    await Future.wait(targets.map(_startTarget));
  }

  Future<void> _startEnabledTargets() async {
    final current = _hostRoom;
    if (_disposed || current == null || !_canRun(current)) return;
    final targets = _runtimes.where((runtime) => runtime.config.enabled && !runtime.disposed).toList(growable: false);
    if (targets.isEmpty) return;
    await Future.wait(targets.map(_startTarget));
  }

  Future<void> _startTarget(_MirrorDanmakuRuntime runtime, {bool announceOffline = false}) async {
    if (_disposed || runtime.disposed) return;
    final epoch = ++runtime.epoch;
    runtime.resolveCancel?.cancel();
    runtime.resolveCancel = null;
    runtime.connectedAnnounced = false;
    runtime.lastFailureText = null;
    runtime.target = null;
    runtime.message = null;
    runtime.status = runtime.config.enabled ? MirrorDanmakuStatus.idle : MirrorDanmakuStatus.disabled;
    _publish();
    await runtime.session.disconnect();
    if (_disposed || runtime.disposed || epoch != runtime.epoch) return;
    if (!runtime.config.enabled) return;
    await _resolveAndConnect(runtime, epoch, announceOffline: announceOffline);
  }

  Future<void> _resolveAndConnect(_MirrorDanmakuRuntime runtime, int epoch, {bool announceOffline = false}) async {
    final current = _hostRoom;
    if (_disposed || current == null || runtime.disposed || !runtime.config.enabled || !_canRun(current)) return;

    runtime.resolveCancel?.cancel();
    final cancel = dio.CancelToken();
    runtime.resolveCancel = cancel;
    runtime.status = MirrorDanmakuStatus.resolving;
    runtime.message = null;
    _publish();

    final result = await resolver.resolveRoom(
      host: current,
      candidate: LiveRoom(platform: runtime.config.platform, roomId: runtime.config.roomId),
      cancelToken: cancel,
    );
    if (_disposed ||
        runtime.disposed ||
        epoch != runtime.epoch ||
        !identical(runtime.resolveCancel, cancel) ||
        !_canRun(current)) {
      return;
    }
    runtime.resolveCancel = null;

    if (!result.isSuccess) {
      _setFailure(runtime, mirrorDanmakuResolveFailureText(result.failure));
      return;
    }
    final target = result.room!;
    runtime.target = target;
    _publish();
    if (!result.canConnect) {
      runtime.status = MirrorDanmakuStatus.offline;
      runtime.message = null;
      _publish();
      if (announceOffline) {
        host.addMirrorSystemMessage(
          i18n('mirror_danmaku_offline_message', args: <String, String>{'name': _labelFor(runtime)}),
        );
      }
      return;
    }
    await _connectTarget(runtime, target, epoch);
  }

  Future<void> _connectTarget(_MirrorDanmakuRuntime runtime, LiveRoom target, int epoch) async {
    final current = _hostRoom;
    if (_disposed || current == null || runtime.disposed || !_canRun(current)) return;
    runtime.target = target;
    runtime.status = MirrorDanmakuStatus.connecting;
    runtime.message = null;
    runtime.connectedAnnounced = false;
    _publish();
    await runtime.session.connect(target);
    if (_disposed || runtime.disposed || epoch != runtime.epoch || !_canRun(current)) return;
    if (runtime.session.isConnected) {
      runtime.status = MirrorDanmakuStatus.connected;
      runtime.message = null;
      _publish();
    } else if (runtime.status == MirrorDanmakuStatus.connecting) {
      _setFailure(runtime, mirrorDanmakuResolveFailureText(null));
    }
  }

  /// Stops every transport without detaching the host. Used by the global
  /// danmaku switch and by hosts that stopped being eligible.
  Future<void> _stopAllForGate() async {
    final tasks = <Future<void>>[];
    for (final runtime in _runtimes) {
      runtime.epoch++;
      runtime.resolveCancel?.cancel();
      runtime.resolveCancel = null;
      runtime.connectedAnnounced = false;
      runtime.lastFailureText = null;
      runtime.target = null;
      runtime.message = null;
      runtime.status = runtime.config.enabled ? MirrorDanmakuStatus.idle : MirrorDanmakuStatus.disabled;
      tasks.add(runtime.session.disconnect());
    }
    _publish();
    await Future.wait(tasks);
  }

  void _handleChat(_MirrorDanmakuRuntime runtime, LiveMessage message) {
    final current = _hostRoom;
    if (_disposed || current == null || !_runtimeAlive(runtime) || !_canRun(current)) return;
    host.applyMirrorChat(message);
  }

  void _handleReady(_MirrorDanmakuRuntime runtime) {
    final current = _hostRoom;
    if (_disposed || current == null || !_runtimeAlive(runtime) || !_canRun(current)) return;
    runtime.status = MirrorDanmakuStatus.connected;
    runtime.message = null;
    _publish();
    if (runtime.connectedAnnounced) return;
    runtime.connectedAnnounced = true;
    runtime.lastFailureText = null;
    host.addMirrorSystemMessage(
      i18n('mirror_danmaku_connected_message', args: <String, String>{'name': _labelFor(runtime)}),
    );
  }

  void _handleReconnect(_MirrorDanmakuRuntime runtime, String reason) {
    final current = _hostRoom;
    if (_disposed || current == null || !_runtimeAlive(runtime) || !_canRun(current)) return;
    runtime.status = MirrorDanmakuStatus.connecting;
    runtime.message = null;
    _publish();
  }

  void _handleTerminalError(_MirrorDanmakuRuntime runtime, String reason) {
    final current = _hostRoom;
    if (_disposed || current == null || !_runtimeAlive(runtime) || !_canRun(current)) return;
    final text = reason.trim().isEmpty ? mirrorDanmakuResolveFailureText(null) : reason.trim();
    _setFailure(runtime, text);
  }

  void _handleHideChanged(bool hidden) {
    if (_disposed) return;
    if (hidden) {
      unawaited(_stopAllForGate());
      return;
    }
    unawaited(ensureConnected());
  }

  void _setFailure(_MirrorDanmakuRuntime runtime, String text) {
    runtime.status = MirrorDanmakuStatus.failed;
    runtime.message = text;
    _publish();
    if (runtime.lastFailureText == text) return;
    runtime.lastFailureText = text;
    host.addMirrorSystemMessage(
      i18n('mirror_danmaku_connect_failed_message', args: <String, String>{'name': _labelFor(runtime), 'reason': text}),
    );
  }

  void _reportTransient(String text) {
    if (_disposed) return;
    state.value = state.value.copyWith(message: text);
  }

  void _publish() {
    if (_disposed) return;
    state.value = MirrorDanmakuState(
      targets: <MirrorDanmakuTargetState>[
        for (final runtime in _runtimes)
          MirrorDanmakuTargetState(
            config: runtime.config,
            target: runtime.target,
            status: runtime.status,
            message: runtime.message,
          ),
      ],
    );
  }

  _MirrorDanmakuRuntime _createRuntime(MirrorDanmakuConfig config) {
    late final _MirrorDanmakuRuntime runtime;
    final session = MirrorDanmakuSession(
      engineFactory: _engineFactory,
      filterPolicyProvider: _filterPolicyProvider,
      onChatMessage: (message) => _handleChat(runtime, message),
      onReady: () => _handleReady(runtime),
      onReconnect: (reason) => _handleReconnect(runtime, reason),
      onTerminalError: (reason) => _handleTerminalError(runtime, reason),
    );
    runtime = _MirrorDanmakuRuntime(config: config, session: session);
    return runtime;
  }

  Future<void> _disposeRuntime(_MirrorDanmakuRuntime runtime) async {
    runtime.disposed = true;
    runtime.epoch++;
    runtime.resolveCancel?.cancel();
    runtime.resolveCancel = null;
    await runtime.session.disconnect();
  }

  bool _runtimeAlive(_MirrorDanmakuRuntime runtime) {
    return !_disposed && !runtime.disposed && _runtimes.contains(runtime);
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

  String _labelFor(_MirrorDanmakuRuntime runtime) {
    final target = runtime.target;
    final config = runtime.config;
    final nick = target?.nick?.trim() ?? '';
    if (nick.isNotEmpty) return nick;
    final storedNick = config.nick.trim();
    if (storedNick.isNotEmpty) return storedNick;
    final title = target?.title?.trim() ?? '';
    if (title.isNotEmpty) return title;
    final storedTitle = config.title.trim();
    if (storedTitle.isNotEmpty) return storedTitle;
    final platform = config.platform;
    final platformName = platform.isNotEmpty && Sites.isSupported(platform) ? Sites.of(platform).name : platform;
    final roomId = config.roomId;
    return '$platformName $roomId'.trim();
  }

  /// Deferred by [onClose] while the in-app floating window still owns the
  /// host room; the room calls this again when the floating resources die.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final runtimes = List<_MirrorDanmakuRuntime>.of(_runtimes);
    _runtimes.clear();
    _hideWorker?.dispose();
    _hideWorker = null;
    state.close();
    await Future.wait(runtimes.map(_disposeRuntime));
  }

  void onClose() {
    if (host.keepsMirrorDanmakuForFloating) return;
    unawaited(dispose());
  }
}

class _MirrorDanmakuRuntime {
  _MirrorDanmakuRuntime({required this.config, required this.session})
    : status = config.enabled ? MirrorDanmakuStatus.idle : MirrorDanmakuStatus.disabled;

  MirrorDanmakuConfig config;
  final MirrorDanmakuSession session;
  LiveRoom? target;
  MirrorDanmakuStatus status;
  String? message;
  int epoch = 0;
  dio.CancelToken? resolveCancel;
  bool connectedAnnounced = false;
  String? lastFailureText;
  bool disposed = false;

  bool get isBusy => status == MirrorDanmakuStatus.resolving || status == MirrorDanmakuStatus.connecting;
}
