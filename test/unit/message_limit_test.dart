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

  test('a longer line is skipped and reported, and the next line arrives',
      () async {
    pieces = [utf8.encode('[${'1,' * 300}1]\n{"n":2}\n')];
    final channel = await open(500);
    addTearDown(channel.abort);
    await expectLater(
        channel.stream,
        emitsInOrder([
          emitsError(isA<MessageTooLargeException>()
              .having((e) => e.limit, 'limit', 500)),
          {'n': 2},
        ]));
  });

  test(
      'closing the sink in a message handler drops a too-long line read with '
      'it', () async {
    // One read: a message, then a line over the limit.
    pieces = [
      [...utf8.encode('{"n":1}\n'), ..._endless.expand((piece) => piece)],
    ];
    final channel = await open(100);
    addTearDown(channel.abort);
    final received = <Object?>[];
    final errors = <Object>[];
    final ended = Completer<void>();
    channel.stream.listen((message) {
      received.add(message);
      channel.sink.close().ignore();
    }, onError: errors.add, onDone: ended.complete);
    var released = false;
    channel.done.whenComplete(() => released = true).ignore();
    await ended.future.timeout(const Duration(seconds: 1));
    expect(received, [
      {'n': 1}
    ]);
    expect(errors, isEmpty);
    // Nor did the line's size abort the graceful close; the server has not
    // closed its side.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(released, isFalse);
  });

  /// Connects to a server that sends a message, then a line over a 100-byte
  /// limit, in one write. Returns the channel once both have arrived, and the
  /// first data the server receives back.
  Future<(TransportChannel, Future<String>)> messageThenTooLong() async {
    final written = Completer<String>();
    final served = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(served.close);
    served.listen((peer) {
      addTearDown(peer.destroy);
      peer.listen((bytes) {
        if (!written.isCompleted) written.complete(utf8.decode(bytes));
      }, onError: (Object _) {});
      peer.add(
          [...utf8.encode('{"n":1}\n'), ..._endless.expand((piece) => piece)]);
    });
    final channel = await connect('127.0.0.1',
        port: served.port, useSSL: false, maxMessageBytes: 100);
    addTearDown(channel.abort);
    // Let all of it arrive, so that the first read holds both lines.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return (channel, written.future);
  }

  /// Checks that [channel] was not aborted and still writes.
  Future<void> expectWritable(
      TransportChannel channel, Future<String> written) async {
    var released = false;
    channel.done.whenComplete(() => released = true).ignore();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(released, isFalse);
    channel.sink.add({'jsonrpc': '2.0', 'method': 'server.ping', 'id': 1});
    expect(await written.timeout(const Duration(seconds: 1)),
        contains('server.ping'));
  }

  test('cancelling after a message leaves a too-long line read with it',
      () async {
    final (channel, written) = await messageThenTooLong();
    expect(await channel.stream.first, {'n': 1});
    // A too-long line does not fail the connection by itself.
    await expectWritable(channel, written);
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
