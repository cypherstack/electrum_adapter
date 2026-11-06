import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A server certificate chain and its key.
SecurityContext servingContext(String certificateChain, String privateKey) =>
    SecurityContext()
      ..useCertificateChain(certificateChain)
      ..usePrivateKey(privateKey);

/// A newline-delimited JSON-RPC server on loopback, over TLS when given a
/// [SecurityContext]. It records each request it reads and answers it on the
/// connection it came from.
class JsonServer {
  final Stream<Socket> _listener;
  final Future<void> Function() _stop;
  final int port;
  final peers = <Socket>[];
  final requests = <Map<String, dynamic>>[];
  final _from = Expando<Socket>();

  /// Completes when a client's connection ends or fails.
  var disconnected = Completer<void>();

  /// Called with each request as it is read.
  void Function(Map<String, dynamic> request)? onRequest;

  /// Whether to stop reading from clients that connect from now on.
  bool stopReading = false;

  JsonServer._(this._listener, this.port, this._stop) {
    _listener.listen((peer) {
      peers.add(peer);
      final reading = peer
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        _from[request] = peer;
        requests.add(request);
        onRequest?.call(request);
      }, onDone: () {
        if (!disconnected.isCompleted) disconnected.complete();
        peer.destroy();
      }, onError: (Object _) {
        if (!disconnected.isCompleted) disconnected.complete();
      });
      if (stopReading) reading.pause();
    }, onError: (Object _) {});
  }

  static Future<JsonServer> start({SecurityContext? context}) async {
    if (context == null) {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      return JsonServer._(server, server.port, server.close);
    }
    final server =
        await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context);
    return JsonServer._(server, server.port, server.close);
  }

  /// Answers [request] with [result] on its connection.
  void reply(Map<String, dynamic> request, Object? result) =>
      (_from[request] ?? peers.single).write('${jsonEncode({
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': result
          })}\n');

  Future<void> close() async {
    for (final peer in peers) {
      peer.destroy();
    }
    await _stop();
  }
}
