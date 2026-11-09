import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:electrum_adapter/electrum_adapter.dart';
import 'package:test/test.dart';

import 'support/json_server.dart';
import 'support/socks.dart';

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
  late Completer<void> disconnected;

  setUp(() async {
    disconnected = Completer<void>();
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((peer) {
      addTearDown(peer.destroy);
      void ended() {
        if (!disconnected.isCompleted) disconnected.complete();
        // Keep the server's sending side open until teardown. A client that
        // only half-closes must not look like it released the whole transport.
      }

      peer.listen(null, onDone: ended, onError: (Object _) => ended());
      _send(peer, pieces);
    });
  });

  Future<TransportChannel> open(int? limit) => connect('127.0.0.1',
      port: server.port, useSSL: false, maxMessageBytes: limit);

  test('messages as long as the limit arrive, also in pieces', () async {
    final message = utf8.encode(jsonEncode({
      'jsonrpc': '2.0',
      'method': 'blockchain.headers.subscribe',
      'params': ['é' * 100],
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

  test('a longer line reports one error, aborts, and drops subsequent messages',
      () async {
    pieces = [utf8.encode('[${'1,' * 300}1]\n{"n":2}\n')];
    final channel = await open(500);
    addTearDown(channel.abort);
    await expectLater(
        channel.stream,
        emitsInOrder([
          emitsError(isA<MessageTooLargeException>()
              .having((e) => e.limit, 'limit', 500)),
          emitsDone,
        ]));
    await channel.done.timeout(const Duration(seconds: 1));
    await disconnected.future.timeout(const Duration(seconds: 1));
    await expectLater(
        channel.sink.done, throwsA(isA<MessageTooLargeException>()));
    await expectLater(
        channel.sink.close(), throwsA(isA<MessageTooLargeException>()));
  });

  for (final malformed in [false, true]) {
    test(
        'an unfinished ${malformed ? 'malformed' : 'valid'} line aborts at the limit',
        () async {
      pieces = [
        if (malformed) utf8.encode('not JSON'),
        ..._endless,
      ];
      final channel = await open(500);
      addTearDown(channel.abort);
      await expectLater(
          channel.stream,
          emitsInOrder([
            emitsError(isA<MessageTooLargeException>()),
            emitsDone,
          ]));
      await channel.done.timeout(const Duration(seconds: 1));
      await disconnected.future.timeout(const Duration(seconds: 1));
    });
  }

  test('without a configured limit a large message still arrives', () async {
    final message = {'value': 'x' * 10000};
    pieces = [utf8.encode('${jsonEncode(message)}\n')];
    final channel = await open(null);
    addTearDown(channel.abort);
    expect(await channel.stream.first, message);
  });

  test('an oversized message aborts a proxy tunnel with the original error',
      () async {
    final proxy = SocksProxy('none')
      ..onConnected = (peer) => _send(peer, _endless);
    await proxy.start();
    addTearDown(proxy.stop);
    final channel = await connect('electrum.example.invalid',
        useSSL: false,
        maxMessageBytes: 500,
        proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port));
    addTearDown(channel.abort);
    await expectLater(
        channel.stream,
        emitsInOrder([
          emitsError(isA<MessageTooLargeException>()),
          emitsDone,
        ]));
    await channel.done.timeout(const Duration(seconds: 1));
    await proxy.closed.future.timeout(const Duration(seconds: 1));
    await expectLater(
        channel.sink.done, throwsA(isA<MessageTooLargeException>()));
  });

  test(
      'closing the sink suppresses a later stream error but still aborts on '
      'a too-long line read with it', () async {
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
    await ended.future.timeout(const Duration(seconds: 1));
    expect(received, [
      {'n': 1}
    ]);
    expect(errors, isEmpty);
    await channel.done.timeout(const Duration(seconds: 1));
    await disconnected.future.timeout(const Duration(seconds: 1));
  });

  /// Connects to a server that sends a message, then a line over a 100-byte
  /// limit, in one write. Returns before anything has listened to the channel.
  Future<TransportChannel> messageThenTooLong() async {
    pieces = [
      [...utf8.encode('{"n":1}\n'), ..._endless.expand((piece) => piece)],
    ];
    final channel = await open(100);
    addTearDown(channel.abort);
    // Let all of it arrive, so that the first read holds both lines.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return channel;
  }

  test(
      'cancelling after a message still aborts on a too-long line read with it',
      () async {
    final channel = await messageThenTooLong();
    expect(await channel.stream.first, {'n': 1});
    await channel.done.timeout(const Duration(seconds: 1));
    await disconnected.future.timeout(const Duration(seconds: 1));
    await expectLater(
        channel.sink.done, throwsA(isA<MessageTooLargeException>()));
  });

  for (final cancel in [false, true]) {
    test(
        'a paused stream ${cancel ? 'can cancel' : 'gets the error on resume'} after an immediate abort',
        () async {
      final channel = await messageThenTooLong();
      final paused = Completer<void>();
      final ended = Completer<void>();
      final errors = <Object>[];
      late StreamSubscription<dynamic> subscription;
      subscription = channel.stream.listen((dynamic message) {
        expect(message, {'n': 1});
        subscription.pause();
        paused.complete();
      }, onError: errors.add, onDone: ended.complete);
      addTearDown(subscription.cancel);
      await paused.future.timeout(const Duration(seconds: 1));
      // Release does not depend on resuming to deliver the queued error.
      await channel.done.timeout(const Duration(seconds: 1));
      await disconnected.future.timeout(const Duration(seconds: 1));
      expect(errors, isEmpty);
      await expectLater(
          channel.sink.done, throwsA(isA<MessageTooLargeException>()));
      if (cancel) {
        await subscription.cancel();
      } else {
        subscription.resume();
        await ended.future.timeout(const Duration(seconds: 1));
        expect(errors, [isA<MessageTooLargeException>()]);
      }
    });
  }

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
