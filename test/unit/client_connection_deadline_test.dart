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
            port: server.port, connectionDeadline: const Duration(seconds: 1)),
        throwsA(isA<TimeoutException>()));
    expect(receivedHello, isTrue);
    await closed.future.timeout(const Duration(seconds: 1));
  });

  for (final kind in ['firo', 'raven']) {
    Future<ElectrumClient> open(JsonServer server,
            {Duration? connectionDeadline = const Duration(milliseconds: 150),
            Duration? connectionTimeout,
            Duration? requestTimeout = const Duration(seconds: 10)}) =>
        kind == 'firo'
            ? FiroElectrumClient.connect('127.0.0.1',
                port: server.port,
                useSSL: false,
                connectionTimeout: connectionTimeout,
                connectionDeadline: connectionDeadline,
                requestTimeout: requestTimeout)
            : RavenElectrumClient.connect('127.0.0.1',
                port: server.port,
                useSSL: false,
                connectionTimeout: connectionTimeout,
                connectionDeadline: connectionDeadline,
                requestTimeout: requestTimeout);

    test('$kind has no implicit deadline for server.version', () async {
      final server = await JsonServer.start();
      addTearDown(server.close);
      // Longer than the old five-second overall budget. TCP is already open,
      // so neither its default nor an explicit TCP timeout may end this RPC.
      server.onRequest = (request) {
        final timer = Timer(const Duration(seconds: 6),
            () => server.reply(request, ['test', '1.4']));
        addTearDown(timer.cancel);
      };
      final client = await open(server,
          connectionDeadline: null,
          connectionTimeout: const Duration(seconds: 1),
          requestTimeout: null);
      addTearDown(client.close);
      expect(client.peer.isClosed, isFalse);
      expect(client.requestTimeout, isNull);
    });

    test('$kind negotiation honors requestTimeout without a setup deadline',
        () async {
      final server = await JsonServer.start();
      addTearDown(server.close);
      await expectLater(
          open(server,
              connectionDeadline: null,
              requestTimeout: const Duration(milliseconds: 150)),
          throwsA(allOf(isA<TimeoutException>(),
              isNot(isA<ConnectionTimeoutException>()))));
      expect(server.requests.single['method'], 'server.version');
      await server.disconnected.future.timeout(const Duration(seconds: 1));
    });

    test('$kind connection deadline includes server.version', () async {
      final server = await JsonServer.start();
      addTearDown(server.close);
      final watch = Stopwatch()..start();
      // The connection deadline, not the 10 s request deadline, ends it.
      await expectLater(
          open(server),
          throwsA(isA<ConnectionTimeoutException>()
              .having((e) => e.message, 'message', contains('negotiation'))));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(server.requests.single['method'], 'server.version');
      await server.disconnected.future.timeout(const Duration(seconds: 1));
    });

    test(
        '$kind negotiation may use the connection budget beyond requestTimeout',
        () async {
      final server = await JsonServer.start();
      addTearDown(server.close);
      server.onRequest = (request) => Timer(const Duration(milliseconds: 300),
          () => server.reply(request, ['ElectrumX 1.16', '1.4']));
      final client = await (kind == 'firo'
          ? FiroElectrumClient.connect('127.0.0.1',
              port: server.port,
              useSSL: false,
              connectionDeadline: const Duration(seconds: 3),
              requestTimeout: const Duration(milliseconds: 100))
          : RavenElectrumClient.connect('127.0.0.1',
              port: server.port,
              useSSL: false,
              connectionDeadline: const Duration(seconds: 3),
              requestTimeout: const Duration(milliseconds: 100)));
      addTearDown(client.close);
      expect(client.peer.isClosed, isFalse);
    });

    test(
        '$kind negotiation expiry is a connection timeout despite a shorter '
        'requestTimeout', () async {
      final server = await JsonServer.start();
      addTearDown(server.close);
      await expectLater(
          open(server, requestTimeout: const Duration(milliseconds: 50)),
          throwsA(isA<ConnectionTimeoutException>()
              .having((e) => e.message, 'message', contains('negotiation'))));
    });

    test('$kind releases the connection on malformed server.version', () async {
      final server = await JsonServer.start();
      addTearDown(server.close);
      server.onRequest = (request) => server.reply(request, 42);
      await expectLater(open(server), throwsA(isA<Error>()));
      await server.disconnected.future.timeout(const Duration(seconds: 1));
    });

    test('$kind negotiated client retains its configured RPC deadline',
        () async {
      final server = await JsonServer.start();
      addTearDown(server.close);
      server.onRequest = (request) {
        if (request['method'] == 'server.version')
          server.reply(request, ['test', '1.4']);
      };
      final client =
          await open(server, requestTimeout: const Duration(milliseconds: 100));
      addTearDown(client.close);
      expect(client.requestTimeout, const Duration(milliseconds: 100));
      await expectLater(
          client.request('silent'), throwsA(isA<TimeoutException>()));
      await server.disconnected.future.timeout(const Duration(seconds: 1));
    });

    test('$kind completed initialization cancels the setup deadline', () async {
      final server = await JsonServer.start();
      addTearDown(server.close);
      server.onRequest = (request) => server.reply(request, ['test', '1.4']);
      final client = await open(server);
      addTearDown(client.close);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(client.peer.isClosed, isFalse);
      expect(await client.request('still.connected'), ['test', '1.4']);
    });
  }

  test('a silent RPC aborts the actual TCP transport', () async {
    final server = await JsonServer.start();
    addTearDown(server.close);
    final client = await ElectrumClient.connect(
        host: '127.0.0.1',
        port: server.port,
        useSSL: false,
        requestTimeout: const Duration(milliseconds: 100));
    addTearDown(client.close);
    await expectLater(
        client.request('silent'), throwsA(isA<TimeoutException>()));
    await server.disconnected.future.timeout(const Duration(seconds: 1));
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
            connectionDeadline: const Duration(milliseconds: 100)),
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
            connectionDeadline: const Duration(milliseconds: 150),
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

  test('a reply cut off by the server closing ends the client at once',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((peer) {
      peer.listen((_) {
        peer.write('{"jsonrpc":"2.0","id":0,"res');
        peer.close();
      }, onError: (Object _) {});
    });
    final client = await ElectrumClient.connect(
        host: '127.0.0.1',
        port: server.port,
        useSSL: false,
        requestTimeout: const Duration(seconds: 30));
    addTearDown(client.close);
    await expectLater(client.request('truncated'), throwsStateError)
        .timeout(const Duration(seconds: 2));
    await client.done.timeout(const Duration(seconds: 1));
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

  test('closing the sink drops messages a paused listener has not received',
      () async {
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
    final first = Completer<void>();
    final ended = Completer<void>();
    late StreamSubscription<dynamic> subscription;
    subscription = channel.stream.listen((message) {
      received.add(message);
      // The rest of the read is decoded meanwhile, and waits.
      subscription.pause();
      first.complete();
    }, onDone: ended.complete);
    await first.future.timeout(const Duration(seconds: 1));
    await channel.sink.close();
    subscription.resume();
    await ended.future.timeout(const Duration(seconds: 1));
    expect(received, [
      {'n': 1}
    ]);
  });

  test('closing the sink after a resume stops at the message it closed in',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((peer) {
      addTearDown(peer.destroy);
      peer.add(utf8.encode('{"n":1}\n{"n":2}\n{"n":3}\n'));
    });
    final channel =
        await connect('127.0.0.1', port: server.port, useSSL: false);
    addTearDown(channel.abort);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final received = <Object?>[];
    final first = Completer<void>();
    final ended = Completer<void>();
    late StreamSubscription<dynamic> subscription;
    subscription = channel.stream.listen((message) {
      received.add(message);
      if (received.length == 1) {
        subscription.pause();
        first.complete();
      } else {
        channel.sink.close().ignore();
      }
    }, onDone: ended.complete);
    await first.future.timeout(const Duration(seconds: 1));
    subscription.resume();
    await ended.future.timeout(const Duration(seconds: 1));
    expect(received, [
      {'n': 1},
      {'n': 2}
    ]);
  });

  test('a close rejected while a stream is being added leaves the stream open',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final accepted = Completer<Socket>();
    server.listen((peer) {
      addTearDown(peer.destroy);
      peer.listen(null, onError: (Object _) {});
      accepted.complete(peer);
    });
    final channel =
        await connect('127.0.0.1', port: server.port, useSSL: false);
    addTearDown(channel.abort);
    final source = StreamController<dynamic>();
    final adding = channel.sink.addStream(source.stream);
    expect(channel.sink.close, throwsStateError);
    final first = channel.stream.first;
    (await accepted.future).add(utf8.encode('{"n":1}\n'));
    expect(await first.timeout(const Duration(seconds: 1)), {'n': 1});
    await source.close();
    await adding;
  });

  test('a request deadline releases a transport whose server stopped reading',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final received = Completer<int>();
    late StreamSubscription<List<int>> reading;
    server.listen((peer) {
      addTearDown(peer.destroy);
      var count = 0;
      reading = peer.listen((bytes) => count += bytes.length,
          onDone: () => received.complete(count),
          onError: (Object _) => received.complete(count));
      reading.pause();
    });
    final transport =
        await connect('127.0.0.1', port: server.port, useSSL: false);
    final client = BaseClient(transport,
        requestTimeout: const Duration(milliseconds: 200));
    addTearDown(client.close);
    final payload = 'x' * (8 * 1024 * 1024);
    await expectLater(
        client.request('blockchain.transaction.broadcast', [payload]),
        throwsA(isA<TimeoutException>()));
    // A graceful close would wait for the blocked write forever.
    await transport.done.timeout(const Duration(seconds: 1));
    reading.resume();
    expect(await received.future.timeout(const Duration(seconds: 5)),
        lessThan(payload.length));
  });

  group('over a real connection', () {
    late JsonServer server;
    late BaseClient client;

    setUp(() async {
      server = await JsonServer.start();
      addTearDown(server.close);
      final transport =
          await connect('127.0.0.1', port: server.port, useSSL: false);
      client = BaseClient(transport,
          requestTimeout: const Duration(milliseconds: 200));
      addTearDown(client.close);
    });

    List<int> encode(Map<String, dynamic> request, Object? result) =>
        utf8.encode(jsonEncode(
            {'jsonrpc': '2.0', 'id': request['id'], 'result': result}));

    test('a reply whose newline arrives later does not hold back a deadline',
        () async {
      server.onRequest = (request) {
        if (request['method'] != 'answered') return;
        final peer = server.peers.single;
        peer.add(encode(request, 'ok'));
        Timer(const Duration(milliseconds: 30), () => peer.add([10]));
      };
      final watch = Stopwatch()..start();
      final silent = expectLater(
          client.request('silent'), throwsA(isA<TimeoutException>()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await client.request('answered'), 'ok');
      await silent;
      // The server answers, so the silent request fails alone, on time.
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 800)));
      expect(client.peer.isClosed, isFalse);
    });

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

  test('a wrapped channel keeps its transport byte count', () async {
    final server = await JsonServer.start();
    addTearDown(server.close);
    // A long reply arrives in pieces over several deadlines of another
    // request, which the server never answers.
    server.onRequest = (request) {
      if (request['method'] != 'long') return;
      final reply = utf8.encode('${jsonEncode({
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': 'x' * 3000
          })}\n');
      var sent = 0;
      final peer = server.peers.single;
      final pieces = Timer.periodic(const Duration(milliseconds: 20), (timer) {
        final end = sent + 100 < reply.length ? sent + 100 : reply.length;
        peer.add(reply.sublist(sent, end));
        sent = end;
        if (sent == reply.length) timer.cancel();
      });
      addTearDown(pieces.cancel);
    };
    final transport =
        await connect('127.0.0.1', port: server.port, useSSL: false);
    final logged = <Object?>[];
    final client = BaseClient(transport.withChannel(transport.transformStream(
        StreamTransformer<dynamic, dynamic>.fromHandlers(
            handleData: (message, sink) {
      logged.add(message);
      sink.add(message);
    }))), requestTimeout: const Duration(milliseconds: 150));
    addTearDown(client.close);
    // The silent request is the oldest, so only bytes of the long reply,
    // arriving during its deadline, keep the connection open.
    final silent =
        expectLater(client.request('silent'), throwsA(isA<TimeoutException>()));
    final long =
        client.requestWithTimeout('long', timeout: const Duration(seconds: 5));
    await silent;
    expect(client.peer.isClosed, isFalse);
    expect(await long, 'x' * 3000);
    expect(logged, hasLength(1));
  });

  test('a last reply without a newline reaches its caller', () async {
    final server = await JsonServer.start();
    addTearDown(server.close);
    server.onRequest = (request) {
      final peer = server.peers.single;
      peer.add(utf8.encode(jsonEncode(
          {'jsonrpc': '2.0', 'id': request['id'], 'result': 'last'})));
      // The server ends the connection without ending the line.
      peer.close().ignore();
    };
    final client = BaseClient(
        await connect('127.0.0.1', port: server.port, useSSL: false));
    addTearDown(client.close);
    expect(await client.request('final'), 'last');
    await client.done;
  });

  test('large plaintext requests and responses preserve every byte', () async {
    final server = await JsonServer.start();
    addTearDown(server.close);
    server.onRequest = (request) => server.reply(request, request['params']);
    final client = await ElectrumClient.connect(
        host: '127.0.0.1',
        port: server.port,
        useSSL: false,
        requestTimeout: const Duration(seconds: 5));
    addTearDown(client.close);
    final payload = List<String>.generate(200000, (i) => '${i % 100},').join();
    expect(await client.request('echo', [payload]), [payload]);
  });

  test('a reply cut off inside a UTF-8 character ends the client at once',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((peer) {
      peer.listen((_) {
        // The first byte of a two-byte character, then the server closes.
        peer.add(
            [...utf8.encode('{"jsonrpc":"2.0","id":0,"result":"caf'), 0xc3]);
        peer.close();
      }, onError: (Object _) {});
    });
    final client = await ElectrumClient.connect(
        host: '127.0.0.1',
        port: server.port,
        useSSL: false,
        requestTimeout: const Duration(seconds: 30));
    addTearDown(client.close);
    await expectLater(client.request('truncated'), throwsStateError)
        .timeout(const Duration(seconds: 2));
    await client.done.timeout(const Duration(seconds: 1));
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
      markTestSkipped('Cannot force a reset on this platform');
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

  test('invalid deadlines are rejected before opening a connection', () async {
    final server = await JsonServer.start();
    addTearDown(server.close);
    for (final timeout in [Duration.zero, const Duration(seconds: -1)]) {
      await expectLater(
          connect('127.0.0.1', port: server.port, connectionTimeout: timeout),
          throwsArgumentError);
      await expectLater(
          connect('127.0.0.1', port: server.port, connectionDeadline: timeout),
          throwsArgumentError);
      await expectLater(
          connect('127.0.0.1',
              port: server.port, proxyHandshakeTimeout: timeout),
          throwsArgumentError);
      await expectLater(
          ElectrumClient.connect(
              host: '127.0.0.1',
              port: server.port,
              connectionDeadline: timeout),
          throwsArgumentError);
      await expectLater(
          FiroElectrumClient.connect('127.0.0.1',
              port: server.port, proxyHandshakeTimeout: timeout),
          throwsArgumentError);
      await expectLater(
          RavenElectrumClient.connect('127.0.0.1',
              port: server.port, connectionDeadline: timeout),
          throwsArgumentError);
      await expectLater(
          ElectrumClient.connect(
              host: '127.0.0.1', port: server.port, requestTimeout: timeout),
          throwsArgumentError);
    }
    expect(server.peers, isEmpty);
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
