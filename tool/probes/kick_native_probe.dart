// Opt-in Windows probe for the pure_live/native_http method channel.
//
// The Windows integration_test runner in Flutter 3.47 deletes the generated
// cpp_client_wrapper sources before MSBuild runs, so this entrypoint verifies
// the same channel from a normally built runner instead:
//
//   flutter build windows --debug -t tool/probes/kick_native_probe.dart
//   build\windows\x64\runner\Debug\pure_live.exe
//
// The result is written to %TEMP%\pure_live_kick_probe.json.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:pure_live/core/platform/native_http.dart';
import 'package:pure_live/shared/platforms/kick/kick_api.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  final output = File('${Directory.systemTemp.path}${Platform.pathSeparator}pure_live_kick_probe.json');
  final result = <String, Object?>{};
  var code = 1;
  try {
    result['supportsKick'] = NativeHttp.supportsKick;
    final response = await NativeHttp.getKickJson(
      url: 'https://kick.com/stream/livestreams/en?page=1&limit=5',
      headers: KickApi.headers,
    );
    final decoded = jsonDecode(response.body);
    result['directoryStatus'] = response.status;
    result['directoryKeys'] = decoded is Map ? decoded.keys.toList() : const <Object?>[];
    code = response.status == 200 ? 0 : 2;
  } catch (error) {
    result['error'] = error.toString();
  }
  try {
    await NativeHttp.getKickJson(url: 'https://example.com/', headers: const {});
    result['rejectedOtherHost'] = false;
    code = code == 0 ? 3 : code;
  } catch (_) {
    result['rejectedOtherHost'] = true;
  }
  output.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
  exit(code);
}
