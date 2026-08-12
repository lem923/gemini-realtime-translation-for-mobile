import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:realtime_translation/live_translate/gemini_live_protocol.dart';

Future<void> main() async {
  final String apiKey = Platform.environment['GEMINI_API_KEY']?.trim() ?? '';
  if (apiKey.isEmpty) {
    stderr.writeln('Set GEMINI_API_KEY.');
    exitCode = 64;
    return;
  }

  final Uri endpoint = Uri.parse(
    GeminiLiveProtocol.endpoint,
  ).replace(queryParameters: <String, String>{'key': apiKey});
  final HttpClient client = HttpClient()
    ..findProxy = (Uri uri) => HttpClient.findProxyFromEnvironment(
      uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http'),
    );
  WebSocket? socket;
  try {
    socket = await WebSocket.connect(
      endpoint.toString(),
      customClient: client,
    ).timeout(const Duration(seconds: 20));
    stdout.writeln('websocket_connected=true');
    final Completer<void> done = Completer<void>();
    socket.listen(
      (Object? payload) {
        final Object? decoded;
        try {
          final String text = switch (payload) {
            final String value => value,
            final List<int> value => utf8.decode(value),
            _ => throw const FormatException('Unexpected frame type'),
          };
          decoded = jsonDecode(text);
        } on Object {
          stdout.writeln('server_message=unparseable');
          return;
        }
        if (decoded case <String, Object?>{'error': final Object? rawError}) {
          final Map<String, Object?> error = rawError as Map<String, Object?>;
          stdout.writeln(
            'server_message=error code=${error['code'] ?? 'unknown'} '
            'status=${error['status'] ?? 'unknown'}',
          );
        } else if (decoded case final Map<String, Object?> message) {
          stdout.writeln('server_message=${message.keys.join(',')}');
          if (message.containsKey('setupComplete') && !done.isCompleted) {
            done.complete();
          }
        }
      },
      onError: (Object error) {
        stdout.writeln('stream_error_type=${error.runtimeType}');
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        stdout.writeln(
          'websocket_closed code=${socket?.closeCode ?? 'unknown'}',
        );
        if (!done.isCompleted) done.complete();
      },
    );
    socket.add(GeminiLiveProtocol.setupMessage(targetLanguageCode: 'zh-Hans'));
    await done.future.timeout(const Duration(seconds: 20));
  } on TimeoutException {
    stdout.writeln('diagnostic_timeout=true');
    exitCode = 1;
  } on Object catch (error) {
    stdout.writeln('connect_error_type=${error.runtimeType}');
    exitCode = 1;
  } finally {
    await socket?.close();
    client.close(force: true);
  }
}
