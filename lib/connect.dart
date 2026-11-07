import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:electrum_adapter/src/abortable_raw_socket.dart';
import 'package:electrum_adapter/src/connection_timeout.dart';
import 'package:electrum_adapter/src/socks.dart';
import 'package:electrum_adapter/src/transport_channel.dart';
import 'package:socks_socket/socks_socket.dart';
import 'package:stream_channel/stream_channel.dart';

export 'package:electrum_adapter/src/connection_timeout.dart'
    show ConnectionTimeoutException, connectionTimeout, proxyConnectionTimeout;
export 'package:electrum_adapter/src/transport_channel.dart'
    show TransportChannel;

const aliveTimerDuration = Duration(seconds: 2);

/// Connects to an Electrum server, directly or through a SOCKS5 proxy such as
/// Tor, and returns a channel of JSON-RPC messages.
///
/// [acceptUnverified] accepts any certificate on a direct TLS connection,
/// which lets anyone on the path impersonate the server; certificates are
/// always verified through a proxy.
///
/// [securityContext] sets the certificates trusted for TLS, such as a server's
/// self-signed certificate; null uses the platform's trusted roots. A given
/// [securityContext] is always enforced, even when [acceptUnverified] is true.
/// On macOS and iOS the certificate must also list the serverAuth extended
/// key usage.
///
/// [onBadCertificate] is called with a certificate that fails verification,
/// on a direct TLS connection and through a proxy; return true to accept it.
/// It is not called on a direct connection when [acceptUnverified] is true
/// without a [securityContext], which accepts every certificate.
///
/// [connectionTimeout] bounds the entire connection, including TCP, SOCKS
/// negotiation (when used) and TLS. It defaults to [connectionTimeout] for a
/// direct connection and to [proxyConnectionTimeout] through a proxy, and must
/// be positive. An expired attempt releases its socket and throws a
/// [ConnectionTimeoutException]. [aliveTimerDuration] is retained for
/// compatibility; it does not implement a heartbeat.
///
/// Each line from the server is one JSON message, decoded as it arrives;
/// lines that are not JSON are skipped, and invalid UTF-8 is replaced. When
/// [maxMessageBytes] is given, a longer line is skipped and reported on the
/// stream as a [MessageTooLargeException], on which a client closes; there is
/// no limit by default.
///
/// Closing the channel's sink ends its stream at once, sends queued output and
/// then shuts down sending; the connection closes once the server closes its
/// side. [TransportChannel.abort] releases it at once, and a client does so
/// after its `closeTimeout`. Cancelling the stream alone does not close the
/// connection.
Future<TransportChannel> connect(
  String host, {
  int port = 50002,
  Duration? connectionTimeout,
  Duration aliveTimerDuration = aliveTimerDuration,
  bool acceptUnverified = false,
  bool useSSL = true,
  ({InternetAddress host, int port})? proxyInfo,
  SecurityContext? securityContext,
  bool Function(X509Certificate)? onBadCertificate,
  int? maxMessageBytes,
}) async {
  final timeout =
      resolveConnectionTimeout(connectionTimeout, proxied: proxyInfo != null);
  if (maxMessageBytes != null && maxMessageBytes < 1) {
    throw ArgumentError.value(
        maxMessageBytes, 'maxMessageBytes', 'Must be positive');
  }
  ConnectionTask<RawSocket>? task;
  RawSocket? tcp;
  AbortableRawSocket? tls;
  var expired = false;

  ConnectionTimeoutException timedOut() => ConnectionTimeoutException(
      'Electrum connection to $host:$port timed out', timeout);

  // The socket is ours throughout, so an abandoned attempt can always release
  // it, even when the other side never hangs up.
  void abort() {
    task?.cancel();
    // Fail TLS through its socket so it releases its native state.
    tls?.abort(const SocketException('Electrum connection aborted'));
    tcp?.close().ignore();
  }

  // As socks_socket did, report a proxied transport's errors as SOCKS errors.
  Object proxiedError(Object error) => error is SocksException
      ? error
      : SocksConnectionException(message: 'SOCKS5 connection error: $error');

  Future<RawSocketChannel> open() async {
    try {
      task = proxyInfo == null
          ? await RawSocket.startConnect(host, port)
          : await RawSocket.startConnect(proxyInfo.host, proxyInfo.port);
      // TCP may finish after the deadline, before we owned the socket.
      if (expired) task!.cancel();
      tcp = await task!.socket;
      task = null;
      if (expired) throw timedOut();
      Stream<RawSocketEvent>? events;
      if (proxyInfo != null) {
        events = await socksConnect(tcp!,
            proxyHost: proxyInfo.host.address,
            proxyPort: proxyInfo.port,
            targetHost: host,
            targetPort: port);
        if (expired) throw timedOut();
      }
      final RawSocket socket;
      if (useSSL) {
        final transport = tls = AbortableRawSocket(tcp!, events);
        events = null;
        try {
          socket = await RawSecureSocket.secure(transport,
              host: host,
              context: securityContext,
              // Certificates are always verified through a proxy.
              onBadCertificate: proxyInfo == null &&
                      acceptUnverified &&
                      securityContext == null
                  ? (_) => true
                  : onBadCertificate);
        } on SocketException catch (error) {
          // socks_socket reported a connection lost during the TLS upgrade as
          // a SOCKS failure too.
          if (proxyInfo == null || expired) rethrow;
          throw socksConnectionLost(
              proxyInfo.host.address, proxyInfo.port, error);
        }
      } else {
        socket = tcp!;
      }
      if (expired) throw timedOut();
      // As socks_socket did, a proxied connection closes once the server ends
      // its side and the output accepted before then is sent; a direct one
      // stays half-open, as a dart:io Socket does.
      return RawSocketChannel(socket, abort,
          events: events,
          closeOnPeerEof: proxyInfo != null,
          mapError: proxyInfo == null ? null : proxiedError);
    } catch (_) {
      abort();
      rethrow;
    }
  }

  final channel = await open().timeout(timeout, onTimeout: () {
    expired = true;
    abort();
    throw timedOut();
  });
  return TransportChannel(_jsonChannel(channel, maxMessageBytes), channel.abort,
      done: channel.done, received: () => channel.received);
}

/// Reported through a channel's stream when a line from the server is longer
/// than its `maxMessageBytes`. The line is skipped; a client closes on this
/// error.
class MessageTooLargeException implements Exception {
  /// The limit, in bytes.
  final int limit;

  const MessageTooLargeException(this.limit);

  @override
  String toString() =>
      'MessageTooLargeException: a message from the server exceeded $limit '
      'bytes';
}

/// Newline-delimited JSON over [channel], as the Electrum protocol sends it.
///
/// Closing the sink ends the stream before it emits anything more, as
/// [StreamChannel] requires: messages and errors not yet delivered are
/// dropped. (stream_channel's own close guarantee would report such an error
/// as uncaught.)
StreamChannel<dynamic> _jsonChannel(
    StreamChannel<List<int>> channel, int? maxMessageBytes) {
  var closed = false;
  final stream = Stream<dynamic>.eventTransformed(channel.stream,
          (messages) => _JsonLineSink(messages, maxMessageBytes))
      .transform(StreamTransformer<dynamic, dynamic>.fromHandlers(
          handleData: (message, sink) {
    if (!closed) sink.add(message);
  }, handleError: (error, stack, sink) {
    if (!closed) sink.addError(error, stack);
  }));
  final sink = StreamSinkTransformer<dynamic, List<int>>.fromHandlers(
      handleData: (data, sink) {
    sink.add(utf8.encode('${jsonEncode(data)}\n'));
  }, handleDone: (sink) {
    // Throws, leaving the channel open, while a stream is being added.
    sink.close();
    closed = true;
  }).bind(channel.sink);
  return StreamChannel<dynamic>(stream, sink);
}

/// Decodes each line of bytes as one JSON message while it arrives, so a large
/// message is never also held as a string. Lines that are not JSON, including
/// blank ones, are skipped, as json_rpc_2 does. A line longer than [_limit] is
/// skipped too, and reported as a [MessageTooLargeException].
class _JsonLineSink implements EventSink<List<int>> {
  final EventSink<dynamic> _messages;
  final int? _limit;
  ByteConversionSink? _line;
  int _lineBytes = 0;
  bool _skipping = false;

  _JsonLineSink(this._messages, this._limit);

  @override
  void add(List<int> bytes) {
    var start = 0;
    while (true) {
      final end = bytes.indexOf(0x0A, start);
      _feed(bytes, start, end < 0 ? bytes.length : end);
      if (end < 0) return;
      _endLine();
      start = end + 1;
    }
  }

  void _feed(List<int> bytes, int start, int end) {
    if (start == end || _skipping) return;
    final limit = _limit;
    if (limit != null) {
      _lineBytes += end - start;
      if (_lineBytes > limit) {
        _line = null;
        _skipping = true;
        _messages.addError(MessageTooLargeException(limit));
        return;
      }
    }
    try {
      (_line ??= const Utf8Decoder(allowMalformed: true).startChunkedConversion(
              const JsonDecoder().startChunkedConversion(
                  ChunkedConversionSink<Object?>.withCallback(
                      (values) => _messages.add(values.single)))))
          .addSlice(bytes, start, end, false);
    } on FormatException {
      _line = null;
      _skipping = true;
    }
  }

  void _endLine() {
    final line = _line;
    _line = null;
    _lineBytes = 0;
    _skipping = false;
    try {
      line?.close();
    } on FormatException {
      // Not JSON.
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _messages.addError(error, stackTrace);

  @override
  void close() {
    _endLine();
    _messages.close();
  }
}
