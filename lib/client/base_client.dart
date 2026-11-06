import 'dart:async';

import 'package:async/async.dart';
import 'package:electrum_adapter/src/connection_timeout.dart';
import 'package:electrum_adapter/src/transport_channel.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stack_trace/stack_trace.dart';
import 'package:stream_channel/stream_channel.dart';

/// The BaseClient class must be given an open channel to the server, which it
/// will use to make requests (or close the channel). We intentionally keep the
/// channel generic so that we can, for example, inject a mock server and write
/// tests against it. Normally, the channel will be derived from a SecureSocket
/// via TCP (see [connect.dart]).
///
/// Example:
///   var client = BaseClient(await connect('testnet.rvn.rocks'));
///
class BaseClient {
  static const defaultCloseTimeout = Duration(seconds: 5);

  /// Deadline for each RPC response, including responses sent in a batch;
  /// null, the default, sets none.
  final Duration? requestTimeout;

  /// How long a graceful close may spend sending queued output before the
  /// transport is aborted.
  final Duration closeTimeout;
  final StreamChannel<dynamic> _channel;
  final _incoming = StreamController<dynamic>(sync: true);
  final _pending = <_PendingRequest>{};
  final _done = Completer<void>();
  bool _closed = false;
  int _messages = 0;
  int _nextId = 0;

  /// Completes when the client closes, or fails with its terminal error.
  Future<void> get done => _done.future;

  /// We use a Peer here--which implements both Server and Client sides of a
  /// Remote Procedure Call (RPC) interface--to communicate with an ElectrumX
  /// Ravencoin server. We do so because we need:
  ///
  /// - the Client side for the basic ability to call 'procedures' on the
  ///   remote server (e.g. 'blockchain.scripthash.get_balance');
  ///
  /// - the Server side so that when we can subscribe to an ongoing stream of
  ///   updates (e.g. 'blockchain.headers.subscribe'). The remote server can
  ///   notify us of an update by calling our registered 'procedures'.
  ///
  /// The ElectrumX specification requires that notifications from the server
  /// use procedure names that match the initiating subscribe call. For example:
  ///
  ///   We can start a subscription by calling `blockchain.scripthash.subscribe`
  ///   and the server will subsequently notify us uf status changes by
  ///   calling this client's matching `blockchain.scripthash.subscribe`
  ///   procedure.
  ///
  /// Note that the BaseClient class does not implement subscriptions.
  ///
  late rpc.Peer peer;

  /// Throws a [StateError] if [channel]'s stream already has a listener.
  BaseClient(StreamChannel<dynamic> channel,
      {this.requestTimeout,
      this.closeTimeout = defaultCloseTimeout,
      rpc.ErrorCallback? onUnhandledError})
      : _channel = channel {
    final timeout = requestTimeout;
    if (timeout != null) checkPositive(timeout, 'requestTimeout');
    checkPositive(closeTimeout, 'closeTimeout');
    _done.future.ignore();
    // Listen at once, so a stream that already has a listener fails here. A
    // transport error is kept for done; json_rpc_2 would only report a
    // generic closure.
    final incoming = _incoming;
    final subscription = channel.stream.listen((dynamic message) {
      _messages++;
      incoming.add(message);
    }, onError: (Object error, StackTrace stack) {
      _terminate(error, stack);
    }, onDone: () {
      incoming.close().ignore();
    });
    incoming
      ..onPause = subscription.pause
      ..onResume = subscription.resume
      ..onCancel = subscription.cancel;
    final guarded =
        StreamChannel<dynamic>.withGuarantees(incoming.stream, channel.sink);
    // json_rpc_2 does not await sink.close(), and the guarantee wrapper does
    // not watch the caller's sink, so observe sink failures here.
    guarded.sink.done.then<void>((_) {}, onError: _terminate);
    channel.sink.done.then<void>((_) {}, onError: _terminate);
    peer = rpc.Peer.withoutJson(
        StreamChannel<dynamic>(guarded.stream, _PeerSink(guarded.sink)),
        onUnhandledError: onUnhandledError ?? handleError,
        idGenerator: () => _nextId++);
    peer.listen().then<void>((_) => _terminate(), onError: _terminate);
  }

  /// Closes the connection and fails pending requests at once.
  ///
  /// Output already queued, such as a notification sent just before, is still
  /// sent for up to [closeTimeout] before the transport is aborted. This does
  /// not wait for that.
  Future<void> close() async {
    _terminate();
  }

  Future<dynamic> request(String method, [dynamic parameters]) =>
      requestWithTimeout(method, parameters: parameters);

  /// Sends one RPC, preserving [request]'s existing positional API. [timeout]
  /// replaces the client's [requestTimeout] for this call; with neither, the
  /// request has no deadline. Every request goes through this method,
  /// including those of [request] and of helpers with a deadline of their own,
  /// so a subclass sees all requests by overriding it.
  ///
  /// A deadline runs from when the request is sent, so it includes time
  /// spent waiting behind earlier replies. When it passes, the request fails
  /// with a [TimeoutException] and a late response is discarded. If nothing at
  /// all arrived from the server during the deadline of the oldest pending
  /// request, the connection is presumed dead: the client closes and every
  /// pending request fails with a [TimeoutException]. While an older request
  /// is pending, the server may be busy with it, so a newer request's deadline
  /// fails only that request. A [TransportChannel] counts the bytes it
  /// receives, under TLS as each record is decrypted, so a long response in
  /// progress keeps the connection open; on other channels only whole
  /// messages count. No requests are retried.
  Future<dynamic> requestWithTimeout(String method,
      {dynamic parameters, Duration? timeout}) {
    try {
      if (timeout != null) checkPositive(timeout, 'timeout');
      if (_closed || peer.isClosed) {
        throw StateError('Electrum client is closed');
      }
    } catch (error, stack) {
      return Future<dynamic>.error(error, stack);
    }
    final deadline = timeout ?? requestTimeout;
    // json_rpc_2 takes the next id first.
    final pending = _PendingRequest(_nextId, method, deadline, _received);
    _pending.add(pending);
    if (deadline != null)
      pending.timer = Timer(deadline, () => _expire(pending));
    try {
      unawaited(
          peer.sendRequest(method, parameters).then<void>((dynamic value) {
        if (_pending.remove(pending)) pending.complete(value);
      }, onError: (Object error, StackTrace stack) {
        if (_pending.remove(pending)) pending.fail(error, stack);
      }));
    } catch (error, stack) {
      if (_pending.remove(pending)) pending.fail(error, stack);
    }
    return pending.future;
  }

  /// What has arrived from the server: bytes when the transport counts them,
  /// and messages.
  int get _received {
    final channel = _channel;
    return _messages + (channel is TransportChannel ? channel.received : 0);
  }

  void _expire(_PendingRequest pending) {
    if (!_pending.contains(pending)) return;
    final stack = StackTrace.current;
    final message = 'Electrum request "${pending.method}" timed out';
    if (_received == pending.received && identical(_pending.first, pending)) {
      // Nothing arrived for the whole deadline of the oldest pending request.
      final error = TimeoutException(
          '$message and nothing was received; connection closed',
          pending.timeout);
      _failPending((_) => error, stack);
      _terminate(error, stack);
      return;
    }
    // The server is answering, or may be busy with an older request.
    _pending.remove(pending);
    pending.fail(TimeoutException(message, pending.timeout), stack);
    _abandon(pending.id);
  }

  /// Answers an expired request locally: json_rpc_2 keeps a request, with its
  /// stack trace, until a response arrives, which the server may never send.
  void _abandon(int id) {
    if (_incoming.isClosed) return;
    _incoming.add({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': -32000, 'message': 'Electrum request abandoned'},
    });
  }

  void _failPending(
      Object Function(_PendingRequest request) error, StackTrace stack) {
    final pending = _pending.toList();
    _pending.clear();
    for (final request in pending) {
      request.fail(error(request), stack);
    }
  }

  /// Closes the client. With an [error], the transport is aborted.
  void _terminate([Object? error, StackTrace? stack]) {
    if (_closed) return;
    _closed = true;
    // A lost connection fails pending requests with a StateError, as
    // json_rpc_2 did; done reports the transport's own error.
    _failPending(
        (request) => StateError('Electrum client closed with pending request '
            '"${request.method}"${error == null ? '' : ': $error'}'),
        stack ?? StackTrace.current);
    // A failed or timed-out transport may have stopped reading: abort rather
    // than wait for a graceful close that might never finish.
    if (error != null) _abort();
    try {
      peer.close().ignore();
    } catch (closeError, closeStack) {
      // The close failed, so queued output cannot be drained either.
      if (error == null) _abort();
      error ??= closeError;
      stack ??= closeStack;
    }
    final channel = _channel;
    try {
      // Once the stream has ended, the guarantee wrapper no longer closes
      // the caller's sink, so close it here; queued output is still sent.
      channel.sink.close().ignore();
    } catch (_) {
      // The sink was closed already and rejects a second close.
    }
    if (error == null && channel is TransportChannel) {
      // Bound the drain: a server that stopped reading must not hold the
      // transport open.
      final drain = Timer(closeTimeout, _abort);
      channel.done.whenComplete(drain.cancel).ignore();
    }
    if (error == null) {
      _done.complete();
    } else {
      _done.completeError(error, stack);
    }
  }

  /// Aborts the transport, if the channel has one. The client is closing
  /// already, so a failure to abort is not reported.
  void _abort() {
    final channel = _channel;
    if (channel is! TransportChannel) return;
    try {
      channel.abort();
    } catch (_) {
      // Nothing more can be done with the transport.
    }
  }

  void handleError(dynamic error, dynamic trace) {
    print(error);
    final simpleTrace = Trace.from(trace as StackTrace);
    print(simpleTrace.terse);
  }
}

/// Drops messages once closed instead of throwing: json_rpc_2 still sends a
/// batch from `withBatch`'s finally block after its requests have failed on a
/// closed client.
class _PeerSink extends DelegatingStreamSink<dynamic> {
  bool _closed = false;

  _PeerSink(super.sink);

  @override
  void add(dynamic data) {
    // json_rpc_2 sends an empty batch when every member failed before it was
    // sent, and an empty batch is an invalid request.
    if (_closed || (data is List && data.isEmpty)) return;
    super.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (!_closed) super.addError(error, stackTrace);
  }

  @override
  Future<void> close() {
    _closed = true;
    return super.close();
  }
}

class _PendingRequest {
  /// The request's JSON-RPC id.
  final int id;
  final String method;
  final Duration? timeout;

  /// What had arrived from the server when the request was sent.
  final int received;

  // Completes a response synchronously, as json_rpc_2 does: a subscription's
  // first result must reach its stream before a notification read with it.
  final _result = Completer<dynamic>.sync();
  Timer? timer;

  _PendingRequest(this.id, this.method, this.timeout, this.received);

  Future<dynamic> get future => _result.future;

  void complete(dynamic value) {
    timer?.cancel();
    _result.complete(value);
  }

  void fail(Object error, StackTrace stack) {
    timer?.cancel();
    // Asynchronously, as before: a synchronous error delivered before the
    // caller listens would be reported as unhandled.
    scheduleMicrotask(() => _result.completeError(error, stack));
  }
}
