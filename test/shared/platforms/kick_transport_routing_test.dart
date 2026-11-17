import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/domains/live/data/platforms/sites.dart';
import 'package:pure_live/shared/platforms/kick/kick_api.dart';
import 'package:pure_live/shared/platforms/kick/kick_link.dart';

void main() {
  group('Kick 传输路由', () {
    test('only kick.com API requests use the native TLS channel', () {
      // The room detail also fetches the IVS master playlist through the same
      // request function; the native channel only accepts kick.com, so routing
      // that playlist to it would make every Kick room hang.
      expect(KickApi.usesPlatformTls(Uri.parse('https://kick.com/api/v2/channels/westcol'), native: true), isTrue);
      expect(
        KickApi.usesPlatformTls(
          Uri.parse('https://fa723fc1b171.us-west-2.playback.live-video.net/api/video/v1/x.m3u8'),
          native: true,
        ),
        isFalse,
      );
      expect(KickApi.usesPlatformTls(Uri.parse('https://kick.com/api/v2/channels/westcol'), native: false), isFalse);
      expect(KickApi.usesPlatformTls(Uri.parse('http://kick.com/api/v2/channels/westcol'), native: true), isFalse);
      expect(KickApi.usesPlatformTls(Uri.parse('https://www.kick.com/api/v2/channels/westcol'), native: true), isFalse);
    });

    test('media headers address the channel page, not the API host', () {
      final headers = KickApi.mediaHeaders('Fixture');
      expect(headers['Referer'], 'https://kick.com/fixture/');
      expect(headers['Origin'], 'https://kick.com');
      expect(headers['User-Agent'], isNotEmpty);
      expect(() => KickApi.mediaHeaders('../bad'), throwsA(isA<FormatException>()));
    });

    test('channel links normalize to a slug without accepting reserved pages', () {
      expect(KickLink.parse('https://kick.com/Fixture'), 'fixture');
      expect(KickLink.parse('https://www.kick.com/fixture'), 'fixture');
      expect(KickLink.parse('https://kick.com/categories'), isNull);
      expect(KickLink.parse('https://example.com/fixture'), isNull);
    });

    test('Kick is registered and routable only on Windows', () {
      expect(Sites.isSupported(Sites.kickSite), Platform.isWindows);
      expect(Sites.isRetired(Sites.kickSite), !Platform.isWindows);
      expect(Sites.isRetiredLink('来 https://kick.com/fixture'), !Platform.isWindows);
      if (Platform.isWindows) {
        expect(Sites.logoForId(Sites.kickSite), endsWith('/kick.png'));
      }
    });
  });
}
