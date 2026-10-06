import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:electrum_adapter/electrum_adapter.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

const _reply = {'jsonrpc': '2.0', 'id': 0, 'result': 'ok'};

void main() {
  // The certificate is made per run: Apple platforms cap a TLS server
  // certificate's validity, so a committed one would expire.
  if (!_hasOpenssl()) {
    test('TLS with a self-signed certificate', () {},
        skip: 'needs openssl on PATH');
    return;
  }
  // Nullable so cleanup copes with a setup that failed partway.
  Directory? dir;
  SecureServerSocket? bound;
  late String certPath;
  late SecureServerSocket server;

  setUpAll(() async {
    final tmp =
        dir = await Directory.systemTemp.createTemp('electrum_adapter_tls');
    certPath = '${tmp.path}/cert.pem';
    final keyPath = '${tmp.path}/key.pem';
    // A self-signed certificate, as on a personal Electrum server. Apple
    // platforms reject a server certificate without the serverAuth usage.
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      // LibreSSL, macOS's /usr/bin/openssl, otherwise writes explicit curve
      // parameters, which Dart rejects.
      '-pkeyopt',
      'ec_param_enc:named_curve',
      '-nodes',
      '-keyout',
      keyPath,
      '-out',
      certPath,
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
      '-addext',
      'subjectAltName=DNS:localhost',
      '-addext',
      'extendedKeyUsage=serverAuth',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    server = bound = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain(certPath)
          ..usePrivateKey(keyPath));
    // Answer each request line with one JSON-RPC reply.
    server.listen((client) {
      client
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((_) => client.write('${jsonEncode(_reply)}\n'),
              onError: (Object _) {});
    }, onError: (Object _) {});
  });

  tearDownAll(() async {
    await bound?.close();
    await dir?.delete(recursive: true);
  });

  SecurityContext trusting() => SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificates(certPath);

  Future<Object?> roundTrip(Future<StreamChannel<dynamic>> connecting) async {
    final channel = await connecting;
    channel.sink.add({'jsonrpc': '2.0', 'id': 0, 'method': 'server.ping'});
    final reply =
        await channel.stream.first.timeout(const Duration(seconds: 5));
    await channel.sink.close();
    return reply;
  }

  group('direct', () {
    Future<StreamChannel<dynamic>> open(SecurityContext? context) =>
        connect('localhost',
            port: server.port,
            acceptUnverified: false,
            securityContext: context);

    test('trusts a self-signed certificate from the context', () async {
      expect(await roundTrip(open(trusting())), _reply);
    });

    test('rejects the certificate without the context', () async {
      await expectLater(open(null), throwsA(isA<HandshakeException>()));
    });

    test('enforces the context even when accepting unverified certificates',
        () async {
      await expectLater(
          connect('localhost',
              port: server.port,
              acceptUnverified: true,
              securityContext: SecurityContext(withTrustedRoots: false)),
          throwsA(isA<HandshakeException>()));
    });

    test('ElectrumClient.connect passes the context through', () async {
      final client = await ElectrumClient.connect(
          host: 'localhost',
          port: server.port,
          acceptUnverified: false,
          securityContext: trusting());
      addTearDown(client.close);
      expect(await client.request('server.ping'), 'ok');
    });
  });

  group('through a SOCKS5 proxy', () {
    late ServerSocket proxy;

    setUpAll(() async {
      proxy = await _tunnelProxy(server.port);
    });

    tearDownAll(() => proxy.close());

    Future<StreamChannel<dynamic>> open(SecurityContext? context) =>
        connect('localhost',
            port: server.port,
            proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port),
            securityContext: context);

    test('trusts a self-signed certificate from the context', () async {
      expect(await roundTrip(open(trusting())), _reply);
    });

    test('rejects the certificate without the context', () async {
      await expectLater(open(null), throwsA(isA<HandshakeException>()));
    });
  });
}

bool _hasOpenssl() {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// A SOCKS5 proxy that tunnels every CONNECT to [upstreamPort] on loopback.
Future<ServerSocket> _tunnelProxy(int upstreamPort) async {
  final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  proxy.listen((client) {
    final buffer = <int>[];
    Socket? upstream;
    var connecting = false;
    client.listen((bytes) async {
      if (upstream != null) {
        upstream!.add(bytes);
        return;
      }
      buffer.addAll(bytes);
      if (buffer.length == 3) {
        client.add([5, 0]);
      } else if (!connecting &&
          buffer.length > 8 &&
          buffer.length >= 10 + buffer[7]) {
        connecting = true;
        final pending = buffer.sublist(10 + buffer[7]);
        final socket =
            await Socket.connect(InternetAddress.loopbackIPv4, upstreamPort);
        socket.listen(client.add,
            onError: (Object _) {}, onDone: client.destroy);
        client.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
        if (pending.isNotEmpty) socket.add(pending);
        upstream = socket;
      }
    }, onError: (Object _) {}, onDone: () => upstream?.destroy());
  });
  return proxy;
}
