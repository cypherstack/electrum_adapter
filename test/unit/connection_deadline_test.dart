import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:electrum_adapter/client/base_client.dart';
import 'package:electrum_adapter/connect.dart';
import 'package:electrum_adapter/electrum_adapter.dart'
    show FiroElectrumClient, ElectrumClient;
import 'package:socks_socket/socks_socket.dart' show SocksConnectionException;
import 'package:test/test.dart';

import 'support/socks.dart';
import 'support/sockets.dart';

void main() {
  test('the connection deadline does not expire a completed connection',
      () async {
    final proxy = SocksProxy('none');
    await proxy.start();
    addTearDown(proxy.stop);
    // Long enough for a cold start under load to connect.
    final channel = await connect('electrum.example.invalid',
        port: 50001,
        useSSL: false,
        connectionDeadline: const Duration(milliseconds: 500),
        proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port));
    final input = channel.stream.drain<void>();
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(proxy.closed.isCompleted, isFalse);
    await channel.sink.close();
    await input;
    await proxy.closed.future.timeout(const Duration(seconds: 1));
  });

  for (final stage in ['greeting', 'connect', 'tls']) {
    test('a proxy phase timeout closes a stalled $stage without a deadline',
        () async {
      final proxy = SocksProxy(stage);
      await proxy.start();
      addTearDown(proxy.stop);
      const timeout = Duration(milliseconds: 200);
      await expectLater(
          connect('electrum.example.invalid',
              proxyHandshakeTimeout: timeout,
              useSSL: stage == 'tls',
              proxyInfo: (
                host: InternetAddress.loopbackIPv4,
                port: proxy.port
              )),
          throwsA(isA<ConnectionTimeoutException>()
              .having((e) => e.duration, 'duration', timeout)));
      await proxy.closed.future.timeout(const Duration(seconds: 1));
      if (stage == 'greeting') expect(proxy.connectRequests, isEmpty);
      if (stage == 'tls') expect(proxy.payload, isNotEmpty);
    });

    test('the configured deadline closes a stalled $stage connection',
        () async {
      final proxy = SocksProxy(stage);
      await proxy.start();
      addTearDown(proxy.stop);
      final watch = Stopwatch()..start();
      await expectLater(
        connect('electrum.example.invalid',
            port: 50002,
            connectionDeadline: const Duration(milliseconds: 150),
            useSSL: stage == 'tls',
            proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port)),
        throwsA(isA<TimeoutException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      // The expired attempt closed its connection to the proxy.
      await proxy.closed.future.timeout(const Duration(seconds: 1));
      if (stage == 'tls') expect(proxy.payload, isNotEmpty);
    });
  }

  test('each proxy phase gets a fresh timeout and ignores the direct TCP limit',
      () async {
    final proxy =
        SocksProxy('none', stepDelay: const Duration(milliseconds: 400));
    await proxy.start();
    addTearDown(proxy.stop);
    final watch = Stopwatch()..start();
    final channel = await connect('electrum.example.invalid',
        useSSL: false,
        connectionTimeout: const Duration(milliseconds: 50),
        proxyHandshakeTimeout: const Duration(milliseconds: 650),
        proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port));
    addTearDown(channel.abort);
    // Both phases succeeded within their own limit, despite exceeding one
    // phase's allowance in total. Timers must be cancelled on success too.
    expect(watch.elapsed, greaterThan(const Duration(milliseconds: 650)));
    final input = channel.stream.drain<void>();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(proxy.closed.isCompleted, isFalse);
    await channel.sink.close();
    await input;
    await proxy.closed.future.timeout(const Duration(seconds: 1));
  });

  test('an explicit total deadline still applies across fresh proxy phases',
      () async {
    final proxy =
        SocksProxy('none', stepDelay: const Duration(milliseconds: 400));
    await proxy.start();
    addTearDown(proxy.stop);
    await expectLater(
        connect('electrum.example.invalid',
            useSSL: false,
            proxyHandshakeTimeout: const Duration(milliseconds: 650),
            connectionDeadline: const Duration(milliseconds: 650),
            proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port)),
        throwsA(isA<ConnectionTimeoutException>()));
    await proxy.closed.future.timeout(const Duration(seconds: 1));
  });

  test('all proxy phases share one total deadline', () async {
    final proxy =
        SocksProxy('tls', stepDelay: const Duration(milliseconds: 80));
    await proxy.start();
    addTearDown(proxy.stop);
    final watch = Stopwatch()..start();
    await expectLater(
      connect('electrum.example.invalid',
          port: 50002,
          connectionDeadline: const Duration(milliseconds: 200),
          proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port)),
      throwsA(isA<TimeoutException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 350)));
    await proxy.closed.future.timeout(const Duration(seconds: 1));
  });

  test('SOCKS setup and protocol negotiation share one total deadline',
      () async {
    final proxy =
        SocksProxy('none', stepDelay: const Duration(milliseconds: 80));
    await proxy.start();
    addTearDown(proxy.stop);
    Timer? replyTimer;
    addTearDown(() => replyTimer?.cancel());
    proxy.onPayload = (peer, _) {
      replyTimer ??= Timer(const Duration(milliseconds: 180), () {
        peer.write('${jsonEncode({
              'jsonrpc': '2.0',
              'id': 0,
              'result': ['test', '1.4']
            })}\n');
      });
    };
    await expectLater(
        FiroElectrumClient.connect('electrum.example.invalid',
            port: 50001,
            useSSL: false,
            connectionDeadline: const Duration(milliseconds: 250),
            proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port)),
        throwsA(isA<TimeoutException>()));
    expect(proxy.payload, isNotEmpty);
    await proxy.closed.future.timeout(const Duration(seconds: 1));
  });

  test('an RPC deadline destroys an established SOCKS transport', () async {
    final proxy = SocksProxy('none');
    await proxy.start();
    addTearDown(proxy.stop);
    final client = await ElectrumClient.connect(
        host: 'electrum.example.invalid',
        port: 50001,
        useSSL: false,
        requestTimeout: const Duration(milliseconds: 100),
        proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port));
    addTearDown(client.close);
    await expectLater(
        client.request('silent'), throwsA(isA<TimeoutException>()));
    await proxy.closed.future.timeout(const Duration(seconds: 1));
  });

  test('close still sends a notification queued just before it', () async {
    final proxy = SocksProxy('none');
    await proxy.start();
    addTearDown(proxy.stop);
    final client = await ElectrumClient.connect(
        host: 'electrum.example.invalid',
        port: 50001,
        useSSL: false,
        proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port));
    client.peer.sendNotification('server.ping');
    client.peer.sendNotification('server.ping', ['again']);
    await client.close();
    await proxy.closed.future.timeout(const Duration(seconds: 1));
    final lines = utf8.decode(proxy.payload).trim().split('\n');
    expect(
        lines.map((line) => (jsonDecode(line) as Map)['params'] ?? <Object?>[]),
        [
          <Object?>[],
          ['again']
        ]);
  });

  test('a reply followed by graceful proxy EOF reaches its caller', () async {
    final proxy = await _replyThenClose();
    addTearDown(proxy.stop);
    final channel = await connect('electrum.example.invalid',
        port: 50001,
        useSSL: false,
        proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port));
    // Let the reply and the close both arrive before anything reads them.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final client = BaseClient(channel);
    expect(await client.request('first'), 'r0');
    // An uncaught error from the closed connection would fail this test.
    await expectLater(client.request('second'), throwsStateError);
    // Whether the request was written before the proxy's close was read
    // decides whether done reports the failed write.
    await client.done.then((_) {}, onError: (Object error) {
      expect(error, isA<SocksConnectionException>());
    });
  });

  test(
      'a reply immediately followed by a proxy reset may be lost but never hangs',
      () async {
    final linger = resetOption();
    if (linger == null) {
      markTestSkipped('Cannot force a reset on this platform');
      return;
    }
    final proxy = SocksProxy('none');
    await proxy.start();
    addTearDown(proxy.stop);
    proxy.onPayload = (peer, _) {
      if (!proxy.payload.contains(10)) return;
      proxy.onPayload = null;
      peer.setRawOption(linger);
      peer.write('{"jsonrpc":"2.0","id":0,"result":"r0"}\n');
      // Deliberately do not flush: a reset can discard the reply before it
      // reaches the client. Unlike graceful EOF, losing that reply is allowed.
      peer.destroy();
    };
    final transport = await connect('electrum.example.invalid',
        port: 50001,
        useSSL: false,
        proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port));
    addTearDown(transport.abort);
    final client = BaseClient(transport);
    addTearDown(client.close);
    final first = client.request('first').then<Object?>(
        (dynamic value) => value,
        onError: (Object error) => error);
    final second = expectLater(client.request('second'), throwsStateError);
    await expectLater(client.done, throwsA(isA<SocksConnectionException>()))
        .timeout(const Duration(seconds: 2));
    // Either the intact reply arrived before the reset, or the request failed
    // with the connection. The unanswered request must fail in either case.
    expect(await first.timeout(const Duration(seconds: 1)),
        anyOf('r0', isA<StateError>()));
    await second.timeout(const Duration(seconds: 1));
    await transport.done.timeout(const Duration(seconds: 1));
    expect(client.peer.isClosed, isTrue);
    await expectLater(client.request('later'), throwsStateError);
  });

  test('a proxy reset fails pending requests and reports its error in done',
      () async {
    final linger = resetOption();
    if (linger == null) {
      markTestSkipped('Cannot force a reset on this platform');
      return;
    }
    final proxy = SocksProxy('none');
    await proxy.start();
    addTearDown(proxy.stop);
    proxy.onPayload = (peer, _) {
      peer.setRawOption(linger);
      peer.destroy();
    };
    final client = await ElectrumClient.connect(
        host: 'electrum.example.invalid',
        port: 50001,
        useSSL: false,
        proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port));
    addTearDown(client.close);
    // As before, a lost connection fails pending requests with a StateError.
    await expectLater(
        client.request('reset'),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('SOCKS5 connection error'))));
    await expectLater(client.done, throwsA(isA<SocksConnectionException>()));
  });

  test('a request deadline releases a proxied transport that stopped reading',
      () async {
    final proxy = SocksProxy('none');
    await proxy.start();
    addTearDown(proxy.stop);
    final transport = await connect('electrum.example.invalid',
        port: 50001,
        useSSL: false,
        proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port));
    proxy.pauseReading();
    final client = BaseClient(transport,
        requestTimeout: const Duration(milliseconds: 200));
    addTearDown(client.close);
    await expectLater(
        client.request(
            'blockchain.transaction.broadcast', ['x' * (8 * 1024 * 1024)]),
        throwsA(isA<TimeoutException>()));
    // A graceful close would wait for the blocked write forever.
    await transport.done.timeout(const Duration(seconds: 1));
  });

  Future<TransportChannel> openTunnel(SocksProxy proxy,
          {bool useSSL = false}) =>
      connect('electrum.example.invalid',
          port: 50001,
          useSSL: useSSL,
          proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port));

  List<Object?> methods(List<int> payload) => const LineSplitter()
      .convert(utf8.decode(payload))
      .map((line) => (jsonDecode(line) as Map)['method'])
      .toList();

  test('cancelling a proxied stream keeps its connection writable', () async {
    final proxy = SocksProxy('none');
    await proxy.start();
    addTearDown(proxy.stop);
    proxy.onPayload = (peer, _) {
      if (proxy.payload.contains(10)) {
        peer.write('{"jsonrpc":"2.0","id":0,"result":"r0"}\n');
        proxy.onPayload = null;
      }
    };
    final channel = await openTunnel(proxy);
    channel.sink.add({'jsonrpc': '2.0', 'id': 0, 'method': 'first'});
    expect(await channel.stream.first, isA<Map<Object?, Object?>>());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    channel.sink.add({'jsonrpc': '2.0', 'method': 'second'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(methods(proxy.payload), ['first', 'second']);
    await channel.sink.close();
  });

  test(
      'closing an unlistened proxied channel releases it once the server '
      'closes', () async {
    final proxy = SocksProxy('none');
    await proxy.start();
    addTearDown(proxy.stop);
    proxy.onPayload = (peer, _) => peer.destroy();
    final transport = await openTunnel(proxy);
    transport.sink.add({'jsonrpc': '2.0', 'method': 'server.ping'});
    await transport.sink.close();
    await transport.done.timeout(const Duration(seconds: 1));
  });

  test('a reset after closing a proxied channel raises no uncaught error',
      () async {
    final linger = resetOption();
    if (linger == null) {
      markTestSkipped('Cannot force a reset on this platform');
      return;
    }
    final proxy = SocksProxy('none');
    await proxy.start();
    addTearDown(proxy.stop);
    // The proxy answers the client's close with a reset.
    proxy.onPayload = (peer, _) => peer.setRawOption(linger);
    final channel = await openTunnel(proxy);
    final errors = <Object>[];
    final ended =
        channel.stream.listen((_) {}, onError: errors.add).asFuture<void>();
    channel.sink.add({'jsonrpc': '2.0', 'method': 'server.ping'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await channel.sink.close();
    await ended.timeout(const Duration(seconds: 1));
    await channel.done.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(errors, isEmpty);
  });

  test('a reset during TLS through a proxy is a SOCKS connection error',
      () async {
    final linger = resetOption();
    if (linger == null) {
      markTestSkipped('Cannot force a reset on this platform');
      return;
    }
    final proxy = SocksProxy('none');
    await proxy.start();
    addTearDown(proxy.stop);
    // The tunnel resets on the ClientHello.
    proxy.onPayload = (peer, _) {
      peer.setRawOption(linger);
      peer.destroy();
    };
    await expectLater(
        openTunnel(proxy, useSSL: true),
        throwsA(isA<SocksConnectionException>().having((e) => e.message,
            'message', contains('Connection closed before SOCKS5'))));
  });
}

/// A proxy that sends a reply right after its CONNECT reply, then closes.
Future<SocksProxy> _replyThenClose() async {
  final proxy = SocksProxy('none')
    ..onConnected = (peer) {
      peer.write('{"jsonrpc":"2.0","id":0,"result":"r0"}\n');
      // Destroying the socket at once would cancel the write on Windows.
      peer.flush().whenComplete(peer.destroy).ignore();
    };
  await proxy.start();
  return proxy;
}
