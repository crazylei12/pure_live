// Opt-in production-network probe: Kick public chat (Centrifugo gateway).
//
// Resolves the chatroom through the public channel response (fetched with curl
// on hosts where dart:io TLS is rejected), then runs the production KickApi and
// KickDanmaku against the live guest chat. Requires a live channel; pass a slug
// with PURELIVE_KICK_SLUG (default: xqc). Only aggregate counters are printed.
//
//   flutter test tool/probes/kick_chat_probe_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/network/http_client.dart';
import 'package:pure_live/shared/platforms/kick/kick_api.dart';
import 'package:pure_live/shared/platforms/kick/kick_danmaku.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final slug = io.Platform.environment['PURELIVE_KICK_SLUG']?.trim().isNotEmpty == true
      ? io.Platform.environment['PURELIVE_KICK_SLUG']!.trim()
      : 'xqc';

  test('Kick public chat delivers messages through the production engine', () async {
    final response = await io.Process.run('curl', [
      '-sS',
      '--max-time',
      '20',
      '-H',
      'User-Agent: ${KickApi.userAgent}',
      '-H',
      'Accept: application/json',
      'https://kick.com/api/v2/channels/$slug',
    ]);
    expect(response.exitCode, 0, reason: 'curl must fetch the public channel response');
    final channelBody = response.stdout as String;
    final channel = jsonDecode(channelBody) as Map<String, dynamic>;
    expect(channel['slug'], slug);
    final chatroomData = channel['chatroom'];
    final chatroom = chatroomData is Map ? chatroomData['id'] : null;
    expect(chatroom, isA<int>());

    final api = KickApi(request: (_, _) async => (status: 200, body: channelBody));
    final engine = KickDanmaku(api: api);
    final firstMessage = Completer<void>();
    var messages = 0;
    String? failure;
    engine.onMessage = (_) {
      messages++;
      if (!firstMessage.isCompleted) firstMessage.complete();
    };
    engine.onClose = (reason) {
      failure = reason;
      if (!firstMessage.isCompleted) firstMessage.completeError(StateError(reason));
    };
    await io.HttpOverrides.runWithHttpOverrides(() async {
      final previousDio = HttpClient.instance.dio;
      // The test harness has no GetX settings tree; a plain adapter keeps the
      // production POST/WebSocket code while avoiding app bootstrap.
      HttpClient.instance.dio = Dio()..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => io.HttpClient());
      try {
        await engine.start(slug);
        await firstMessage.future.timeout(const Duration(seconds: 40));
      } finally {
        await engine.stop();
        HttpClient.instance.dio = previousDio;
      }
    }, _RealNetwork());
    // ignore: avoid_print
    print(
      'kick chat probe: slug=$slug chatroom=${chatroom ?? '?'} messages=$messages'
      '${failure == null ? '' : ' failure=$failure'}',
    );
    expect(messages, greaterThan(0));
    expect(failure, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

class _RealNetwork extends io.HttpOverrides {}
