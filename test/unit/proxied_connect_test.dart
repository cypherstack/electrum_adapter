import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:electrum_adapter/client/base_client.dart';
import 'package:electrum_adapter/connect.dart';
import 'package:socks_socket/socks_socket.dart';
import 'package:test/test.dart';

import 'support/socks.dart';
import 'support/sockets.dart';

void main() {
  test('a proxy reset fails the input and output and permits disposal',
      () async {
    final proxy = SocksProxy('none');
    final accepted = Completer<Socket>();
    proxy.onConnected = accepted.complete;
    await proxy.start();
    addTearDown(proxy.stop);

    final channel = await connect(
      'localhost',
      port: 50001,
      useSSL: false,
      proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port),
    );
    final errors = <Object>[];
    final done = Completer<void>();
    channel.stream.listen((_) {}, onError: errors.add, onDone: done.complete);
    final outputFailed = expectLater(
        channel.sink.done, throwsA(isA<SocksConnectionException>()));
    final peer = await accepted.future;
    // Reset instead of graceful EOF.
    peer.setRawOption(resetOption()!);
    peer.destroy();

    await done.future.timeout(const Duration(seconds: 5));
    await outputFailed.timeout(const Duration(seconds: 5));
    expect(errors, [isA<SocksConnectionException>()]);
    await expectLater(
        channel.sink.close(), throwsA(isA<SocksConnectionException>()));
  }, testOn: 'linux || mac-os');

  test('a proxied request reaches a server that closed its side', () async {
    final request = {
      'jsonrpc': '2.0',
      'method': 'blockchain.transaction.broadcast',
      'id': 0,
      'params': ['00' * (4 * 1024 * 1024)],
    };
    final expected = utf8.encode('${jsonEncode(request)}\n').length;
    // A SOCKS5 proxy whose tunnel peer half-closes, then reads slowly.
    final proxy = SocksProxy('none')
      // SO_RCVBUF: keep the request queued on the sending side.
      ..onAccept = (peer) => peer.setRawOption(RawSocketOption.fromInt(
          RawSocketOption.levelSocket,
          Platform.isLinux || Platform.isAndroid ? 8 : 0x1002,
          65536));
    proxy.onConnected = (peer) async {
      proxy.pauseReading();
      await peer.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      proxy.resumeReading();
    };
    await proxy.start();
    addTearDown(proxy.stop);

    final channel = await connect(
      'localhost',
      port: 50001,
      useSSL: false,
      proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port),
    );
    // Clients keep listening for replies, so the EOF is seen mid-send.
    final replies = channel.stream.drain<void>();
    channel.sink.add(request);
    await replies;
    await proxy.closed.future.timeout(const Duration(seconds: 10));
    expect(proxy.payload.length, expected);
  });

  test('targets reach the proxy with their address type', () async {
    // CONNECT, then the address type and address, then port 50001.
    final targets = {
      '127.0.0.1': [1, 127, 0, 0, 1],
      '::1': [4, ...List.filled(15, 0), 1],
      'localhost': [3, 9, ...'localhost'.codeUnits],
    };
    for (final MapEntry(key: host, value: address) in targets.entries) {
      final proxy = SocksProxy('none');
      await proxy.start();
      addTearDown(proxy.stop);
      final channel = await connect(host,
          port: 50001,
          useSSL: false,
          connectionTimeout: const Duration(seconds: 2),
          proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port));
      expect(
          proxy.connectRequests,
          [
            [5, 1, 0, ...address, 0xc3, 0x51]
          ],
          reason: host);
      channel.abort();
    }
    expect(socksRequestLength([5, 1, 0, 1, 127, 0, 0, 1, 0, 80]), 10);
    expect(socksRequestLength([5, 1, 0, 4, ...List.filled(18, 0)]), 22);
    expect(socksRequestLength([5, 1, 0, 3, 1, 120, 0]), isNull);
  });

  test('closing the client closes the proxied connection', () async {
    final proxy = SocksProxy('none');
    await proxy.start();
    addTearDown(proxy.stop);

    final client = BaseClient(await connect(
      'localhost',
      port: 50001,
      useSSL: false,
      proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port),
    ));
    await client.close();
    await proxy.closed.future.timeout(const Duration(seconds: 5));
  });
}
