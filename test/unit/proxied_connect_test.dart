import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:electrum_adapter/client/base_client.dart';
import 'package:electrum_adapter/connect.dart';
import 'package:test/test.dart';

void main() {
  test('a proxied request reaches a server that closed its side', () async {
    final request = {
      'jsonrpc': '2.0',
      'method': 'blockchain.transaction.broadcast',
      'id': 0,
      'params': ['00' * (4 * 1024 * 1024)],
    };
    final expected = utf8.encode('${jsonEncode(request)}\n').length;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final received = Completer<int>();
    // A SOCKS5 proxy whose tunnel peer half-closes, then reads slowly.
    server.listen((peer) {
      addTearDown(peer.destroy);
      // SO_RCVBUF: keep the request queued on the sending side.
      final soRcvbuf = Platform.isLinux || Platform.isAndroid ? 8 : 0x1002;
      peer.setRawOption(RawSocketOption.fromInt(
          RawSocketOption.levelSocket, soRcvbuf, 65536));
      final buffer = <int>[];
      var tunnel = false;
      var count = 0;
      late StreamSubscription<List<int>> input;
      input = peer.listen((bytes) async {
        if (tunnel) {
          count += bytes.length;
          return;
        }
        buffer.addAll(bytes);
        if (buffer.length == 3) {
          peer.add([5, 0]);
        } else if (buffer.length > 8 && buffer.length == 10 + buffer[7]) {
          tunnel = true;
          input.pause();
          peer.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
          await peer.close();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          input.resume();
        }
      }, onDone: () => received.complete(count));
    });

    final channel = await connect(
      'localhost',
      port: 50001,
      useSSL: false,
      proxyInfo: (host: InternetAddress.loopbackIPv4, port: server.port),
    );
    // Clients keep listening for replies, so the EOF is seen mid-send.
    final replies = channel.stream.drain<void>();
    channel.sink.add(request);
    await replies;
    expect(
        await received.future.timeout(const Duration(seconds: 10)), expected);
  });

  test('closing the client closes the proxied connection', () async {
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(proxy.close);
    final closed = Completer<void>();
    // A SOCKS5 proxy that reports when the client ends the connection.
    proxy.listen((peer) {
      final buffer = <int>[];
      var tunnel = false;
      peer.listen((bytes) {
        if (tunnel) return;
        buffer.addAll(bytes);
        if (buffer.length == 3) {
          peer.add([5, 0]);
        } else if (buffer.length > 8 && buffer.length == 10 + buffer[7]) {
          tunnel = true;
          peer.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
        }
      }, onDone: () {
        if (!closed.isCompleted) closed.complete();
        peer.destroy();
      });
    });

    final client = BaseClient(await connect(
      'localhost',
      port: 50001,
      useSSL: false,
      proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port),
    ));
    await client.close();
    await closed.future.timeout(const Duration(seconds: 5));
  });
}
