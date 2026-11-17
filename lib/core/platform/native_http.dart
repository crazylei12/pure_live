import 'dart:io';

import 'package:flutter/services.dart';

/// Windows WinHTTP bridge for hosts that reject dart:io's TLS fingerprint.
///
/// The Windows runner exposes `pure_live/native_http` and refuses every host
/// except kick.com. Other platforms report [supportsKick] as false so the Kick
/// adapter is not registered there.
class NativeHttp {
  const NativeHttp._();

  static const MethodChannel _channel = MethodChannel('pure_live/native_http');

  /// Kick is only exposed on Windows until another platform grows an accepted
  /// native TLS transport.
  static bool get supportsKick => Platform.isWindows;

  static Future<({int status, String body})> getKickJson({
    required String url,
    Map<String, String> headers = const <String, String>{},
    String? proxyHost,
    int? proxyPort,
    int timeoutMillis = 20000,
  }) async {
    final response = await _channel.invokeMapMethod<String, dynamic>('getKickJson', <String, dynamic>{
      'url': url,
      'headers': headers,
      if (proxyHost != null && proxyHost.isNotEmpty && proxyPort != null && proxyPort > 0) ...<String, dynamic>{
        'proxyHost': proxyHost,
        'proxyPort': proxyPort,
      },
      'timeoutMillis': timeoutMillis,
    });
    if (response == null) {
      throw PlatformException(code: 'native_http_failed', message: 'Empty native HTTP response');
    }
    final status = response['statusCode'];
    final body = response['body'];
    if (status is! int || body is! String) {
      throw PlatformException(code: 'native_http_failed', message: 'Malformed native HTTP response');
    }
    return (status: status, body: body);
  }
}
