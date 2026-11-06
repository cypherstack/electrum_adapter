import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:electrum_adapter/connect.dart';
import 'package:electrum_adapter/electrum_adapter.dart' show ElectrumClient;
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
        connectionTimeout: const Duration(milliseconds: 500),
        proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port));
    final input = channel.stream.drain<void>();
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(proxy.closed.isCompleted, isFalse);
    await channel.sink.close();
    await input;
    await proxy.closed.future.timeout(const Duration(seconds: 1));
  });

  for (final stage in ['greeting', 'connect', 'tls']) {
    test('the configured deadline closes a stalled $stage connection',
        () async {
      final proxy = SocksProxy(stage);
      await proxy.start();
      addTearDown(proxy.stop);
      final watch = Stopwatch()..start();
      await expectLater(
        connect('electrum.example.invalid',
            port: 50002,
            connectionTimeout: const Duration(milliseconds: 150),
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

  test('all proxy phases share one total deadline', () async {
    final proxy =
        SocksProxy('tls', stepDelay: const Duration(milliseconds: 80));
    await proxy.start();
    addTearDown(proxy.stop);
    final watch = Stopwatch()..start();
    await expectLater(
      connect('electrum.example.invalid',
          port: 50002,
          connectionTimeout: const Duration(milliseconds: 200),
          proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port)),
      throwsA(isA<TimeoutException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 350)));
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
      markTestSkipped('No SO_LINGER layout for this platform');
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
      markTestSkipped('No SO_LINGER layout for this platform');
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
