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
  bool _enabled = true;

  MirrorDanmakuResolveResult? _preview;
  String? _previewInput;
  CancelToken? _cancelToken;
  int _previewEpoch = 0;
  bool _previewing = false;
  bool _saving = false;
  final Set<String> _busyTargets = <String>{};
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _mirror = widget.mirror;
    // attachHost publishes the persisted targets synchronously before its first
    // await, so the list is available on the first frame and cannot come from
    // the previous room.
    final hostRoom = widget.hostRoom;
    _url = TextEditingController();
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
      _notice = null;
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
      _notice = null;
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

  Future<void> _addTarget() async {
    if (_saving || _previewing) return;
    final input = _url.text.trim();
    if (input.isEmpty) {
      setState(() => _error = i18n('mirror_danmaku_invalid_input'));
      return;
    }
    if (_mirror.state.value.count >= _mirror.maxTargets) {
      setState(() => _error = i18n('mirror_danmaku_limit_reached', args: {'max': '${_mirror.maxTargets}'}));
      return;
    }
    if (_preview?.isSuccess != true || _previewInput != input) {
      setState(() => _error = i18n('mirror_danmaku_preview_required'));
      return;
    }

    final room = _preview!.room!;
    final config = MirrorDanmakuConfig(
      platform: room.normalizedPlatformId,
      roomId: room.normalizedRoomId,
      sourceUrl: input,
      nick: room.nick?.trim() ?? '',
      title: room.title?.trim() ?? '',
      enabled: _enabled,
    );

    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    final saved = await _mirror.addAndApply(config, resolved: _preview);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (saved) {
        _url.clear();
        _preview = null;
        _previewInput = null;
        _notice = i18n('mirror_danmaku_added');
      } else {
        _error = _mirror.state.value.message ?? i18n('mirror_danmaku_save_failed');
      }
    });
  }

  Future<void> _toggleTarget(MirrorDanmakuTargetState target, bool enabled) async {
    final key = target.identityKey;
    if (_busyTargets.contains(key)) return;
    setState(() {
      _busyTargets.add(key);
      _error = null;
      _notice = null;
    });
    final saved = await _mirror.setEnabled(key, enabled);
    if (!mounted) return;
    setState(() {
      _busyTargets.remove(key);
      if (!saved) {
        _error = _mirror.state.value.message ?? i18n('mirror_danmaku_save_failed');
      }
    });
  }

  Future<void> _retryTarget(MirrorDanmakuTargetState target) async {
    final key = target.identityKey;
    if (_busyTargets.contains(key)) return;
    setState(() {
      _busyTargets.add(key);
      _error = null;
      _notice = null;
    });
    await _mirror.retry(identityKey: key);
    if (!mounted) return;
    setState(() => _busyTargets.remove(key));
  }

  Future<void> _removeTarget(MirrorDanmakuTargetState target) async {
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

    final key = target.identityKey;
    setState(() {
      _busyTargets.add(key);
      _error = null;
      _notice = null;
    });
    final removed = await _mirror.removeTarget(key);
    if (!mounted) return;
    setState(() {
      _busyTargets.remove(key);
      if (!removed) {
        _error = _mirror.state.value.message ?? i18n('mirror_danmaku_remove_failed');
      }
    });
  }

  String _statusLabel(MirrorDanmakuTargetState target) {
    if (!target.config.enabled) return i18n('mirror_danmaku_status_disabled');
    if (_mirror.globallyHidden) return i18n('mirror_danmaku_global_hidden');
    return switch (target.status) {
      MirrorDanmakuStatus.idle => i18n('mirror_danmaku_status_idle'),
      MirrorDanmakuStatus.disabled => i18n('mirror_danmaku_status_disabled'),
      MirrorDanmakuStatus.resolving => i18n('mirror_danmaku_status_resolving'),
      MirrorDanmakuStatus.connecting => i18n('mirror_danmaku_status_connecting'),
      MirrorDanmakuStatus.connected => i18n('mirror_danmaku_status_connected'),
      MirrorDanmakuStatus.offline => i18n('mirror_danmaku_status_offline'),
      MirrorDanmakuStatus.failed => i18n('mirror_danmaku_status_failed'),
    };
  }

  Color _statusColor(BuildContext context, MirrorDanmakuTargetState target) {
    final scheme = Theme.of(context).colorScheme;
    if (!target.config.enabled) return scheme.outline;
    if (_mirror.globallyHidden) return scheme.outline;
    return switch (target.status) {
      MirrorDanmakuStatus.connected => Colors.green,
      MirrorDanmakuStatus.failed => scheme.error,
      MirrorDanmakuStatus.offline => scheme.tertiary,
      MirrorDanmakuStatus.resolving || MirrorDanmakuStatus.connecting => scheme.primary,
      MirrorDanmakuStatus.idle || MirrorDanmakuStatus.disabled => scheme.outline,
    };
  }

  String _platformName(String platform) {
    return platform.isNotEmpty && Sites.isSupported(platform) ? Sites.of(platform).name : platform;
  }

  String _targetLabel(MirrorDanmakuTargetState target) {
    final nick = target.target?.nick?.trim() ?? '';
    if (nick.isNotEmpty) return nick;
    final storedNick = target.config.nick.trim();
    if (storedNick.isNotEmpty) return storedNick;
    final title = target.target?.title?.trim() ?? '';
    if (title.isNotEmpty) return title;
    final storedTitle = target.config.title.trim();
    if (storedTitle.isNotEmpty) return storedTitle;
    return '${_platformName(target.config.platform)} ${target.config.roomId}'.trim();
  }

  String _targetSubtitle(MirrorDanmakuTargetState target) {
    final room = '${_platformName(target.config.platform)} ${target.config.roomId}'.trim();
    final title = target.target?.title?.trim() ?? target.config.title.trim();
    return title.isEmpty ? room : '$room · $title';
  }

  Widget _targetCard(BuildContext context, MirrorDanmakuTargetState target) {
    final busy = _busyTargets.contains(target.identityKey);
    final color = _statusColor(context, target);
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _targetLabel(target),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _targetSubtitle(target),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else
                  Switch(
                    key: ValueKey<String>('mirror-danmaku-target-switch-${target.identityKey}'),
                    value: target.config.enabled,
                    onChanged: (value) => _toggleTarget(target, value),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(_statusLabel(target), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color)),
            if (target.status == MirrorDanmakuStatus.failed && (target.message?.isNotEmpty ?? false))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  target.message!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: [
                if (target.config.enabled)
                  TextButton.icon(
                    onPressed: busy ? null : () => _retryTarget(target),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(i18n('mirror_danmaku_retry')),
                  ),
                TextButton.icon(
                  onPressed: busy ? null : () => _removeTarget(target),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: Text(i18n('mirror_danmaku_remove')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _roomSummary(BuildContext context, LiveRoom room, {required bool canConnect}) {
    final platform = room.normalizedPlatformId;
    final platformName = _platformName(platform);
    final lines = <String>[
      '${i18n('mirror_danmaku_platform')}: $platformName',
      '${i18n('mirror_danmaku_room_id')}: ${room.normalizedRoomId}',
      if ((room.nick ?? '').trim().isNotEmpty) '${i18n('mirror_danmaku_nick')}: ${room.nick!.trim()}',
      if ((room.title ?? '').trim().isNotEmpty) '${i18n('mirror_danmaku_room_title')}: ${room.title!.trim()}',
      '${i18n('mirror_danmaku_live_status')}: ${canConnect ? i18n('mirror_danmaku_live') : i18n('mirror_danmaku_offline')}',
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
        constraints: BoxConstraints(maxWidth: 600, maxHeight: maxHeight > 320 ? maxHeight : 320),
        child: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                  child: Obx(() {
                    final state = _mirror.state.value;
                    final atLimit = state.count >= _mirror.maxTargets;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(i18n('mirror_danmaku_title'), style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 8),
                        Text(i18n('mirror_danmaku_desc'), style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                i18n('mirror_danmaku_targets_title'),
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            Text('${state.count}/${_mirror.maxTargets}', style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (state.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              i18n('mirror_danmaku_no_target'),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          )
                        else
                          for (final target in state.targets) _targetCard(context, target),
                        const Divider(height: 32),
                        Text(i18n('mirror_danmaku_add_section'), style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 4),
                        SwitchListTile(
                          key: const ValueKey<String>('mirror-danmaku-add-switch'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(i18n('mirror_danmaku_enable')),
                          value: _enabled,
                          onChanged: _saving ? null : (value) => setState(() => _enabled = value),
                        ),
                        TextField(
                          controller: _url,
                          enabled: !_saving && !atLimit,
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
                              onPressed: _previewing || _saving || atLimit ? null : _runPreview,
                              child: Text(i18n(_previewing ? 'mirror_danmaku_previewing' : 'mirror_danmaku_preview')),
                            ),
                            FilledButton(
                              onPressed: _saving || _previewing || atLimit ? null : _addTarget,
                              child: Text(i18n('mirror_danmaku_add')),
                            ),
                          ],
                        ),
                        if (atLimit) ...[
                          const SizedBox(height: 8),
                          Text(
                            i18n('mirror_danmaku_limit_reached', args: {'max': '${_mirror.maxTargets}'}),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                        ] else if (_notice != null) ...[
                          const SizedBox(height: 12),
                          Text(_notice!, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                        ] else if (state.message != null) ...[
                          const SizedBox(height: 12),
                          Text(state.message!),
                        ],
                        if (_preview?.isSuccess == true && _preview?.room != null)
                          _roomSummary(context, _preview!.room!, canConnect: _preview!.canConnect),
                      ],
                    );
                  }),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    child: Text(i18n('mirror_danmaku_close')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
