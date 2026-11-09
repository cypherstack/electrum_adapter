import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Forwards a raw socket under TLS, and can fail its listener on demand.
///
/// dart:io's TLS layer releases its native state when its socket reports an
/// error. Closing the socket under it is not enough: with input still
/// buffered it never finishes tearing down, during the handshake or after. A
/// TLS socket built on this wrapper is therefore aborted with [abort].
class AbortableRawSocket extends Stream<RawSocketEvent> implements RawSocket {
  final RawSocket _socket;
  late final StreamSubscription<RawSocketEvent> _source;
  late final StreamController<RawSocketEvent> _events;
  bool _aborted = false;

  /// Listens to [events] instead when [_socket] already has a listener, as
  /// after a SOCKS handshake.
  AbortableRawSocket(this._socket, [Stream<RawSocketEvent>? events]) {
    _events = StreamController<RawSocketEvent>(
      sync: true,
      onPause: () => _source.pause(),
      onResume: () => _source.resume(),
      onCancel: () => _source.cancel(),
    );
    _source = (events ?? _socket).listen(_events.add,
        onError: _events.addError, onDone: () => _events.close().ignore());
  }

  /// Fails the listener with [error], then closes the socket.
  void abort(Object error) {
    if (_aborted) return;
    _aborted = true;
    if (!_events.isClosed) _events.addError(error);
    _socket.close().ignore();
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
          void Function(RawSocketEvent event)? onData,
          {Function? onError,
          void Function()? onDone,
          bool? cancelOnError}) =>
      _events.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  bool get readEventsEnabled => _socket.readEventsEnabled;

  @override
  set readEventsEnabled(bool value) => _socket.readEventsEnabled = value;

  @override
  bool get writeEventsEnabled => _socket.writeEventsEnabled;

  @override
  set writeEventsEnabled(bool value) => _socket.writeEventsEnabled = value;

  @override
  int available() => _socket.available();

  @override
  Uint8List? read([int? len]) => _socket.read(len);

  @override
  SocketMessage? readMessage([int? count]) => _socket.readMessage(count);

  @override
  int write(List<int> buffer, [int offset = 0, int? count]) =>
      _socket.write(buffer, offset, count);

  @override
  int sendMessage(List<SocketControlMessage> controlMessages, List<int> data,
          [int offset = 0, int? count]) =>
      _socket.sendMessage(controlMessages, data, offset, count);

  @override
  Future<RawSocket> close() async {
    await _socket.close();
    return this;
  }

  @override
  void shutdown(SocketDirection direction) => _socket.shutdown(direction);

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);

  @override
  InternetAddress get address => _socket.address;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get port => _socket.port;

  @override
  int get remotePort => _socket.remotePort;
}
