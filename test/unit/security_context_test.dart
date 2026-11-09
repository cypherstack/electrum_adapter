import 'dart:async';
import 'dart:io';

import 'package:electrum_adapter/client/base_client.dart';
import 'package:electrum_adapter/electrum_adapter.dart';
import 'package:electrum_adapter/src/abortable_raw_socket.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/json_server.dart';
import 'support/socks.dart';

const _pong = {'jsonrpc': '2.0', 'id': 0, 'result': 'ok'};

/// The result for a request: the version pair for server.version, else 'ok'.
Object? _answer(Map<String, dynamic> request) =>
    request['method'] == 'review.echo'
        ? request['params']
        : request['method'] == 'server.version'
            ? ['ElectrumX 1.16.0', '1.4']
            : 'ok';

void main() {
  // The certificate is made per run: Apple platforms cap a TLS server
  // certificate's validity, so a committed one would expire.
  final openssl = _findOpenssl();
  if (openssl == null) {
    test('TLS with a self-signed certificate', () {},
        skip: 'needs openssl on PATH or from Git for Windows');
    return;
  }
  // Nullable so cleanup copes with a setup that failed partway.
  Directory? dir;
  JsonServer? bound;
  late String certPath;
  late JsonServer server;

  SecurityContext serving() => servingContext(certPath, '${dir!.path}/key.pem');

  setUpAll(() async {
    final tmp =
        dir = await Directory.systemTemp.createTemp('electrum_adapter_tls');
    certPath = '${tmp.path}/cert.pem';
    final keyPath = '${tmp.path}/key.pem';
    // A self-signed certificate, as on a personal Electrum server. Apple
    // platforms reject a server certificate without the serverAuth usage.
    final result = await Process.run(openssl, [
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
    final started = server = bound = await JsonServer.start(context: serving());
    started.onRequest = (request) => started.reply(request, _answer(request));
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

  for (final tcpTimeout in [null, const Duration(milliseconds: 200)]) {
    final label = tcpTimeout == null ? 'default' : 'explicit';
    test('slow direct TLS can outlive the $label TCP timeout', () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(listener.close);
      final ready = Completer<Socket>();
      listener.listen((peer) {
        addTearDown(peer.destroy);
        ready.complete(peer);
      });
      final connecting = ElectrumClient.connect(
          host: 'localhost',
          port: listener.port,
          connectionTimeout: tcpTimeout,
          securityContext: trusting());
      // Observe errors immediately, including a regression that times out
      // while the server is still waiting to start its TLS handshake.
      connecting.ignore();
      final peer = await ready.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(tcpTimeout == null
          ? const Duration(seconds: 6)
          : const Duration(milliseconds: 500));
      final securing = SecureSocket.secureServer(peer, serving());
      securing.ignore();
      final client = await connecting;
      addTearDown(client.close);
      final secure = await securing;
      addTearDown(secure.destroy);
      secure.listen(
          (_) => secure.write('{"jsonrpc":"2.0","id":0,"result":"ok"}\n'),
          onError: (Object _) {});
      expect(await client.request('server.ping'), 'ok');
    });
  }

  group('closing and aborting', () {
    // A TLS server that records each request and can stop reading.
    late JsonServer recorder;
    late ServerSocket proxy;

    setUpAll(() async {
      recorder = await JsonServer.start(context: serving());
      proxy = await _tunnelProxy(recorder.port,
          stopReading: () => recorder.stopReading);
    });

    setUp(() {
      recorder.requests.clear();
      recorder.stopReading = false;
      recorder.disconnected = Completer<void>();
    });

    tearDownAll(() async {
      await recorder.close();
      await proxy.close();
    });

    for (final proxied in [false, true]) {
      final path = proxied ? 'through a proxy' : 'directly';

      Future<TransportChannel> open({int? maxMessageBytes}) async =>
          await connect('localhost',
              port: recorder.port,
              securityContext: trusting(),
              maxMessageBytes: maxMessageBytes,
              proxyInfo: proxied
                  ? (host: InternetAddress.loopbackIPv4, port: proxy.port)
                  : null);

      test(
          'an oversized message releases raw TLS and preserves its error $path',
          () async {
        recorder.onRequest = (request) => recorder.reply(request, 'x' * 1000);
        addTearDown(() => recorder.onRequest = null);
        final transport = await open(maxMessageBytes: 100);
        addTearDown(transport.abort);
        final ended = expectLater(
            transport.stream,
            emitsInOrder([
              emitsError(isA<MessageTooLargeException>()),
              emitsDone,
            ]));
        transport.sink.add({'jsonrpc': '2.0', 'id': 0, 'method': 'large'});
        await ended.timeout(const Duration(seconds: 2));
        await transport.done.timeout(const Duration(seconds: 1));
        await recorder.disconnected.future.timeout(const Duration(seconds: 2));
        await expectLater(
            transport.sink.done, throwsA(isA<MessageTooLargeException>()));
      });

      test('close still sends a notification queued just before it $path',
          () async {
        final client = BaseClient(await open());
        client.peer.sendNotification('server.ping', ['last']);
        await client.close();
        await recorder.disconnected.future.timeout(const Duration(seconds: 2));
        expect(recorder.requests.map((request) => request['params']), [
          ['last']
        ]);
      });

      test('a request deadline releases TLS that stopped reading $path',
          () async {
        recorder.stopReading = true;
        final transport = await open();
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
    }
  });

  test('a TLS server that answers nothing closes the client at the deadline',
      () async {
    // A server that reads nothing after the handshake.
    final silent = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4, 0, serving());
    final held = <SecureSocket>[];
    silent.listen((socket) => held.add(socket..listen(null).pause()));
    addTearDown(() async {
      for (final socket in held) {
        socket.destroy();
      }
      await silent.close();
    });
    final transport = await connect('localhost',
        port: silent.port, securityContext: trusting());
    final client = BaseClient(transport,
        requestTimeout: const Duration(milliseconds: 300));
    addTearDown(client.close);
    final first =
        expectLater(client.request('first'), throwsA(isA<TimeoutException>()));
    // More than TLS buffers itself, which it encrypts into the system's
    // buffers without the server reading any of it.
    client.request('large', ['x' * 50000]).ignore();
    await first;
    // Nothing moved between the client and the server.
    expect(client.peer.isClosed, isTrue);
    await expectLater(client.done, throwsA(isA<TimeoutException>()));
  });

  test('aborting TLS that holds unread input releases it', () async {
    final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4, 0, serving());
    final accepted = <SecureSocket>[];
    server.listen((socket) {
      accepted.add(socket);
      socket.listen((_) {}, onError: (Object _) {});
      socket.done.then<void>((_) {}, onError: (Object _) {});
      // More than the client reads, which TLS holds.
      socket.add(List<int>.filled(256 * 1024, 0x41));
    });
    addTearDown(() async {
      for (final socket in accepted) {
        socket.destroy();
      }
      await server.close();
    });
    final tcp =
        await RawSocket.connect(InternetAddress.loopbackIPv4, server.port);
    final tls = AbortableRawSocket(tcp);
    final secure = await RawSecureSocket.secure(tls,
        host: 'localhost', context: trusting());
    final ended = Completer<void>();
    // Read events stay enabled, but nothing reads the plaintext.
    secure.listen((_) {}, onError: (Object _) {
      if (!ended.isCompleted) ended.complete();
    }, onDone: () {
      if (!ended.isCompleted) ended.complete();
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    tls.abort(const SocketException('aborted'));
    tcp.close().ignore();
    // Closing TCP alone would leave TLS waiting forever.
    await ended.future.timeout(const Duration(seconds: 2));
  });

  group('direct', () {
    Future<StreamChannel<dynamic>> open(SecurityContext? context,
            {bool Function(X509Certificate)? onBadCertificate}) =>
        connect('localhost',
            port: server.port,
            acceptUnverified: false,
            securityContext: context,
            onBadCertificate: onBadCertificate);

    test('trusts a self-signed certificate from the context', () async {
      expect(await roundTrip(open(trusting())), _pong);
    });

    test('large TLS requests and responses preserve every byte', () async {
      final client = await ElectrumClient.connect(
          host: 'localhost',
          port: server.port,
          securityContext: trusting(),
          requestTimeout: const Duration(seconds: 5));
      addTearDown(client.close);
      final payload =
          List<String>.generate(200000, (i) => '${i % 100},').join();
      expect(await client.request('review.echo', [payload]), [payload]);
    });

    test('rejects the certificate without the context', () async {
      await expectLater(open(null), throwsA(isA<HandshakeException>()));
    });

    test('rejects an unverified certificate by default', () async {
      await expectLater(connect('localhost', port: server.port),
          throwsA(isA<HandshakeException>()));
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

    test('offers an untrusted certificate to onBadCertificate', () async {
      X509Certificate? offered;
      expect(
          await roundTrip(open(null, onBadCertificate: (certificate) {
            offered = certificate;
            return true;
          })),
          _pong);
      expect(offered?.subject, contains('CN=localhost'));
    });

    test('rejects the certificate when onBadCertificate returns false',
        () async {
      await expectLater(open(null, onBadCertificate: (_) => false),
          throwsA(isA<HandshakeException>()));
    });

    test('calls onBadCertificate even with a context', () async {
      // The context trusts nothing, so only the callback can accept.
      expect(
          await roundTrip(open(SecurityContext(withTrustedRoots: false),
              onBadCertificate: (_) => true)),
          _pong);
    });

    test('acceptUnverified without a context does not consult the callback',
        () async {
      expect(
          await roundTrip(connect('localhost',
              port: server.port,
              acceptUnverified: true,
              onBadCertificate: (_) => false)),
          _pong);
    });

    test('ElectrumClient.connect passes onBadCertificate through', () async {
      X509Certificate? offered;
      final client = await ElectrumClient.connect(
          host: 'localhost',
          port: server.port,
          onBadCertificate: (certificate) {
            offered = certificate;
            return true;
          });
      addTearDown(client.close);
      expect(await client.request('server.ping'), 'ok');
      expect(offered, isNotNull);
    });

    test('FiroElectrumClient.connect passes onBadCertificate through',
        () async {
      X509Certificate? offered;
      final client = await FiroElectrumClient.connect('localhost',
          port: server.port, onBadCertificate: (certificate) {
        offered = certificate;
        return true;
      });
      addTearDown(client.close);
      expect(offered, isNotNull);
    });

    test('RavenElectrumClient.connect passes onBadCertificate through',
        () async {
      X509Certificate? offered;
      final client = await RavenElectrumClient.connect('localhost',
          port: server.port, onBadCertificate: (certificate) {
        offered = certificate;
        return true;
      });
      addTearDown(client.close);
      expect(offered, isNotNull);
      expect(client.protocolVersion, '1.4');
    });
  });

  group('through a SOCKS5 proxy', () {
    late ServerSocket proxy;

    setUpAll(() async {
      proxy = await _tunnelProxy(server.port);
    });

    tearDownAll(() => proxy.close());

    Future<StreamChannel<dynamic>> open(SecurityContext? context,
            {bool Function(X509Certificate)? onBadCertificate}) =>
        connect('localhost',
            port: server.port,
            proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port),
            securityContext: context,
            onBadCertificate: onBadCertificate);

    test('trusts a self-signed certificate from the context', () async {
      expect(await roundTrip(open(trusting())), _pong);
    });

    test('rejects the certificate without the context', () async {
      await expectLater(open(null), throwsA(isA<HandshakeException>()));
    });

    test('offers an untrusted certificate to onBadCertificate', () async {
      X509Certificate? offered;
      expect(
          await roundTrip(open(null, onBadCertificate: (certificate) {
            offered = certificate;
            return true;
          })),
          _pong);
      expect(offered?.subject, contains('CN=localhost'));
    });

    test('rejects the certificate when onBadCertificate returns false',
        () async {
      await expectLater(open(null, onBadCertificate: (_) => false),
          throwsA(isA<HandshakeException>()));
    });
  });
}

/// An openssl executable: on PATH, or else where Git for Windows installs one.
String? _findOpenssl() {
  final git = '${Platform.environment['ProgramFiles'] ?? r'C:\Program Files'}'
      r'\Git';
  for (final candidate in [
    'openssl',
    if (Platform.isWindows) ...[
      '$git\\mingw64\\bin\\openssl.exe',
      '$git\\usr\\bin\\openssl.exe',
    ],
  ]) {
    try {
      if (Process.runSync(candidate, ['version']).exitCode == 0) {
        return candidate;
      }
    } on ProcessException {
      // Not there.
    }
  }
  return null;
}

/// A SOCKS5 proxy that tunnels every CONNECT to [upstreamPort] on loopback.
/// Once [stopReading] returns true, it stops reading from its client, so the
/// client's writes back up as with a stalled server.
Future<ServerSocket> _tunnelProxy(int upstreamPort,
    {bool Function()? stopReading}) async {
  final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  proxy.listen((client) {
    Socket? upstream;
    late StreamSubscription<List<int>> reading;
    reading = serveSocks(client,
        beforeReply: () async {
          final socket = upstream =
              await Socket.connect(InternetAddress.loopbackIPv4, upstreamPort);
          socket.listen(client.add,
              onError: (Object _) {}, onDone: client.destroy);
        },
        onPayload: (bytes) {
          upstream!.add(bytes);
          if (stopReading?.call() ?? false) reading.pause();
        },
        onDone: () => upstream?.destroy());
  });
  return proxy;
}
