import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:electrum_adapter/src/socks.dart';
import 'package:socks_socket/socks_socket.dart';
import 'package:test/test.dart';

import 'support/socks.dart';

void main() {
  Future<Stream<RawSocketEvent>> negotiate(_ProxySocket socket) =>
      socksConnect(socket,
          proxyHost: '127.0.0.1',
          proxyPort: 9050,
          targetHost: 'electrum.example',
          targetPort: 50001);

  Future<List<RawSocketEvent>> takeOver(
      _ProxySocket socket, Stream<RawSocketEvent> stream) async {
    final events = <RawSocketEvent>[];
    stream.listen((event) {
      events.add(event);
      // As any owner must: read events repeat until the input is read.
      if (event == RawSocketEvent.read) socket.read();
    });
    socket.readEventsEnabled = true;
    await pumpEventQueue();
    return events;
  }

  test('a proxy close that arrives with the reply reaches the next owner',
      () async {
    // The target accepted and closed at once; the proxy relays the reply and
    // its close together.
    final socket = _ProxySocket(socksSucceeded, closeWithReply: true);
    final events = await takeOver(socket, await negotiate(socket));
    expect(events, [RawSocketEvent.readClosed]);
  });

  test('input after the reply stays unread for the next owner', () async {
    final socket =
        _ProxySocket([...socksSucceeded, 1, 2, 3], closeWithReply: true);
    final stream = await negotiate(socket);
    expect(socket.available(), 3);
    final events = await takeOver(socket, stream);
    expect(events.first, RawSocketEvent.read);
    expect(events.last, RawSocketEvent.readClosed);
  });

  for (final (greeting, reason) in [
    ([4, 0], 'invalid reply version'),
    ([5, 0xff], 'proxy rejected authentication method'),
    ([5, 0, 9], 'reply has unexpected trailing data'),
  ]) {
    test('a greeting with $reason fails the handshake', () async {
      final socket = _ProxySocket(socksSucceeded, greeting: greeting);
      await expectLater(
          negotiate(socket),
          throwsA(isA<SocksHandshakeException>().having((e) => e.message,
              'message', 'SOCKS5 handshake failed: $reason')));
    });
  }

  test('a truncated reply fails with a SOCKS connection error', () async {
    final socket = _ProxySocket([5, 0, 0, 1, 0, 0], closeWithReply: true);
    await expectLater(
        negotiate(socket), throwsA(isA<SocksConnectionException>()));
  });
}

/// A proxy's end of a raw socket, delivering events with dart:io's rules: a
/// read event repeats in a microtask while input is unread, and the close is
/// dispatched once input is drained, only while read events are enabled.
class _ProxySocket extends Stream<RawSocketEvent> implements RawSocket {
  final List<int> _reply;
  final List<int> _greeting;
  final bool _closeWithReply;
  late final _controller = StreamController<RawSocketEvent>(
      sync: true,
      onListen: _apply,
      onPause: _apply,
      onResume: _apply,
      onCancel: _apply);
  final _input = <int>[];
  final _written = <int>[];
  bool _readEventsEnabled = true;
  bool _closed = false;
  bool _closedRead = false;
  bool _closedReadSent = false;
  bool _readEventIssued = false;
  bool _sendReadEvents = false;

  _ProxySocket(this._reply,
      {bool closeWithReply = false, List<int> greeting = const [5, 0]})
      : _closeWithReply = closeWithReply,
        _greeting = greeting;

  void _apply() {
    _sendReadEvents = _controller.hasListener &&
        !_controller.isPaused &&
        _readEventsEnabled &&
        !_closed;
    if (_sendReadEvents) _issueReadEvent();
  }

  void _arrive(List<int> bytes, {bool close = false}) {
    _input.addAll(bytes);
    if (close) _closedRead = true;
    _issueReadEvent();
  }

  // Mirrors _NativeSocket.issueReadEvent in dart:io.
  void _issueReadEvent() {
    if (_closedReadSent || _readEventIssued) return;
    _readEventIssued = true;
    void issue() {
      _readEventIssued = false;
      if (_closed || !_sendReadEvents) return;
      if (_input.isEmpty) {
        if (_closedRead && !_closedReadSent) {
          _closedReadSent = true;
          _controller.add(RawSocketEvent.readClosed);
        }
        return;
      }
      _controller.add(RawSocketEvent.read);
      _readEventIssued = true;
      scheduleMicrotask(issue);
    }

    scheduleMicrotask(issue);
  }

  @override
  int write(List<int> buffer, [int offset = 0, int? count]) {
    final end = count == null ? buffer.length : offset + count;
    _written.addAll(buffer.sublist(offset, end));
    if (_written.length == 3) {
      Timer.run(() => _arrive(_greeting));
    } else if (_written.length > 3 && _written[3] != 0) {
      Timer.run(() => _arrive(_reply, close: _closeWithReply));
      _written.add(0);
    }
    return end - offset;
  }

  @override
  int available() => _input.length;

  @override
  Uint8List? read([int? len]) {
    if (_input.isEmpty) return null;
    final count = len == null || len > _input.length ? _input.length : len;
    final bytes = Uint8List.fromList(_input.sublist(0, count));
    _input.removeRange(0, count);
    return bytes;
  }

  @override
  bool get readEventsEnabled => _readEventsEnabled;
  @override
  set readEventsEnabled(bool value) {
    _readEventsEnabled = value;
    _apply();
  }

  @override
  bool writeEventsEnabled = false;

  @override
  Future<RawSocket> close() async {
    _closed = true;
    _controller.close().ignore();
    return this;
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
          void Function(RawSocketEvent event)? onData,
          {Function? onError,
          void Function()? onDone,
          bool? cancelOnError}) =>
      _controller.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
