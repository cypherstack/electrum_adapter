import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:electrum_adapter/electrum_adapter.dart';
import 'package:test/test.dart';

import 'support/json_server.dart';

/// Sends [pieces] to [peer] one at a time, until it goes away.
Future<void> _send(Socket peer, List<List<int>> pieces) async {
  try {
    for (final piece in pieces) {
      peer.add(piece);
      await peer.flush();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  } on SocketException {
    // The client closed the connection.
  }
}

/// A valid JSON value that never ends: 2,000 bytes of an open array.
final _endless = [
  utf8.encode('['),
  for (var i = 0; i < 20; i++) utf8.encode('1,' * 50),
];

void main() {
  late ServerSocket server;
  late List<List<int>> pieces;

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((peer) {
      addTearDown(peer.destroy);
      peer.listen(null, onError: (Object _) {});
      _send(peer, pieces);
    });
  });

  Future<TransportChannel> open(int limit) => connect('127.0.0.1',
      port: server.port, useSSL: false, maxMessageBytes: limit);

  test('messages as long as the limit arrive, also in pieces', () async {
    final message = utf8.encode(jsonEncode({
      'jsonrpc': '2.0',
      'method': 'blockchain.headers.subscribe',
      'params': ['x' * 200],
    }));
    pieces = [
      message.sublist(0, 100),
      [...message.sublist(100), 10, ...message, 10],
    ];
    final channel = await open(message.length);
    addTearDown(channel.abort);
    final expected = jsonDecode(utf8.decode(message));
    expect(await channel.stream.take(2).toList(), [expected, expected]);
  });

  test('a longer message fails the stream and releases the connection',
      () async {
    pieces = _endless;
    final channel = await open(500);
    await expectLater(
        channel.stream,
        emitsInOrder([
          emitsError(isA<MessageTooLargeException>()
              .having((e) => e.limit, 'limit', 500)),
          emitsDone,
        ]));
    await channel.done.timeout(const Duration(seconds: 1));
  });

  test('a client fails with the error', () async {
    final json = await JsonServer.start();
    addTearDown(json.close);
    json.onRequest = (_) => _send(json.peers.single, _endless);
    final client = await ElectrumClient.connect(
        host: '127.0.0.1',
        port: json.port,
        useSSL: false,
        maxMessageBytes: 500);
    addTearDown(client.close);
    await expectLater(
        client.request('server.ping'),
        throwsA(isStateError.having(
            (e) => e.message, 'message', contains('MessageTooLarge'))));
    await expectLater(client.done, throwsA(isA<MessageTooLargeException>()));
  });

  test('the limit must be positive', () async {
    pieces = [];
    await expectLater(open(0), throwsArgumentError);
  });
}
