import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:socks_socket/socks_socket.dart';

/// Asks the SOCKS5 proxy connected through [socket] to connect to
/// [targetHost]:[targetPort], without authentication.
///
/// [socket] must not have a listener yet. Returns its events for the next
/// owner to listen to; bytes after the proxy's reply stay unread. Failures are
/// reported with socks_socket's exception types. The caller owns [socket] and
/// closes it on failure; closing it also ends a negotiation in progress.
Future<Stream<RawSocketEvent>> socksConnect(
  RawSocket socket, {
  required String proxyHost,
  required int proxyPort,
  required String targetHost,
  required int targetPort,
}) async {
  final request = _encodeConnect(targetHost, targetPort);
  final io = _HandshakeIo(socket);
  Never handshakeFailed(String reason) => throw SocksHandshakeException(
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      message: 'SOCKS5 handshake failed: $reason');
  try {
    await io.write(const [5, 1, 0]);
    final greeting = await io.read(2);
    if (greeting[0] != 5) handshakeFailed('invalid reply version');
    if (greeting[1] != 0) {
      handshakeFailed('proxy rejected authentication method');
    }
    if (socket.available() > 0) {
      handshakeFailed('reply has unexpected trailing data');
    }
    await io.write(request);
    final reply = await io.read(4);
    var length = _replyLength(reply);
    if (length == null) {
      reply.addAll(await io.read(1));
      length = _replyLength(reply);
    }
    if (length != null && length > reply.length) {
      reply.addAll(await io.read(length - reply.length));
    }
    if (length == null || length < 0) {
      throw SocksHandshakeException(
          proxyHost: proxyHost,
          proxyPort: proxyPort,
          message: 'Invalid SOCKS reply');
    }
    if (reply[1] != 0) {
      final code = SocksReplyCode.fromByte(reply[1]);
      final description = code?.description ??
          'unknown (0x${reply[1].toRadixString(16).padLeft(2, '0')})';
      throw SocksRequestException(
          replyCode: code,
          proxyHost: proxyHost,
          proxyPort: proxyPort,
          targetDomain: targetHost,
          targetPort: targetPort,
          message: 'SOCKS5 request failed (proxy: $proxyHost:$proxyPort, '
              'target: $targetHost:$targetPort, reply: $description)');
    }
    return io.release();
  } on SocketException catch (error) {
    throw socksConnectionLost(proxyHost, proxyPort, error);
  }
}

/// How socks_socket reports a connection lost during the handshake or a TLS
/// upgrade through the proxy.
SocksConnectionException socksConnectionLost(
        String proxyHost, int proxyPort, SocketException error) =>
    SocksConnectionException(
        message: 'Connection closed before SOCKS5 response received '
            '(proxy: $proxyHost:$proxyPort): ${error.message}');

/// A CONNECT request for a numeric address, or a domain the proxy resolves.
List<int> _encodeConnect(String host, int port) {
  if (port < 1 || port > 65535) throw ArgumentError.value(port, 'port');
  final address = InternetAddress.tryParse(host);
  final List<int> destination;
  if (address != null) {
    destination = [
      address.type == InternetAddressType.IPv4 ? 1 : 4,
      ...address.rawAddress,
    ];
  } else {
    if (host.isEmpty ||
        host.length > 255 ||
        host.codeUnits.any((c) => c <= 32 || c >= 127) ||
        host.contains(RegExp(r'[/\\:@]'))) {
      throw ArgumentError.value(
          host, 'host', 'Use an ASCII hostname or a numeric address');
    }
    destination = [3, host.length, ...ascii.encode(host)];
  }
  return [5, 1, 0, ...destination, port >> 8, port & 255];
}

/// The length of a CONNECT reply from its first four bytes or more: null
/// while the address length is still unread, -1 when malformed.
int? _replyLength(List<int> reply) {
  if (reply[0] != 5 || reply[2] != 0) return -1;
  if (reply[1] != 0) return 4;
  switch (reply[3]) {
    case 1:
      return 10;
    case 4:
      return 22;
    case 3:
      if (reply.length < 5) return null;
      return reply[4] == 0 ? -1 : 7 + reply[4];
    default:
      return -1;
  }
}

/// Exact reads and complete writes on a raw socket during the handshake.
class _HandshakeIo {
  final RawSocket _socket;
  late final StreamSubscription<RawSocketEvent> _subscription;
  Completer<void>? _waiter;
  Object? _error;
  StackTrace? _errorStack;
  bool _ended = false;

  _HandshakeIo(this._socket) {
    _socket.readEventsEnabled = false;
    _socket.writeEventsEnabled = false;
    _subscription = _socket.listen((event) {
      if (event == RawSocketEvent.read) {
        // Read events repeat while data waits, so take each one only for a
        // read in progress, which asks again if it needs more. This also
        // leaves a readClosed that arrives with the reply queued for the
        // socket's next owner instead of delivering it here.
        _socket.readEventsEnabled = false;
      } else if (event == RawSocketEvent.write) {
        _socket.writeEventsEnabled = false;
      } else {
        _ended = true;
      }
      _wake();
    }, onError: (Object error, StackTrace stack) {
      _error ??= error;
      _errorStack ??= stack;
      _ended = true;
      _wake();
    }, onDone: () {
      _ended = true;
      _wake();
    });
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  Future<void> _next() => (_waiter ??= Completer<void>()).future;

  void _checkOpen() {
    final error = _error;
    if (error is SocketException) {
      Error.throwWithStackTrace(error, _errorStack ?? StackTrace.current);
    }
    if (error != null) throw SocketException('$error');
    if (_ended) throw const SocketException('Connection closed by the proxy');
  }

  Future<void> write(List<int> bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      _checkOpen();
      offset += _socket.write(bytes, offset);
      if (offset < bytes.length) {
        _socket.writeEventsEnabled = true;
        await _next();
      }
    }
  }

  Future<List<int>> read(int length) async {
    final bytes = <int>[];
    while (bytes.length < length) {
      final chunk = _socket.read(length - bytes.length);
      if (chunk != null && chunk.isNotEmpty) {
        bytes.addAll(chunk);
        continue;
      }
      _checkOpen();
      _socket.readEventsEnabled = true;
      await _next();
    }
    return bytes;
  }

  /// Hands the socket's events to its next owner.
  Stream<RawSocketEvent> release() {
    _socket.readEventsEnabled = false;
    _socket.writeEventsEnabled = false;
    return SubscriptionStream(_subscription);
  }
}
