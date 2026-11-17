import 'package:pure_live/core/models/live_room.dart';

/// One A room's persisted mirror-danmaku target.
///
/// Only non-sensitive room identity and display metadata are stored. The
/// resolved transport arguments, cookies and tokens are deliberately absent and
/// are fetched again for every room entry.
class MirrorDanmakuConfig {
  const MirrorDanmakuConfig({
    required this.platform,
    required this.roomId,
    this.sourceUrl = '',
    this.nick = '',
    this.title = '',
    this.enabled = true,
    this.version = currentVersion,
  });

  static const int currentVersion = 1;

  final String platform;
  final String roomId;
  final String sourceUrl;
  final String nick;
  final String title;
  final bool enabled;
  final int version;

  String get identityKey => '${platform.trim().toLowerCase()}:${roomId.trim()}';

  bool matchesHost(LiveRoom host) => host.identityKey == identityKey;

  MirrorDanmakuConfig copyWith({
    String? platform,
    String? roomId,
    String? sourceUrl,
    String? nick,
    String? title,
    bool? enabled,
    int? version,
  }) {
    return MirrorDanmakuConfig(
      platform: platform ?? this.platform,
      roomId: roomId ?? this.roomId,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      nick: nick ?? this.nick,
      title: title ?? this.title,
      enabled: enabled ?? this.enabled,
      version: version ?? this.version,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'version': version,
      'platform': platform,
      'roomId': roomId,
      'sourceUrl': sourceUrl,
      'nick': nick,
      'title': title,
      'enabled': enabled,
    };
  }

  static MirrorDanmakuConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = _readInt(raw['version']);
    if (version != currentVersion) return null;
    final platform = _readString(raw['platform']).trim().toLowerCase();
    final roomId = _readString(raw['roomId']).trim();
    if (platform.isEmpty || roomId.isEmpty) return null;
    return MirrorDanmakuConfig(
      platform: platform,
      roomId: roomId,
      sourceUrl: _readString(raw['sourceUrl']).trim(),
      nick: _readString(raw['nick']).trim(),
      title: _readString(raw['title']).trim(),
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : true,
      version: version,
    );
  }

  static String _readString(Object? value) => value is String ? value : '';

  static int _readInt(Object? value) => value is num ? value.toInt() : 0;

  @override
  String toString() {
    return 'MirrorDanmakuConfig{platform: $platform, roomId: $roomId, enabled: $enabled}';
  }
}
