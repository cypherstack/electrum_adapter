import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

/// A channel whose transport can be aborted, and which counts the bytes it
/// has received, so that a client can tell a slow server from a silent one.
///
/// [connect] returns one. A wrapped or transformed channel is a plain
/// [StreamChannel]; use [withChannel] to keep this transport's controls:
///
/// ```dart
/// final transport = await connect(host);
/// final client =
///     BaseClient(transport.withChannel(transport.transformStream(logger)));
/// ```
class TransportChannel extends DelegatingStreamChannel<dynamic> {
  /// Releases the transport at once, without sending queued output.
  final void Function() abort;

  /// Completes once the transport has been released, by [abort] or by a
  /// graceful close that both sides have finished. Defaults to the sink's
  /// `done`.
  final Future<void> done;

  final int Function() _received;

  TransportChannel(StreamChannel<dynamic> channel, this.abort,
      {Future<void>? done, int Function()? received})
      : done = done ??
            channel.sink.done
                .then<void>((_) {}, onError: (Object _, StackTrace __) {}),
        _received = received ?? _none,
        super(channel);

  static int _none() => 0;

  /// The bytes received so far, under TLS as each record is decrypted, or 0
  /// when the transport does not count them.
  int get received => _received();

  /// Returns [channel], which wraps or transforms this one, with this
  /// transport's [abort], [done] and [received].
  TransportChannel withChannel(StreamChannel<dynamic> channel) =>
      TransportChannel(channel, abort, done: done, received: _received);
}

/// Adapts a raw socket, which TLS may sit on, to a channel of bytes.
///
/// The socket is read while the stream is listened to and not paused. Writes
/// wait for the socket to take each part. Closing the sink ends the stream,
/// sends queued output and then shuts down only the sending side, as closing
/// a dart:io [Socket] does; input that arrives until the other side closes is
/// read and discarded, so its close is still noticed. Receiving is never shut
/// down, which would discard input that has already arrived. The socket
/// closes once both sides are done, or at once on [abort].
class RawSocketChannel extends StreamChannelMixin<List<int>> {
  final RawSocket _socket;
  final void Function() _abortSocket;
  final Object Function(Object error)? _mapError;
  final bool _closeOnPeerEof;

  /// Whether to wait for the write event after every write before writing
  /// more or shutting down.
  final bool _confirmWrites;

  late final StreamController<List<int>> _input;
  late final StreamSubscription<RawSocketEvent> _events;
  final _output = StreamController<List<int>>(sync: true);
  late final StreamSubscription<List<int>> _writes;
  late final _ChannelSink _sink;
  final _queue = Queue<List<int>>();

  /// Marks where in the output the other side closed.
  final List<int> _peerEnd = <int>[];
  final _sent = Completer<void>();
  final _released = Completer<void>();
  int _offset = 0;
  int _received = 0;
  bool _closed = false;
  bool _peerClosed = false;
  bool _awaitingWrite = false;
  bool _outputEnded = false;
  bool _writeClosed = false;
  Object? _error;
  StackTrace? _errorStack;

  /// Listens to [events] instead when the socket already has a listener, as
  /// after a SOCKS handshake. [mapError] translates transport errors. With
  /// [closeOnPeerEof], the other side's close also closes this side once the
  /// output accepted before it, including a stream being added, is sent;
  /// later output is dropped.
  ///
  /// [confirmWrites] waits for the write event after every write. It defaults
  /// to true for a plain socket on Windows, whose write can still be pending
  /// after it took every byte, as dart:io's socket sink does.
  RawSocketChannel(this._socket, this._abortSocket,
      {Stream<RawSocketEvent>? events,
      Object Function(Object error)? mapError,
      bool closeOnPeerEof = false,
      bool? confirmWrites})
      : _mapError = mapError,
        _closeOnPeerEof = closeOnPeerEof,
        _confirmWrites = confirmWrites ??
            (Platform.isWindows && _socket is! RawSecureSocket) {
    _socket.readEventsEnabled = false;
    _socket.writeEventsEnabled = false;
    _sent.future.ignore();
    _input = StreamController<List<int>>(
      onListen: _updateReading,
      onPause: _updateReading,
      onResume: _updateReading,
      onCancel: _discard,
    );
    _sink = _ChannelSink(this);
    _writes =
        _output.stream.listen(_write, onError: _abortWith, onDone: _endOutput);
    _events =
        (events ?? _socket).listen(_event, onError: _fail, onDone: _onDone);
  }

  @override
  Stream<List<int>> get stream => _input.stream;

  @override
  StreamSink<List<int>> get sink => _sink;

  /// Completes once the socket has been released.
  Future<void> get done => _released.future;

  /// The number of bytes received so far.
  int get received => _received;

  /// Reads while a listener wants data, and always once input is discarded:
  /// only discarding closes the stream while the socket is open.
  void _updateReading() {
    if (_closed || _peerClosed) return;
    _socket.readEventsEnabled = _input.isClosed || !_input.isPaused;
  }

  /// Ends the stream and discards input from now on.
  void _discard() {
    if (_input.isClosed) return;
    _input.close().ignore();
    _updateReading();
  }

  void _event(RawSocketEvent event) {
    if (_closed) return;
    if (event == RawSocketEvent.read) {
      final List<int>? bytes;
      try {
        bytes = _socket.read();
      } catch (error, stack) {
        _fail(error, stack);
        return;
      }
      if (bytes == null) return;
      _received += bytes.length;
      if (!_input.isClosed) _input.add(bytes);
    } else if (event == RawSocketEvent.write) {
      _socket.writeEventsEnabled = false;
      if (!_awaitingWrite) return;
      _awaitingWrite = false;
      _pump();
    } else if (event == RawSocketEvent.readClosed) {
      _peerClosed = true;
      if (!_input.isClosed) _input.close().ignore();
      if (_writeClosed) {
        _socket.close().ignore();
      } else if (_closeOnPeerEof) {
        _sink._endAfterAccepted();
      }
    } else if (event == RawSocketEvent.closed) {
      _onDone();
    }
  }

  void _onDone() {
    if (_closed) return;
    // The socket ended before this side finished sending.
    if (!_writeClosed)
      _error ??= _mapped(const SocketException('Connection closed'));
    abort();
  }

  Object _mapped(Object error) => _mapError?.call(error) ?? error;

  /// Fails the transport with a transport error.
  void _fail(Object error, StackTrace stack) {
    if (_closed) return;
    final mapped = _mapped(error);
    _error ??= mapped;
    _errorStack ??= stack;
    // Once the stream has ended, done reports the failure.
    if (!_input.isClosed) _input.addError(mapped, stack);
    abort();
  }

  /// Fails the transport with an error added to its sink.
  void _abortWith(Object error, StackTrace stack) {
    if (_closed) return;
    _error ??= error;
    _errorStack ??= stack;
    abort();
  }

  void _write(List<int> bytes) {
    if (identical(bytes, _peerEnd)) return _endOutput();
    // Output after the other side's close is dropped.
    if (_closed || _outputEnded || bytes.isEmpty) return;
    _queue.add(bytes);
    if (!_awaitingWrite) _pump();
  }

  /// Writes queued output for as long as the socket takes it.
  void _pump() {
    while (!_closed && _queue.isNotEmpty) {
      final bytes = _queue.first;
      try {
        _offset += _socket.write(bytes, _offset);
      } catch (error, stack) {
        _fail(error, stack);
        return;
      }
      // A TLS write can report a failure synchronously.
      if (_closed) return;
      if (_offset < bytes.length) return _awaitWrite();
      _queue.removeFirst();
      _offset = 0;
      if (_confirmWrites) return _awaitWrite();
    }
    if (_closed) return;
    // Take more once what was queued has been written.
    if (_writes.isPaused) _writes.resume();
    if (_outputEnded) _shutdownOutput();
  }

  void _awaitWrite() {
    _awaitingWrite = true;
    _socket.writeEventsEnabled = true;
    if (!_writes.isPaused) _writes.pause();
  }

  /// The sink was closed, or output is dropped: send what is queued, then
  /// shut down sending.
  void _endOutput() {
    _outputEnded = true;
    if (!_closed && !_awaitingWrite && _queue.isEmpty) _shutdownOutput();
  }

  void _shutdownOutput() {
    if (_writeClosed) return;
    _writeClosed = true;
    _socket.shutdown(SocketDirection.send);
    if (_peerClosed) _socket.close().ignore();
    if (!_sent.isCompleted) _sent.complete();
  }

  void abort() {
    if (_closed) return;
    _closed = true;
    _abortSocket();
    _events.cancel().ignore();
    _writes.cancel().ignore();
    _queue.clear();
    if (_error == null &&
        (_output.isClosed || _outputEnded || _sink._ending) &&
        !_writeClosed) {
      // A close in progress was cut short, and its output was lost.
      _error = _mapped(const SocketException('Connection closed'));
      _errorStack = StackTrace.current;
    }
    final error = _error;
    if (!_sent.isCompleted) {
      if (error == null) {
        _sent.complete();
      } else {
        _sent.completeError(error, _errorStack);
      }
    }
    if (!_input.isClosed) _input.close().ignore();
    _released.complete();
  }
}

/// The sink of a [RawSocketChannel]: a stream controller's sink, so it rejects
/// use while a stream is being added and after close, and drops output once
/// the transport is released. Its [done] reports a transport failure even
/// when nothing was being written.
class _ChannelSink implements StreamSink<List<int>> {
  final RawSocketChannel _channel;

  /// The other side closed, and this side closes once the output accepted
  /// before then is sent.
  bool _ending = false;

  _ChannelSink(this._channel);

  StreamController<List<int>> get _output => _channel._output;

  @override
  void add(List<int> data) => _output.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _output.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      _output.addStream(stream).whenComplete(() {
        if (_ending) _markEnd();
      }).then((_) {
        // As a socket's sink does, report a transport failure.
        final error = _channel._error;
        if (error != null) {
          Error.throwWithStackTrace(
              error, _channel._errorStack ?? StackTrace.current);
        }
      });

  /// Sends the output accepted so far, including a stream being added, then
  /// closes; output added later is dropped.
  void _endAfterAccepted() {
    _ending = true;
    _markEnd();
  }

  void _markEnd() {
    // A closed sink already ends its output after what it accepted.
    if (_output.isClosed) return;
    try {
      _output.add(_channel._peerEnd);
    } on StateError {
      // A stream is being added; the end is marked when it is done.
    }
  }

  @override
  Future<void> close() {
    // Throws while a stream is being added.
    _output.close().ignore();
    // Closing the sink ends the stream, as for any StreamChannel.
    _channel._discard();
    return done;
  }

  @override
  Future<void> get done => _channel._sent.future;
}
