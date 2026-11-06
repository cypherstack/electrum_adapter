import 'dart:async';
import 'dart:io';

/// The SOCKS5 reply to a CONNECT request that succeeded.
const socksSucceeded = [5, 0, 0, 1, 0, 0, 0, 0, 0, 0];

/// The length of the SOCKS5 CONNECT request at the start of [bytes], which
/// depends on its address type, or null until all of it has arrived.
int? socksRequestLength(List<int> bytes) {
  if (bytes.length < 5) return null;
  final length = switch (bytes[3]) {
    1 => 10, // IPv4
    3 => 7 + bytes[4], // a domain name, after its length
    4 => 22, // IPv6
    final type => throw StateError('Unknown SOCKS5 address type $type'),
  };
  return bytes.length < length ? null : length;
}

/// Answers the SOCKS5 handshake a client starts on [client]: the no-auth
/// greeting, then a CONNECT request of any address type, whose bytes
/// [onRequest] receives. [stallAt] stops answering at 'greeting' or 'connect', and
/// [stepDelay] delays each answer. [beforeReply] runs before the CONNECT reply
/// and [afterReply] after it. What the client sends after the request goes to
/// [onPayload], from the reply on. [onDone] runs when the client's input ends
/// or fails. Returns the subscription to that input.
StreamSubscription<List<int>> serveSocks(Socket client,
    {String stallAt = 'none',
    Duration stepDelay = Duration.zero,
    void Function(List<int> request)? onRequest,
    FutureOr<void> Function()? beforeReply,
    void Function()? afterReply,
    void Function(List<int> bytes)? onPayload,
    void Function()? onDone}) {
  final buffer = <int>[];
  var stage = 'greeting';
  return client.listen((bytes) async {
    if (stage == 'tunnel') {
      onPayload?.call(bytes);
      return;
    }
    buffer.addAll(bytes);
    if (stage == 'greeting') {
      if (buffer.length < 2 || buffer.length < 2 + buffer[1]) return;
      buffer.removeRange(0, 2 + buffer[1]);
      stage = 'request';
      if (stallAt == 'greeting') return;
      await Future<void>.delayed(stepDelay);
      client.add([5, 0]);
    }
    if (stage == 'request') {
      final length = socksRequestLength(buffer);
      if (length == null) return;
      final request = buffer.sublist(0, length);
      buffer.removeRange(0, length);
      stage = 'connecting';
      onRequest?.call(request);
      if (stallAt == 'connect') return;
      await Future<void>.delayed(stepDelay);
      await beforeReply?.call();
      stage = 'tunnel';
      client.add(socksSucceeded);
      afterReply?.call();
      if (buffer.isNotEmpty) onPayload?.call(List.of(buffer));
      buffer.clear();
    }
  }, onDone: onDone, onError: (Object _) => onDone?.call());
}

/// A SOCKS5 proxy stub that answers the handshake for each client, then
/// records what the client sends, without connecting anywhere.
class SocksProxy {
  /// 'greeting' or 'connect' stops answering at that step.
  final String stallAt;
  final Duration stepDelay;
  late final ServerSocket server;
  Socket? peer;
  final closed = Completer<void>();

  /// The CONNECT requests received, as sent.
  final connectRequests = <List<int>>[];
  final payload = <int>[];
  void Function(Socket peer)? onAccept;
  void Function(Socket peer)? onConnected;
  void Function(Socket peer, List<int> bytes)? onPayload;
  StreamSubscription<List<int>>? _reading;

  SocksProxy(this.stallAt, {this.stepDelay = Duration.zero});

  int get port => server.port;

  /// Stops reading from the client, as a stalled peer does.
  void pauseReading() => _reading?.pause();

  void resumeReading() => _reading?.resume();

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      peer = socket;
      onAccept?.call(socket);
      _reading = serveSocks(socket,
          stallAt: stallAt,
          stepDelay: stepDelay,
          onRequest: connectRequests.add,
          afterReply: () => onConnected?.call(socket),
          onPayload: (bytes) {
            payload.addAll(bytes);
            onPayload?.call(socket, bytes);
          },
          onDone: () {
            if (!closed.isCompleted) closed.complete();
            socket.destroy();
          });
    });
  }

  Future<void> stop() async {
    peer?.destroy();
    await server.close();
  }
}
