import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:pure_live/core/index.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_config.dart';
import 'package:pure_live/domains/live/data/mirror_danmaku/mirror_danmaku_resolver.dart';
import 'package:pure_live/domains/live/data/platforms/sites.dart';
import 'package:pure_live/domains/live/presentation/playback/controllers/live_play_controller.dart';
import 'package:pure_live/domains/live/presentation/playback/controllers/mirror_danmaku_controller.dart';

class MirrorDanmakuDialog {
  const MirrorDanmakuDialog._();

  static Future<void> show({required BuildContext context, required LivePlayController controller}) {
    return showDialog<void>(
      context: context,
      builder: (_) =>
          MirrorDanmakuEditor(mirror: controller.mirrorDanmakuController, hostRoom: controller.state.value.room.detail),
    );
  }
}

@visibleForTesting
class MirrorDanmakuEditor extends StatefulWidget {
  const MirrorDanmakuEditor({super.key, required this.mirror, required this.hostRoom});

  final MirrorDanmakuController mirror;
  final LiveRoom? hostRoom;

  @override
  State<MirrorDanmakuEditor> createState() => _MirrorDanmakuEditorState();
}

class _MirrorDanmakuEditorState extends State<MirrorDanmakuEditor> {
  late final MirrorDanmakuController _mirror;
  late final TextEditingController _url;
  late bool _enabled;

  MirrorDanmakuResolveResult? _preview;
  String? _previewInput;
  CancelToken? _cancelToken;
  int _previewEpoch = 0;
  bool _previewing = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mirror = widget.mirror;
    // Read the persisted target before the asynchronous host attach can finish.
    // The menu becomes available before attachHost runs, so relying on the
    // controller state here would briefly show defaults and could save an
    // enabled value over an already-disabled configuration.
    final hostRoom = widget.hostRoom;
    final config = hostRoom == null ? null : _mirror.readSavedConfig(hostRoom);
    _enabled = config?.enabled ?? true;
    _url = TextEditingController(text: config?.sourceUrl ?? '');
    if (hostRoom != null) {
      unawaited(_mirror.attachHost(hostRoom));
    }
  }

  @override
  void dispose() {
    _previewEpoch++;
    _cancelToken?.cancel();
    _url.dispose();
    super.dispose();
  }

  void _onUrlChanged(String value) {
    _previewEpoch++;
    _cancelToken?.cancel();
    _cancelToken = null;
    setState(() {
      _preview = null;
      _previewInput = null;
      _previewing = false;
      _error = null;
    });
  }

  Future<void> _runPreview() async {
    final input = _url.text.trim();
    if (input.isEmpty) {
      setState(() => _error = i18n('mirror_danmaku_invalid_input'));
      return;
    }

    final epoch = ++_previewEpoch;
    _cancelToken?.cancel();
    final token = CancelToken();
    _cancelToken = token;
    setState(() {
      _previewing = true;
      _preview = null;
      _previewInput = null;
      _error = null;
    });

    final result = await _mirror.preview(input, cancelToken: token);
    if (!mounted || epoch != _previewEpoch) return;
    setState(() {
      _previewing = false;
      _preview = result;
      _previewInput = input;
      _error = result.isSuccess ? null : mirrorDanmakuResolveFailureText(result.failure);
    });
  }

  Future<void> _save() async {
    if (_saving || _previewing) return;
    final current = _mirror.state.value.config;
    final input = _url.text.trim();

    MirrorDanmakuConfig? config;
    MirrorDanmakuResolveResult? preview;
    if (_preview?.isSuccess == true && _previewInput == input) {
      preview = _preview;
      final room = preview!.room!;
      config = MirrorDanmakuConfig(
        platform: room.normalizedPlatformId,
        roomId: room.normalizedRoomId,
        sourceUrl: input,
        nick: room.nick?.trim() ?? '',
        title: room.title?.trim() ?? '',
        enabled: _enabled,
      );
    } else if (current != null && (input.isEmpty || input == current.sourceUrl)) {
      config = current.copyWith(enabled: _enabled);
    } else {
      setState(() => _error = i18n('mirror_danmaku_preview_required'));
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    final saved = await _mirror.saveAndApply(config, resolved: preview);
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _error = _mirror.state.value.message ?? i18n('mirror_danmaku_save_failed'));
  }

  Future<void> _disable() async {
    final disabled = await _mirror.disable();
    if (!mounted) return;
    setState(() {
      if (disabled) {
        _enabled = false;
        _error = null;
      } else {
        // The write failed, so the persisted target and the B transport remain
        // enabled. Keep the switch in that state instead of implying success.
        _error = _mirror.state.value.message ?? i18n('mirror_danmaku_save_failed');
      }
    });
  }

  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(i18n('mirror_danmaku_confirm_remove_title')),
        content: Text(i18n('mirror_danmaku_confirm_remove_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(i18n('mirror_danmaku_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(i18n('mirror_danmaku_confirm_remove_action')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final removed = await _mirror.remove();
    if (!mounted) return;
    if (removed) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _error = _mirror.state.value.message ?? i18n('mirror_danmaku_remove_failed'));
  }

  String _statusLabel(MirrorDanmakuState state) {
    if (state.config == null) return i18n('mirror_danmaku_no_target');
    if (_mirror.globallyHidden && state.config!.enabled) return i18n('mirror_danmaku_global_hidden');
    return switch (state.status) {
      MirrorDanmakuStatus.idle => i18n('mirror_danmaku_status_idle'),
      MirrorDanmakuStatus.disabled => i18n('mirror_danmaku_status_disabled'),
      MirrorDanmakuStatus.resolving => i18n('mirror_danmaku_status_resolving'),
      MirrorDanmakuStatus.connecting => i18n('mirror_danmaku_status_connecting'),
      MirrorDanmakuStatus.connected => i18n('mirror_danmaku_status_connected'),
      MirrorDanmakuStatus.offline => i18n('mirror_danmaku_status_offline'),
      MirrorDanmakuStatus.failed => i18n('mirror_danmaku_status_failed'),
    };
  }

  Color _statusColor(BuildContext context, MirrorDanmakuState state) {
    final scheme = Theme.of(context).colorScheme;
    if (_mirror.globallyHidden && state.config?.enabled == true) return scheme.outline;
    return switch (state.status) {
      MirrorDanmakuStatus.connected => Colors.green,
      MirrorDanmakuStatus.failed => scheme.error,
      MirrorDanmakuStatus.offline => scheme.tertiary,
      MirrorDanmakuStatus.resolving || MirrorDanmakuStatus.connecting => scheme.primary,
      MirrorDanmakuStatus.idle || MirrorDanmakuStatus.disabled => scheme.outline,
    };
  }

  Widget _statusLine(BuildContext context, MirrorDanmakuState state) {
    return Row(
      children: [
        Icon(Icons.circle, size: 10, color: _statusColor(context, state)),
        const SizedBox(width: 8),
        Expanded(child: Text(_statusLabel(state), style: Theme.of(context).textTheme.bodyMedium)),
      ],
    );
  }

  Widget _roomSummary(BuildContext context, LiveRoom room, {required bool canConnect}) {
    final platform = room.normalizedPlatformId;
    final platformName = platform.isNotEmpty && Sites.isSupported(platform) ? Sites.of(platform).name : platform;
    final lines = <String>[
      '${i18n('mirror_danmaku_platform')}: $platformName',
      '${i18n('mirror_danmaku_room_id')}: ${room.normalizedRoomId}',
      if ((room.nick ?? '').trim().isNotEmpty) '${i18n('mirror_danmaku_nick')}: ${room.nick!.trim()}',
      if ((room.title ?? '').trim().isNotEmpty) '${i18n('mirror_danmaku_room_title')}: ${room.title!.trim()}',
      '${i18n('mirror_danmaku_live')}: ${canConnect ? i18n('mirror_danmaku_live') : i18n('mirror_danmaku_offline')}',
    ];
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(line, style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height - 40;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: maxHeight > 240 ? maxHeight : 240),
        child: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                  child: Obx(() {
                    final state = _mirror.state.value;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(i18n('mirror_danmaku_title'), style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 8),
                        Text(i18n('mirror_danmaku_desc'), style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 16),
                        _statusLine(context, state),
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(i18n('mirror_danmaku_enable')),
                          value: _enabled,
                          onChanged: (value) => setState(() => _enabled = value),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _url,
                          enabled: !_saving,
                          onChanged: _onUrlChanged,
                          decoration: InputDecoration(
                            labelText: i18n('mirror_danmaku_url_label'),
                            hintText: i18n('mirror_danmaku_url_hint'),
                            border: const OutlineInputBorder(),
                          ),
                          maxLines: 2,
                          minLines: 1,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: _previewing || _saving ? null : _runPreview,
                              child: Text(i18n(_previewing ? 'mirror_danmaku_previewing' : 'mirror_danmaku_preview')),
                            ),
                            if (state.config != null)
                              OutlinedButton(
                                onPressed: _saving ? null : _mirror.retry,
                                child: Text(i18n('mirror_danmaku_retry')),
                              ),
                            if (state.config != null)
                              OutlinedButton(
                                onPressed: _saving ? null : _disable,
                                child: Text(i18n('mirror_danmaku_disable')),
                              ),
                            if (state.config != null)
                              TextButton(
                                onPressed: _saving ? null : _remove,
                                child: Text(i18n('mirror_danmaku_remove')),
                              ),
                          ],
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                        ] else if (state.message != null) ...[
                          const SizedBox(height: 12),
                          Text(state.message!),
                        ],
                        if (_preview?.isSuccess == true && _preview?.room != null)
                          _roomSummary(context, _preview!.room!, canConnect: _preview!.canConnect)
                        else if (state.target != null)
                          _roomSummary(
                            context,
                            state.target!,
                            canConnect: state.status == MirrorDanmakuStatus.connected,
                          ),
                      ],
                    );
                  }),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: _saving ? null : () => Navigator.of(context).pop(),
                      child: Text(i18n('mirror_danmaku_cancel')),
                    ),
                    FilledButton(
                      onPressed: _saving || _previewing ? null : _save,
                      child: Text(i18n('mirror_danmaku_save')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
