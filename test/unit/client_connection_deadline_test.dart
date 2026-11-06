import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:electrum_adapter/client/base_client.dart';
import 'package:electrum_adapter/electrum_adapter.dart';
import 'package:test/test.dart';

import 'support/json_server.dart';
import 'support/sockets.dart';

void main() {
  test('direct TLS deadline aborts a peer that never handshakes', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final closed = Completer<void>();
    var receivedHello = false;
    server.listen((peer) {
      addTearDown(peer.destroy);
      peer.listen((_) => receivedHello = true, onDone: () {
        closed.complete();
        peer.destroy();
      }, onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      });
    });
    // Long enough for a cold start under load to send its hello.
    await expectLater(
        connect('127.0.0.1',
            port: server.port, connectionTimeout: const Duration(seconds: 1)),
        throwsA(isA<TimeoutException>()));
    expect(receivedHello, isTrue);
    await closed.future.timeout(const Duration(seconds: 1));
  });

  test('a connection timeout is a TimeoutException and a SocketException',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((peer) {
      addTearDown(peer.destroy);
      peer.listen((_) {}, onError: (Object _) {});
    });
    await expectLater(
        connect('127.0.0.1',
            port: server.port,
            connectionTimeout: const Duration(milliseconds: 100)),
        throwsA(allOf(isA<ConnectionTimeoutException>(),
            isA<TimeoutException>(), isA<SocketException>())));
  });

  test('a TLS deadline after partial handshake bytes closes the connection',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final closed = Completer<void>();
    server.listen((peer) {
      addTearDown(peer.destroy);
      var first = true;
      peer.listen((_) {
        // Half of a TLS handshake record, then nothing more.
        if (first)
          peer.add([0x16, 0x03, 0x03, 0x00, 0x50, ...List.filled(20, 0)]);
        first = false;
      }, onDone: () {
        if (!closed.isCompleted) closed.complete();
      }, onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      });
    });
    await expectLater(
        connect('127.0.0.1',
            port: server.port,
            connectionTimeout: const Duration(milliseconds: 150),
            acceptUnverified: true),
        throwsA(isA<TimeoutException>()));
    await closed.future.timeout(const Duration(seconds: 1));
  });

  test('close still sends a notification queued just before it', () async {
    final server = await JsonServer.start();
    addTearDown(server.close);
    final client = await ElectrumClient.connect(
        host: '127.0.0.1', port: server.port, useSSL: false);
    client.peer.sendNotification('server.ping');
    client.peer.sendNotification('server.ping', ['again']);
    await client.close();
    await server.disconnected.future.timeout(const Duration(seconds: 1));
    expect(server.requests.map((r) => r['params'] ?? <Object?>[]), [
      <Object?>[],
      ['again']
    ]);
  });

  test('closing the raw channel ends cleanly despite unread replies', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final outcome = Completer<String>();
    server.listen((peer) {
      addTearDown(peer.destroy);
      var received = 0;
      // Replies the client never reads.
      peer.add(List.filled(64 * 1024, 0x20));
      peer.listen((bytes) => received += bytes.length,
          onDone: () => outcome.complete('EOF after $received bytes'),
          onError: (Object error) => outcome.complete('$error'));
    });
    final channel =
        await connect('127.0.0.1', port: server.port, useSSL: false);
    // The server never closes its side.
    addTearDown(channel.abort);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final request = {'jsonrpc': '2.0', 'id': 7, 'method': 'server.ping'};
    channel.sink.add(request);
    await channel.sink.close();
    // A reset instead of EOF could also discard the request's bytes.
    expect(await outcome.future.timeout(const Duration(seconds: 2)),
        'EOF after ${utf8.encode('${jsonEncode(request)}\n').length} bytes');
  });

  test('closing the sink stops messages that already arrived', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((peer) {
      addTearDown(peer.destroy);
      peer.add(utf8.encode('{"n":1}\n{"n":2}\n{"n":3}\n'));
    });
    final channel =
        await connect('127.0.0.1', port: server.port, useSSL: false);
    addTearDown(channel.abort);
    final received = <Object?>[];
    final ended = Completer<void>();
    channel.stream.listen((message) {
      received.add(message);
      channel.sink.close().ignore();
    }, onDone: ended.complete);
    await ended.future.timeout(const Duration(seconds: 1));
    expect(received, [
      {'n': 1}
    ]);
  });

  group('over a real connection', () {
    late JsonServer server;
    late BaseClient client;

    setUp(() async {
      server = await JsonServer.start();
      addTearDown(server.close);
      final transport =
          await connect('127.0.0.1', port: server.port, useSSL: false);
      client = BaseClient(transport);
      addTearDown(client.close);
    });

    List<int> encode(Map<String, dynamic> request, Object? result) =>
        utf8.encode(jsonEncode(
            {'jsonrpc': '2.0', 'id': request['id'], 'result': result}));

    test('a malformed message split across reads does not affect the next',
        () async {
      server.onRequest = (request) {
        final peer = server.peers.single;
        peer.add(utf8.encode('{"broken":]'));
        Timer(const Duration(milliseconds: 20), () {
          // The rest of the malformed line, though it parses on its own.
          peer.add([...encode(request, 'wrong'), 10]);
          Timer(const Duration(milliseconds: 20),
              () => server.reply(request, 'ok'));
        });
      };
      expect(await client.request('after'), 'ok');
    });

    test('invalid UTF-8 in one message does not drop messages read with it',
        () async {
      server.onRequest = (request) {
        server.peers.single.add([
          ...utf8.encode('{"jsonrpc":"2.0","id":999,"result":"'),
          0xff,
          ...utf8.encode('"}\n'),
          ...encode(request, 'ok'),
          10
        ]);
      };
      expect(await client.request('mixed'), 'ok');
    });
  });

  test('close sends all queued output even when the server writes afterwards',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final closed = Completer<void>();
    final outcome = Completer<Object>();
    server.listen((peer) {
      final received = BytesBuilder(copy: false);
      final reading = peer.listen(received.add, onDone: () {
        outcome.complete(received.takeBytes());
        peer.destroy();
      }, onError: (Object error) {
        if (!outcome.isCompleted) outcome.complete(error);
      });
      // Stop reading, so the client's output is still queued when it closes.
      reading.pause();
      closed.future.then((_) async {
        // Input arriving after close() must not reset the connection.
        peer.write('{"jsonrpc":"2.0","method":"blockchain.headers.subscribe",'
            '"params":[{"height":1}]}\n');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        reading.resume();
      });
    });
    final client = await ElectrumClient.connect(
        host: '127.0.0.1', port: server.port, useSSL: false);
    final payload = 'x' * (4 * 1024 * 1024);
    client.peer.sendNotification('blockchain.transaction.broadcast', [payload]);
    await client.close();
    closed.complete();
    final result = await outcome.future.timeout(const Duration(seconds: 5));
    expect(result, isA<List<int>>());
    final message = jsonDecode(utf8.decode(result as List<int>)) as Map;
    expect((message['params'] as List).single, payload);
  });

  test(
      'cancelling a paused stream with unread input leaves the isolate '
      'running', () async {
    final results = ReceivePort();
    addTearDown(results.close);
    final isolate = await Isolate.spawn(_cancelWhilePaused, results.sendPort);
    addTearDown(() => isolate.kill(priority: Isolate.immediate));
    // On macOS, shutting down receiving here once left dart:io re-issuing
    // read events forever, so the isolate never reported back.
    expect(await results.first.timeout(const Duration(seconds: 5)), 'alive');
  });

  test('a reset after the sink closes raises no uncaught error', () async {
    final linger = resetOption();
    if (linger == null) {
      markTestSkipped('No SO_LINGER layout for this platform');
      return;
    }
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((peer) {
      peer.setRawOption(linger);
      // The server answers the client's close with a reset.
      peer.listen((_) {}, onDone: peer.destroy, onError: (Object _) {});
    });
    final channel =
        await connect('127.0.0.1', port: server.port, useSSL: false);
    final errors = <Object>[];
    final ended =
        channel.stream.listen((_) {}, onError: errors.add).asFuture<void>();
    await channel.sink.close();
    await ended.timeout(const Duration(seconds: 1));
    await channel.done.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(errors, isEmpty);
  });
}

/// Leaves an `await for` over a raw channel while the server's next message
/// waits unread, then reports whether timers still run.
Future<void> _cancelWhilePaused(SendPort results) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((peer) {
    peer.done.ignore();
    peer.listen((_) {}, onError: (Object _) {});
    final note = utf8.encode('{"jsonrpc":"2.0","method":'
        '"blockchain.headers.subscribe","params":[{"hex":"${'a' * 200}"}]}\n');
    peer.add(note);
    Timer(const Duration(milliseconds: 50), () => peer.add(note));
  });
  final channel = await connect('127.0.0.1', port: server.port, useSSL: false);
  await for (final _ in channel.stream) {
    // The second message arrives while this pauses the stream.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    break;
  }
  Timer(const Duration(milliseconds: 100), () => results.send('alive'));
}
