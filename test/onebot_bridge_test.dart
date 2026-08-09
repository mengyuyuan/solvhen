import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/services/onebot_bridge.dart';

void main() {
  const token = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFG';
  final bridge = OneBotBridge();

  setUp(() async {
    await bridge.stop();
    bridge.onMessage = null;
  });

  tearDown(() async {
    await bridge.stop();
    bridge.onMessage = null;
  });

  test('OneBot refuses startup without explicit insecure-LAN consent',
      () async {
    expect(
      await bridge.start(
        port: 0,
        accessToken: token,
        allowInsecureLan: false,
      ),
      isFalse,
    );
    expect(
      await bridge.start(
        port: 0,
        accessToken: 'short-token',
        allowInsecureLan: true,
      ),
      isFalse,
    );
  });

  test('OneBot requires a bearer token and rejects URL token leakage',
      () async {
    expect(
      await bridge.start(
        port: 0,
        accessToken: token,
        allowInsecureLan: true,
      ),
      isTrue,
    );
    final endpoint = 'ws://127.0.0.1:${bridge.port}/onebot';

    await expectLater(
      WebSocket.connect('$endpoint?access_token=$token'),
      throwsA(isA<WebSocketException>()),
    );

    final socket = await WebSocket.connect(
      endpoint,
      headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
    );
    await _waitForClientCount(bridge, 1);
    expect(bridge.clientCount, 1);
    await socket.close();
  });

  test('OneBot closes an oversized WebSocket frame', () async {
    expect(
      await bridge.start(
        port: 0,
        accessToken: token,
        allowInsecureLan: true,
      ),
      isTrue,
    );
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${bridge.port}/onebot',
      headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
    );
    final closed = socket.listen((_) {}).asFuture<void>();
    socket.add(List<String>.filled(70 * 1024, 'x').join());
    await closed.timeout(const Duration(seconds: 3));

    expect(socket.closeCode, WebSocketStatus.messageTooBig);
  });

  test('OneBot enforces client and per-minute message limits', () async {
    expect(
      await bridge.start(
        port: 0,
        accessToken: token,
        allowInsecureLan: true,
      ),
      isTrue,
    );
    final endpoint = 'ws://127.0.0.1:${bridge.port}/onebot';
    final headers = {HttpHeaders.authorizationHeader: 'Bearer $token'};
    final first = await WebSocket.connect(endpoint, headers: headers);
    final second = await WebSocket.connect(endpoint, headers: headers);
    await _waitForClientCount(bridge, 2);
    expect(bridge.clientCount, 2);
    await expectLater(
      WebSocket.connect(endpoint, headers: headers),
      throwsA(isA<WebSocketException>()),
    );

    final closed = first.listen((_) {}).asFuture<void>();
    for (var index = 0; index < 21; index++) {
      first.add('{}');
    }
    await closed.timeout(const Duration(seconds: 3));
    expect(first.closeCode, WebSocketStatus.policyViolation);
    await second.close();
  });
}

Future<void> _waitForClientCount(OneBotBridge bridge, int expected) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (bridge.clientCount == expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
