import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:electrum_adapter/client/base_client.dart';
import 'package:electrum_adapter/electrum_adapter.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

/// A sink whose close never finishes, as with a server that stopped reading.
NullStreamSink<dynamic> _stuck() =>
    NullStreamSink<dynamic>(done: Completer<void>().future);

void main() {
  late FakeServer server;
  late BaseClient client;
  late List<Map<String, dynamic>> requests;

  void reply(Map<String, dynamic> request, Object? result) =>
      server.reply(request, result);

  setUp(() {
    server = FakeServer();
    requests = server.requests;
    client = BaseClient(server.channel,
        requestTimeout: const Duration(milliseconds: 100));
  });
  tearDown(() => client.close());

  test('a silent RPC times out and closes the peer', () async {
    await expectLater(
        client.request('silent'), throwsA(isA<TimeoutException>()));
    expect(client.peer.isClosed, isTrue);
    await expectLater(client.done, throwsA(isA<TimeoutException>()));
    await expectLater(client.request('later'), throwsStateError);
  });

  test("the oldest request's deadline closes a silent connection", () async {
    final short = client.requestWithTimeout('short',
        timeout: const Duration(milliseconds: 30));
    final other =
        client.requestWithTimeout('long', timeout: const Duration(seconds: 10));
    final closed = isA<TimeoutException>().having(
        (e) => e.message,
        'message',
        'Electrum request "short" timed out and nothing was received; '
            'connection closed');
    await Future.wait([
      expectLater(short, throwsA(closed)),
      expectLater(other, throwsA(closed)),
    ]).timeout(const Duration(seconds: 1));
    expect(client.peer.isClosed, isTrue);
  });

  test("a newer request's deadline does not cut short an older one", () async {
    final long =
        client.requestWithTimeout('long', timeout: const Duration(seconds: 10));
    await expectLater(
        client.requestWithTimeout('short',
            timeout: const Duration(milliseconds: 30)),
        throwsA(isA<TimeoutException>()
            .having((e) => e.message, 'message',
                'Electrum request "short" timed out')
            .having((e) => e.duration, 'duration',
                const Duration(milliseconds: 30))));
    // The server may still be busy with the older request.
    expect(client.peer.isClosed, isFalse);
    reply(requests.first, 'done');
    expect(await long, 'done');
  });

  test('successful responses cancel their deadline', () async {
    server.respond = (request) => reply(request, 'ok');
    final timers = <Timer>[];
    final result = await runZoned(() => client.request('first'),
        zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
      final timer = parent.createTimer(zone, duration, callback);
      timers.add(timer);
      return timer;
    }));
    expect(result, 'ok');
    expect(timers, hasLength(1));
    expect(timers.single.isActive, isFalse);
  });

  test('per-request timeout can exceed the client default', () async {
    final pending = client.requestWithTimeout('slow',
        parameters: ['argument'], timeout: const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(client.peer.isClosed, isFalse);
    expect(requests.single['params'], ['argument']);
    reply(requests.single, 'late but allowed');
    expect(await pending, 'late but allowed');
  });

  test('one omitted batch reply fails only that member', () async {
    server.respond = (request) {
      if (request['method'] == 'answers') reply(request, 'ok');
    };
    late Future<dynamic> answered, omitted;
    client.peer.withBatch(() {
      answered = client.request('answers');
      omitted = client.request('silent');
    });
    expect(await answered, 'ok');
    await expectLater(omitted, throwsA(isA<TimeoutException>()));
    expect(requests.map((r) => r['method']), ['answers', 'silent']);
    expect(client.peer.isClosed, isFalse);
  });

  test('a request issued while another is sent keeps its own deadline',
      () async {
    final sync = FakeServer(sync: true);
    final seen = sync.requests;
    sync.respond = (request) {
      if (request['method'] == 'trigger') {
        // The answer to 'first' is delivered while 'trigger' is sent.
        sync.reply(seen.first, 'one');
      }
    };
    final nested = BaseClient(sync.channel);
    addTearDown(nested.close);
    late Future<dynamic> second;
    final first = nested.request('first').then((dynamic _) {
      second = nested.requestWithTimeout('second',
          timeout: const Duration(seconds: 1));
    });
    await Future<void>.delayed(Duration.zero);
    final trigger = nested.requestWithTimeout('trigger',
        timeout: const Duration(milliseconds: 50));
    await first;
    // Something arrives, so 'trigger' fails alone at its deadline.
    Timer(const Duration(milliseconds: 20), () {
      sync.sink.add({'jsonrpc': '2.0', 'id': 999, 'result': null});
    });
    await expectLater(trigger, throwsA(isA<TimeoutException>()));
    // 'second' was not abandoned in its place.
    sync.reply(seen.last, 'two');
    expect(await second, 'two');
  });

  test('a timeout fails only its request while the server is sending',
      () async {
    final slow = client.requestWithTimeout('slow',
        timeout: const Duration(milliseconds: 60));
    final fast = expectLater(slow, throwsA(isA<TimeoutException>()));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    server.respond = (request) => reply(request, 'ok');
    expect(await client.request('other'), 'ok');
    await fast;
    expect(client.peer.isClosed, isFalse);
    // A late response to the expired request is discarded.
    reply(requests.first, 'late');
    expect(await client.request('again'), 'ok');
    expect(client.peer.isClosed, isFalse);
  });

  test('bytes arriving keep the connection open when a request times out',
      () async {
    final input = StreamController<dynamic>();
    var received = 0;
    final transport = TransportChannel(
        StreamChannel<dynamic>(input.stream, NullStreamSink<dynamic>()), () {},
        received: () => received);
    final counting =
        BaseClient(transport, requestTimeout: const Duration(milliseconds: 60));
    addTearDown(() async {
      await counting.close();
      await input.close();
    });
    // Part of a long response arrives, but no whole message.
    final arriving = Timer.periodic(
        const Duration(milliseconds: 10), (_) => received += 100);
    addTearDown(arriving.cancel);
    await expectLater(
        counting.request('slow'), throwsA(isA<TimeoutException>()));
    expect(counting.peer.isClosed, isFalse);
    arriving.cancel();
    // Then nothing arrives for a whole deadline.
    await expectLater(
        counting.request('silent'), throwsA(isA<TimeoutException>()));
    expect(counting.peer.isClosed, isTrue);
  });

  test('an RPC error does not close a healthy connection', () async {
    server.respond = (request) => server.sink.add({
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {'code': -32601, 'message': 'unknown method'},
        });
    await expectLater(
        client.request('unknown'), throwsA(isA<rpc.RpcException>()));
    server.respond = (request) => reply(request, 'ok');
    expect(await client.request('supported'), 'ok');
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(client.peer.isClosed, isFalse);
  });

  test('remote EOF releases pending requests', () async {
    final pending = expectLater(client.request('silent'), throwsStateError);
    await server.sink.close();
    await pending;
    await client.done;
    expect(client.peer.isClosed, isTrue);
  });

  test('a response immediately followed by EOF still reaches its caller',
      () async {
    server.respond = (request) {
      reply(request, 'last response');
      server.sink.close().ignore();
    };
    expect(await client.request('last'), 'last response');
    await client.done;
    expect(client.peer.isClosed, isTrue);
  });

  test('transport errors are observed and terminate the client', () async {
    final error = Exception('broken transport');
    // Pending requests fail with a StateError, as when json_rpc_2 reported
    // the closure; done keeps the transport's error.
    final pending = expectLater(
        client.request('silent'),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('broken transport'))));
    server.sink.addError(error, StackTrace.current);
    await expectLater(client.done, throwsA(same(error)));
    await pending;
    expect(client.peer.isClosed, isTrue);
  });

  test('a transport timeout fails pending requests with a StateError',
      () async {
    // Such as the transport's own write stall: the connection failed, which
    // is not a request deadline.
    final stalled = TimeoutException('could not send');
    final pending = expectLater(
        client.request('silent'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('could not send'))));
    server.sink.addError(stalled, StackTrace.current);
    await expectLater(client.done, throwsA(same(stalled)));
    await pending;
  });

  test('a channel whose stream already has a listener is rejected at once',
      () async {
    final shared = StreamChannelController<dynamic>();
    shared.local.stream.listen((_) {});
    // Any uncaught error would fail this test.
    expect(() => BaseClient(shared.local), throwsStateError);
    await Future<void>.delayed(Duration.zero);
  });

  test('a sink that rejects a second close does not fail a clean close',
      () async {
    final input = StreamController<dynamic>();
    final once = BaseClient(StreamChannel<dynamic>(input.stream, _OnceSink()));
    await once.close();
    await once.done;
    await input.close();
  });

  test('invalid timeouts send no request and do not break the client',
      () async {
    for (final timeout in [Duration.zero, const Duration(milliseconds: -1)]) {
      await expectLater(
          client.requestWithTimeout('invalid', timeout: timeout),
          throwsA(
              isA<ArgumentError>().having((e) => e.name, 'name', 'timeout')));
      expect(
          () => BaseClient(StreamChannelController<dynamic>().local,
              requestTimeout: timeout),
          throwsA(isA<ArgumentError>()
              .having((e) => e.name, 'name', 'requestTimeout')));
      expect(
          () => BaseClient(StreamChannelController<dynamic>().local,
              closeTimeout: timeout),
          throwsA(isA<ArgumentError>()
              .having((e) => e.name, 'name', 'closeTimeout')));
      expect(
          () => FiroElectrumClient(
              StreamChannelController<dynamic>().local, 'host', 1, false, null,
              closeTimeout: timeout),
          throwsA(isA<ArgumentError>()
              .having((e) => e.name, 'name', 'closeTimeout')));
    }
    expect(requests, isEmpty);
    expect(client.peer.isClosed, isFalse);
  });

  test('a batch on a client closed by a deadline fails without stray errors',
      () async {
    await expectLater(
        client.request('silent'), throwsA(isA<TimeoutException>()));
    final futures = <Future<dynamic>>[];
    client.peer.withBatch(() {
      futures.add(client.request('first'));
      futures.add(client.request('second'));
    });
    await expectLater(Future.wait(futures), throwsStateError);
  });

  test('batch helpers on a closed client report the closure once', () async {
    final electrum = ElectrumClient(
        FakeServer().channel, 'host', 1, false, null,
        requestTimeout: const Duration(milliseconds: 100));
    await electrum.close();
    // Any unhandled error from the batch members would fail this test.
    await expectLater(
        electrum.broadcastTransactions(['00', '01', '02']), throwsStateError);
  });

  test('a broadcast can be given longer than the client deadline', () async {
    final remote = FakeServer();
    final electrum = ElectrumClient(remote.channel, 'host', 1, false, null,
        requestTimeout: const Duration(milliseconds: 50));
    addTearDown(electrum.close);
    remote.respond = (request) => Timer(
        const Duration(milliseconds: 150), () => remote.reply(request, 'txid'));
    const timeout = Duration(seconds: 2);
    expect(await electrum.broadcastTransaction('00', timeout: timeout), 'txid');
    expect(await electrum.broadcastTransactions(['01', '02'], timeout: timeout),
        ['txid', 'txid']);
  });

  test('an invalid broadcast timeout sends nothing', () async {
    final remote = FakeServer();
    final electrum = ElectrumClient(remote.channel, 'host', 1, false, null);
    addTearDown(electrum.close);
    await expectLater(
        electrum.broadcastTransactions(['00'], timeout: Duration.zero),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'timeout')));
    // A batch whose members all failed before being sent is not sent empty.
    electrum.peer.withBatch(() {});
    await Future<void>.delayed(Duration.zero);
    expect(remote.messages, isEmpty);
  });

  test('a sink that fails ends the client with its error', () async {
    final input = StreamController<dynamic>();
    final failing = Completer<void>();
    final watched = BaseClient(StreamChannel<dynamic>(
        input.stream, NullStreamSink<dynamic>(done: failing.future)));
    final pending = expectLater(watched.request('pending'), throwsStateError);
    failing.completeError(const SocketException('broken'));
    await expectLater(watched.done, throwsA(isA<SocketException>()));
    await pending;
    await input.close();
  });

  test('remote EOF closes the supplied sink', () async {
    final input = StreamController<dynamic>();
    final sink = _RecordingSink();
    final eofClient = BaseClient(StreamChannel<dynamic>(input.stream, sink));
    await input.close();
    await eofClient.done;
    await sink.closed.future.timeout(const Duration(seconds: 1));
  });

  test('close lets queued output drain, then aborts a stuck transport',
      () async {
    final input = StreamController<dynamic>();
    var aborts = 0;
    final transport = TransportChannel(
        StreamChannel<dynamic>(input.stream, _stuck()), () => aborts++,
        done: Completer<void>().future);
    final stuck =
        BaseClient(transport, closeTimeout: const Duration(milliseconds: 50));
    await stuck.close();
    expect(aborts, 0);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(aborts, 1);
    await input.close();
  });

  test('a transport released by a graceful close is not aborted', () async {
    final input = StreamController<dynamic>();
    final released = Completer<void>();
    var aborts = 0;
    final transport = TransportChannel(
        StreamChannel<dynamic>(input.stream, _stuck()), () => aborts++,
        done: released.future);
    final draining =
        BaseClient(transport, closeTimeout: const Duration(milliseconds: 50));
    await draining.close();
    released.complete();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(aborts, 0);
    await input.close();
  });

  test('an abort that fails after a graceful close is not reported', () async {
    final input = StreamController<dynamic>();
    var aborts = 0;
    final transport =
        TransportChannel(StreamChannel<dynamic>(input.stream, _stuck()), () {
      aborts++;
      throw StateError('already released');
    }, done: Completer<void>().future);
    final client =
        BaseClient(transport, closeTimeout: const Duration(milliseconds: 50));
    await client.close();
    await client.done;
    // An uncaught error from the drain bound would fail this test.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(aborts, 1);
    await input.close();
  });

  test('a close that fails releases the transport at once', () async {
    final input = StreamController<dynamic>();
    var aborts = 0;
    final transport = TransportChannel(
        StreamChannel<dynamic>(input.stream, _UnclosableSink()), () => aborts++,
        done: Completer<void>().future);
    final client =
        BaseClient(transport, closeTimeout: const Duration(seconds: 10));
    await client.close();
    // Queued output cannot drain through a sink that cannot close.
    expect(aborts, 1);
    await expectLater(client.done, throwsStateError);
    await input.close();
  });

  test('a request deadline aborts the transport at once', () async {
    final input = StreamController<dynamic>();
    var aborts = 0;
    final transport = TransportChannel(
        StreamChannel<dynamic>(input.stream, _stuck()), () => aborts++,
        done: Completer<void>().future);
    final timed =
        BaseClient(transport, requestTimeout: const Duration(milliseconds: 30));
    await expectLater(
        timed.request('silent'), throwsA(isA<TimeoutException>()));
    expect(aborts, 1);
    await input.close();
  });

  test('close releases requests even when the supplied sink never closes',
      () async {
    final input = StreamController<dynamic>();
    final stuck = BaseClient(StreamChannel<dynamic>(input.stream, _stuck()));
    final pending = expectLater(
        stuck.request('silent'),
        throwsA(isStateError.having((e) => e.message, 'message',
            'Electrum client closed with pending request "silent"')));
    await stuck.close().timeout(const Duration(seconds: 1));
    await pending;
    await stuck.done;
    await stuck.close();
    await input.close();
  });
}

/// A sink that rejects close, as a socket's sink does while a stream is
/// being added to it.
class _UnclosableSink extends NullStreamSink<dynamic> {
  @override
  Future<void> close() => throw StateError('StreamSink is bound to a stream');
}

/// Records that it was closed.
class _RecordingSink extends NullStreamSink<dynamic> {
  final Completer<void> closed;

  _RecordingSink() : this._(Completer<void>());
  _RecordingSink._(this.closed) : super(done: closed.future);

  @override
  Future<void> close() {
    if (!closed.isCompleted) closed.complete();
    return super.close();
  }
}

/// Rejects a second close, as some sinks do.
class _OnceSink extends NullStreamSink<dynamic> {
  var _closedOnce = false;

  @override
  Future<void> close() {
    if (_closedOnce) throw StateError('closed twice');
    _closedOnce = true;
    return super.close();
  }
}
