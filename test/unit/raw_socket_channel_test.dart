import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:electrum_adapter/src/transport_channel.dart';
import 'package:test/test.dart';

void main() {
  RawSocketChannel open(_Socket socket,
          {bool closeOnPeerEof = false,
          bool? confirmWrites,
          Object Function(Object error)? mapError}) =>
      RawSocketChannel(socket, () {
        socket.close();
      },
          closeOnPeerEof: closeOnPeerEof,
          confirmWrites: confirmWrites,
          mapError: mapError);

  test('a rejected addStream leaves the sink usable', () async {
    final socket = _Socket();
    final channel = open(socket);
    final listened = Stream<List<int>>.value([1])..listen(null);
    expect(() => channel.sink.addStream(listened), throwsStateError);
    channel.sink.add([2]);
    await channel.sink.close();
    expect(() => channel.sink.addStream(Stream.value([3])), throwsStateError);
    await channel.sink.close();
    expect(socket.written, [2]);
    socket.peerClose();
    await channel.done.timeout(const Duration(seconds: 1));
  });

  test('partial writes preserve every byte and their order', () async {
    final socket = _Socket();
    final channel = open(socket);
    final input = channel.stream.drain<void>();
    channel.sink.add(List<int>.generate(1000, (i) => i % 256));
    channel.sink.add([9, 8, 7]);
    await channel.sink.close();
    expect(
        socket.written, [...List<int>.generate(1000, (i) => i % 256), 9, 8, 7]);
    // Like a dart:io Socket, closing the sink only shuts down sending.
    expect(socket.sendShutdown, isTrue);
    expect(socket.closed, isFalse);
    await input;
    socket.peerClose();
    await channel.done.timeout(const Duration(seconds: 1));
    expect(socket.closed, isTrue);
  });

  test(
      'closing the sink ends the stream and discards input until the peer '
      'closes', () async {
    final socket = _Socket();
    final channel = open(socket);
    final replies = <List<int>>[];
    final input = channel.stream.listen(replies.add).asFuture<void>();
    socket.deliver([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);
    await channel.sink.close();
    await input.timeout(const Duration(seconds: 1));
    socket.deliver([4, 5]);
    await Future<void>.delayed(Duration.zero);
    expect(replies, [
      [1, 2, 3]
    ]);
    // Discarded input is still read, so the peer's close is noticed.
    expect(socket.unread, isEmpty);
    expect(socket.receiveShutdown, isFalse);
    socket.peerClose();
    await channel.done.timeout(const Duration(seconds: 1));
    expect(socket.closed, isTrue);
  });

  test('cancelling the input keeps reading without shutting down receiving',
      () async {
    final socket = _Socket();
    final channel = open(socket);
    await channel.stream.listen((_) {}).cancel();
    // Shutting down receiving discards input that has already arrived; on
    // macOS that can leave dart:io re-issuing read events forever.
    expect(socket.receiveShutdown, isFalse);
    expect(socket.readEventsEnabled, isTrue);
    socket.deliver([1, 2]);
    await Future<void>.delayed(Duration.zero);
    expect(socket.unread, isEmpty);
    channel.sink.add([7]);
    await Future<void>.delayed(Duration.zero);
    expect(socket.written, [7]);
    expect(socket.sendShutdown, isFalse);
    await channel.sink.close();
    socket.peerClose();
    await channel.done.timeout(const Duration(seconds: 1));
    expect(socket.closed, isTrue);
  });

  test(
      'an unlistened channel still notices the peer closing after its sink '
      'closes', () async {
    final socket = _Socket();
    final channel = open(socket);
    expect(socket.readEventsEnabled, isFalse);
    await channel.sink.close();
    expect(socket.readEventsEnabled, isTrue);
    socket.peerClose();
    await channel.done.timeout(const Duration(seconds: 1));
    expect(socket.closed, isTrue);
  });

  test('a paused listener does not keep a closed channel open', () async {
    final socket = _Socket();
    final channel = open(socket);
    final subscription = channel.stream.listen((_) {});
    final ended = subscription.asFuture<void>();
    subscription.pause();
    await channel.sink.close();
    socket.deliver([1]);
    socket.peerClose();
    await channel.done.timeout(const Duration(seconds: 1));
    expect(socket.closed, isTrue);
    subscription.resume();
    await ended.timeout(const Duration(seconds: 1));
  });

  test('peer EOF closes the sink after queued output when asked to', () async {
    final socket = _Socket()..blocked = true;
    final channel = open(socket, closeOnPeerEof: true);
    final input = channel.stream.drain<void>();
    channel.sink.add([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    await socket.attempted.future;
    socket.peerClose();
    await input;
    // Output added after the peer closed is dropped, not thrown.
    channel.sink.add([11]);
    expect(socket.sendShutdown, isFalse);
    socket.unblock();
    await channel.sink.done.timeout(const Duration(seconds: 1));
    expect(socket.written, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    expect(socket.sendShutdown, isTrue);
    await channel.done.timeout(const Duration(seconds: 1));
  });

  test('peer EOF still sends every message accepted before it', () async {
    final socket = _Socket()..blocked = true;
    final channel = open(socket, closeOnPeerEof: true);
    final input = channel.stream.drain<void>();
    channel.sink.add([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    await socket.attempted.future;
    // Queued behind the blocked write.
    channel.sink.add([11]);
    channel.sink.add([12]);
    socket.peerClose();
    await input;
    channel.sink.add([13]);
    socket.unblock();
    await channel.sink.done.timeout(const Duration(seconds: 1));
    expect(socket.written, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
    expect(socket.sendShutdown, isTrue);
    await channel.done.timeout(const Duration(seconds: 1));
  });

  test(
      'cancelling the input of a channel that closes on peer EOF keeps its '
      'output open', () async {
    final socket = _Socket();
    final channel = open(socket, closeOnPeerEof: true);
    await channel.stream.listen((_) {}).cancel();
    await Future<void>.delayed(Duration.zero);
    channel.sink.add([1, 2]);
    await Future<void>.delayed(Duration.zero);
    expect(socket.written, [1, 2]);
    expect(socket.sendShutdown, isFalse);
    expect(socket.closed, isFalse);
    socket.peerClose();
    await channel.done.timeout(const Duration(seconds: 1));
  });

  test('abort releases a blocked write and its close Future', () async {
    final socket = _Socket()..blocked = true;
    final channel = open(socket);
    channel.sink.add([1, 2, 3]);
    final closing =
        expectLater(channel.sink.close(), throwsA(isA<SocketException>()));
    await socket.attempted.future;
    channel.abort();
    await closing.timeout(const Duration(seconds: 1));
    expect(socket.closed, isTrue);
  });

  test('a protocol abort fails blocked output with its original error',
      () async {
    final socket = _Socket()..blocked = true;
    final channel = open(socket);
    final error = FormatException('message too large');
    final adding = channel.sink.addStream(Stream.value([1, 2, 3]));
    final failed = expectLater(adding, throwsA(same(error)));
    await socket.attempted.future;
    channel.abort(error);
    await channel.done.timeout(const Duration(seconds: 1));
    await failed.timeout(const Duration(seconds: 1));
    await expectLater(channel.sink.done, throwsA(same(error)));
    await expectLater(channel.sink.close(), throwsA(same(error)));
    expect(socket.closed, isTrue);
    expect(socket.written, isEmpty);
  });

  test('a synchronous read failure reaches the stream and closes the transport',
      () async {
    final socket = _Socket();
    final channel = open(socket);
    final result = expectLater(channel.stream,
        emitsInOrder([emitsError(isA<SocketException>()), emitsDone]));
    socket.failRead();
    await result;
    expect(socket.closed, isTrue);
  });

  test('a transport error fails the stream, done and close with one error',
      () async {
    final socket = _Socket();
    final channel =
        open(socket, mapError: (error) => StateError('mapped: $error'));
    final result = expectLater(channel.stream,
        emitsInOrder([emitsError(isA<StateError>()), emitsDone]));
    final done = expectLater(channel.sink.done, throwsA(isA<StateError>()));
    socket.reset();
    await result;
    await done;
    await expectLater(channel.sink.close(), throwsA(isA<StateError>()));
    expect(socket.closed, isTrue);
  });

  test('a transport error after the sink closes does not reach the stream',
      () async {
    final socket = _Socket()..blocked = true;
    final channel = open(socket);
    final errors = <Object>[];
    final input =
        channel.stream.listen((_) {}, onError: errors.add).asFuture<void>();
    channel.sink.add([1]);
    final closing =
        expectLater(channel.sink.close(), throwsA(isA<SocketException>()));
    await input.timeout(const Duration(seconds: 1));
    socket.reset();
    await closing;
    await channel.done.timeout(const Duration(seconds: 1));
    expect(errors, isEmpty);
  });

  test(
      'peer EOF while a stream is being added sends the rest of it, then '
      'closes', () async {
    final socket = _Socket()..blocked = true;
    final channel = open(socket, closeOnPeerEof: true);
    final input = channel.stream.drain<void>();
    final source = StreamController<List<int>>();
    final adding = channel.sink.addStream(source.stream);
    source.add([1, 2, 3, 4, 5, 6, 7, 8, 9]);
    await socket.attempted.future;
    // An uncaught error from the event handler would fail this test.
    socket.peerClose();
    await input;
    // The stream was accepted before the peer closed, so all of it is sent.
    source.add([10]);
    source.close().ignore();
    expect(socket.sendShutdown, isFalse);
    socket.unblock();
    await adding.timeout(const Duration(seconds: 1));
    channel.sink.add([11]);
    await channel.sink.done.timeout(const Duration(seconds: 1));
    expect(socket.written, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    expect(socket.sendShutdown, isTrue);
    await channel.done.timeout(const Duration(seconds: 1));
    await channel.sink.close().timeout(const Duration(seconds: 1));
  });

  test('abort ends a stream being added without an error', () async {
    final socket = _Socket()..blocked = true;
    final channel = open(socket);
    final source = StreamController<List<int>>();
    final adding = channel.sink.addStream(source.stream);
    source.add([1, 2, 3]);
    await socket.attempted.future;
    channel.abort();
    // As when a socket is destroyed: a pipe or cast() would make an error
    // here uncaught.
    await adding.timeout(const Duration(seconds: 1));
    await channel.sink.done.timeout(const Duration(seconds: 1));
    expect(source.hasListener, isFalse);
  });

  test('a stream being added that fails fails the transport', () async {
    final socket = _Socket();
    final channel = open(socket);
    final error = StateError('source failed');
    final done = expectLater(channel.sink.done, throwsA(same(error)));
    final adding = expectLater(
        channel.sink.addStream(Stream.error(error)), throwsA(same(error)));
    await adding;
    await done;
    expect(socket.closed, isTrue);
  });

  test('close is rejected while a stream is being added, without effect',
      () async {
    final socket = _Socket();
    final channel = open(socket);
    final replies = <List<int>>[];
    final input = channel.stream.listen(replies.add).asFuture<void>();
    final source = StreamController<List<int>>();
    final adding = channel.sink.addStream(source.stream);
    expect(channel.sink.close, throwsStateError);
    expect(() => channel.sink.add([0]), throwsStateError);
    // The stream has not ended and the sink still sends.
    socket.deliver([1, 2]);
    source.add([3]);
    await Future<void>.delayed(Duration.zero);
    expect(replies, [
      [1, 2]
    ]);
    expect(socket.written, [3]);
    await source.close();
    await adding;
    await channel.sink.close().timeout(const Duration(seconds: 1));
    expect(socket.sendShutdown, isTrue);
    await input.timeout(const Duration(seconds: 1));
    socket.peerClose();
    await channel.done.timeout(const Duration(seconds: 1));
  });

  test('a stream cannot be added once the sink is closed', () async {
    final socket = _Socket();
    final channel = open(socket);
    channel.sink.add([1]);
    final closing = channel.sink.close();
    expect(() => channel.sink.addStream(Stream.value([2])), throwsStateError);
    await closing.timeout(const Duration(seconds: 1));
    expect(socket.written, [1]);
    expect(socket.sendShutdown, isTrue);
  });

  test('a stream added after the transport failed fails with its error',
      () async {
    final socket = _Socket();
    final channel = open(socket);
    final input =
        expectLater(channel.stream, emitsError(isA<SocketException>()));
    socket.reset();
    await input;
    var listened = false;
    final source = StreamController<List<int>>(onListen: () => listened = true);
    await expectLater(
        channel.sink.addStream(source.stream), throwsA(isA<SocketException>()));
    expect(listened, isFalse);
  });

  test('a close cut short reports its loss as a mapped error', () async {
    final socket = _Socket()..blocked = true;
    final channel =
        open(socket, mapError: (error) => StateError('mapped: $error'));
    channel.sink.add([1, 2, 3]);
    final closing = expectLater(
        channel.sink.close(),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('Connection closed'))));
    await socket.attempted.future;
    channel.abort();
    await closing.timeout(const Duration(seconds: 1));
  });

  test('a socket that ends before sending finishes reports a mapped error',
      () async {
    final socket = _Socket()..blocked = true;
    final channel =
        open(socket, mapError: (error) => StateError('mapped: $error'));
    channel.stream.listen(null, onError: (Object _) {});
    channel.sink.add([1, 2, 3]);
    final done = expectLater(
        channel.sink.done,
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('Connection closed'))));
    await socket.attempted.future;
    await socket.close();
    await done.timeout(const Duration(seconds: 1));
  });

  test('a stream added after a close was cut short fails with its loss',
      () async {
    final socket = _Socket()..blocked = true;
    final channel = open(socket, closeOnPeerEof: true);
    channel.stream.listen(null, onError: (Object _) {});
    channel.sink.add([1, 2, 3]);
    final done =
        expectLater(channel.sink.done, throwsA(isA<SocketException>()));
    await socket.attempted.future;
    // The peer's close closes this side once its output is sent, which an
    // abort cuts short.
    socket.peerClose();
    await Future<void>.delayed(Duration.zero);
    channel.abort();
    await done;
    await expectLater(channel.sink.addStream(Stream.value([4])),
        throwsA(isA<SocketException>()));
  });

  test('a stream being added waits while the socket has no room', () async {
    final socket = _Socket()..blocked = true;
    final channel = open(socket);
    var delivered = 0;
    final source = StreamController<List<int>>();
    final adding = channel.sink.addStream(source.stream.map((chunk) {
      delivered++;
      return chunk;
    }));
    for (var i = 0; i < 10; i++) {
      source.add([i]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // The first chunk waits for the socket; the rest wait in the source.
    expect(delivered, 1);
    socket.unblock();
    await source.close();
    await adding.timeout(const Duration(seconds: 1));
    expect(socket.written, List<int>.generate(10, (i) => i));
    await channel.sink.close().timeout(const Duration(seconds: 1));
  });

  test('a stream being added is read as the socket takes it', () async {
    final socket = _Socket();
    final channel = open(socket);
    final chunks = List<List<int>>.generate(
        20, (i) => List<int>.generate(10, (j) => (i * 10 + j) % 256));
    await channel.sink.addStream(Stream.fromIterable(chunks));
    expect(socket.written, chunks.expand((chunk) => chunk).toList());
    await channel.sink.close().timeout(const Duration(seconds: 1));
  });

  test('a write the socket takes whole does not wait for a write event',
      () async {
    final socket = _Socket();
    final channel = open(socket, confirmWrites: false);
    channel.sink.add([1, 2, 3]);
    channel.sink.add([4, 5, 6]);
    expect(socket.written, [1, 2, 3, 4, 5, 6]);
    expect(socket.writeWaits, 0);
    // A partial write waits for one.
    channel.sink.add(List<int>.filled(10, 7));
    expect(socket.writeWaits, 1);
    await channel.sink.close().timeout(const Duration(seconds: 1));
    expect(socket.written.length, 16);
  });

  test('with write confirmation, each write waits for its write event',
      () async {
    final socket = _Socket()..holdWriteEvents = true;
    final channel = open(socket, confirmWrites: true);
    channel.sink.add([1, 2, 3]);
    channel.sink.add([4, 5]);
    final closed = channel.sink.close();
    await Future<void>.delayed(Duration.zero);
    // As on Windows, a write the socket took whole may still be in flight.
    expect(socket.written, [1, 2, 3]);
    socket.releaseWriteEvent();
    await Future<void>.delayed(Duration.zero);
    expect(socket.written, [1, 2, 3, 4, 5]);
    expect(socket.sendShutdown, isFalse);
    socket.releaseWriteEvent();
    await closed.timeout(const Duration(seconds: 1));
    expect(socket.sendShutdown, isTrue);
  });

  test('received counts the bytes read', () async {
    final socket = _Socket();
    final channel = open(socket);
    final input = channel.stream.drain<void>();
    socket.deliver([1, 2, 3]);
    await Future<void>.delayed(Duration.zero);
    socket.deliver([4]);
    await Future<void>.delayed(Duration.zero);
    expect(channel.received, 4);
    socket.peerClose();
    await input;
    channel.abort();
  });
}

/// A raw socket double that delivers input as dart:io does: read events and
/// the peer's close only while read events are enabled, the close once the
/// input is drained. Like dart:io, it closes once both directions are shut
/// down and the peer's close has been read.
class _Socket extends Stream<RawSocketEvent> implements RawSocket {
  late final _events =
      StreamController<RawSocketEvent>(sync: true, onResume: _issue);
  final written = <int>[];
  final attempted = Completer<void>();
  final unread = <int>[];
  bool blocked = false;

  /// Withholds write events until [releaseWriteEvent].
  bool holdWriteEvents = false;
  bool closed = false;
  bool sendShutdown = false;
  bool receiveShutdown = false;
  // dart:io sockets start with read events enabled.
  bool _readEventsEnabled = true;
  bool _readFails = false;
  bool _peerClosed = false;
  bool _closedReadSent = false;
  bool _issued = false;
  int writeWaits = 0;

  void failRead() {
    _readFails = true;
    unread.add(0);
    _issue();
  }

  void deliver(List<int> bytes) {
    unread.addAll(bytes);
    _issue();
  }

  void peerClose() {
    _peerClosed = true;
    _issue();
  }

  void reset() => scheduleMicrotask(() {
        if (!closed) _events.addError(const SocketException('reset'));
      });

  void unblock() {
    blocked = false;
    releaseWriteEvent();
  }

  void releaseWriteEvent() => scheduleMicrotask(() {
        if (!closed) _events.add(RawSocketEvent.write);
      });

  void _issue() {
    if (_issued) return;
    _issued = true;
    scheduleMicrotask(() {
      _issued = false;
      // Like dart:io, nothing is delivered to a paused listener.
      if (closed || !_readEventsEnabled || _events.isPaused) return;
      if (unread.isNotEmpty) {
        _events.add(RawSocketEvent.read);
        _issue();
      } else if (_peerClosed && !_closedReadSent) {
        _closedReadSent = true;
        _events.add(RawSocketEvent.readClosed);
      }
    });
  }

  @override
  Uint8List? read([int? length]) {
    if (_readFails) throw const SocketException('Read failed');
    if (unread.isEmpty) return null;
    final bytes = Uint8List.fromList(unread);
    unread.clear();
    return bytes;
  }

  @override
  bool get readEventsEnabled => _readEventsEnabled;
  @override
  set readEventsEnabled(bool value) {
    _readEventsEnabled = value;
    if (value) _issue();
  }

  @override
  bool get writeEventsEnabled => false;
  @override
  set writeEventsEnabled(bool value) {
    if (value) writeWaits++;
    if (value && !blocked && !holdWriteEvents && !closed) {
      scheduleMicrotask(() {
        if (!closed) _events.add(RawSocketEvent.write);
      });
    }
  }

  @override
  int write(List<int> buffer, [int offset = 0, int? count]) {
    if (!attempted.isCompleted) attempted.complete();
    if (blocked) return 0;
    final length = (count ?? buffer.length - offset).clamp(0, 7);
    written.addAll(buffer.sublist(offset, offset + length));
    return length;
  }

  @override
  void shutdown(SocketDirection direction) {
    if (direction == SocketDirection.send) sendShutdown = true;
    if (direction == SocketDirection.receive) {
      // As in dart:io on macOS: unread input is discarded, and a readClosed
      // follows as if the peer had closed.
      receiveShutdown = true;
      unread.clear();
      peerClose();
    }
  }

  @override
  Future<RawSocket> close() async {
    if (!closed) {
      closed = true;
      _events.close().ignore();
    }
    return this;
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
          void Function(RawSocketEvent)? onData,
          {Function? onError,
          void Function()? onDone,
          bool? cancelOnError}) =>
      _events.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
