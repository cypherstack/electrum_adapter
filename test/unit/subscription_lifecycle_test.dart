import 'dart:async';

import 'package:electrum_adapter/client/subscribing_client.dart';
import 'package:electrum_adapter/electrum_adapter.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';

import 'support/fake_server.dart';

void main() {
  late FakeServer server;
  late SubscribingClient client;
  late List<Map<String, dynamic>> requests;

  void reply(Map<String, dynamic> request, Object? result) =>
      server.reply(request, result);
  void notify(int value) => server.sink.add({
        'jsonrpc': '2.0',
        'method': 'review.lifecycle.subscribe',
        'params': [value],
      });

  setUp(() {
    registerSubscribable('review.lifecycle', 0);
    server = FakeServer();
    requests = server.requests;
    client = SubscribingClient(server.channel,
        requestTimeout: const Duration(milliseconds: 100));
  });
  tearDown(() => client.close());

  test('non-batch subscription exposes initial RPC failure and closes',
      () async {
    server.respond = (request) => server.sink.add({
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {'code': -32601, 'message': 'unsupported subscription'},
        });
    await expectLater(client.subscribeNonBatch<int>('review.lifecycle'),
        emitsInOrder([emitsError(isA<rpc.RpcException>()), emitsDone]));
    expect(client.peer.isClosed, isFalse);
  });

  test('a silent initial subscription emits its timeout and closes', () async {
    await expectLater(client.subscribeNonBatch<int>('review.lifecycle'),
        emitsInOrder([emitsError(isA<TimeoutException>()), emitsDone]));
    expect(client.peer.isClosed, isTrue);
  });

  test('async subscription reports initial failure through its Future',
      () async {
    await expectLater(client.subscribe<int>('review.lifecycle'),
        throwsA(isA<TimeoutException>()));
    await client.close();
  });

  test('client close ends active subscriptions', () async {
    server.respond = (request) => reply(request, 1);
    final stream = await client.subscribe<int>('review.lifecycle');
    final result = expectLater(stream, emitsInOrder([1, emitsDone]));
    await client.close();
    await result;
  });

  test('remote EOF ends active subscriptions', () async {
    server.respond = (request) => reply(request, 1);
    final stream = await client.subscribe<int>('review.lifecycle');
    final result = expectLater(stream, emitsInOrder([1, emitsDone]));
    await server.sink.close();
    await result;
  });

  test('a different RPC timeout errors and closes active subscriptions',
      () async {
    server.respond = (request) {
      if (request['method'].toString().endsWith('.subscribe'))
        reply(request, 1);
    };
    final stream = await client.subscribe<int>('review.lifecycle');
    final result = expectLater(stream,
        emitsInOrder([1, emitsError(isA<TimeoutException>()), emitsDone]));
    await expectLater(
        client.request('silent'), throwsA(isA<TimeoutException>()));
    await result;
  });

  test('transport errors reach subscriptions once and close them', () async {
    server.respond = (request) => reply(request, 1);
    final stream = await client.subscribe<int>('review.lifecycle');
    final error = Exception('reset');
    final result = expectLater(
        stream, emitsInOrder([1, emitsError(same(error)), emitsDone]));
    server.sink.addError(error, StackTrace.current);
    await result;
  });

  test('cancelling one listener preserves another subscription to the same key',
      () async {
    server.respond = (request) => reply(request, 1);
    final first =
        (await client.subscribe<int>('review.lifecycle')).listen((_) {});
    final second = await client.subscribe<int>('review.lifecycle');
    final result = expectLater(second.take(2), emitsInOrder([1, 2, emitsDone]));
    await first.cancel();
    notify(2);
    await result;
    notify(3);
    await Future<void>.delayed(Duration.zero);
    expect(client.peer.isClosed, isFalse);
  });

  test('late initial responses after listener cancellation are harmless',
      () async {
    final subscription =
        client.subscribeNonBatch<int>('review.lifecycle').listen((_) {});
    await subscription.cancel();
    await Future<void>.delayed(Duration.zero);
    reply(requests.single, 1);
    notify(2);
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(client.peer.isClosed, isFalse);
  });

  test('subscriptions on a closed client report the closure, not throw',
      () async {
    await client.close();
    // A synchronous throw here would fail the test.
    final stream = client.subscribeNonBatch<int>('review.lifecycle');
    await expectLater(
        stream, emitsInOrder([emitsError(isStateError), emitsDone]));
    await expectLater(
        client.subscribe<int>('review.lifecycle'), throwsStateError);
  });

  test('a notification read with the first result is delivered after it',
      () async {
    final sameRead = FakeServer(sync: true);
    final ordered = SubscribingClient(sameRead.channel);
    addTearDown(ordered.close);
    sameRead.respond = (request) {
      // The response and a newer notification arrive in one read.
      scheduleMicrotask(() => sameRead.sink
        ..add({'jsonrpc': '2.0', 'id': request['id'], 'result': 1})
        ..add({
          'jsonrpc': '2.0',
          'method': 'review.lifecycle.subscribe',
          'params': [2],
        }));
    };
    final stream = await ordered.subscribe<int>('review.lifecycle');
    await expectLater(stream.take(2), emitsInOrder([1, 2, emitsDone]));
    final nonBatch = ordered.subscribeNonBatch<int>('review.lifecycle');
    await expectLater(nonBatch.take(2), emitsInOrder([1, 2, emitsDone]));
  });

  test('invalid params throw at the call, even on a closed client', () async {
    registerSubscribable('review.keyed', 1);
    await client.close();
    // Before, the closure's failure handler threw instead, uncaught.
    expect(() => client.subscribeNonBatch<int>('review.keyed', []),
        throwsRangeError);
    await Future<void>.delayed(Duration.zero);
  });

  test('a null scripthash status arrives as null, not an error', () async {
    registerSubscribable('review.status', 1);
    server.respond = (request) => reply(request, null);
    final stream = await client.subscribe<String?>('review.status', ['sh']);
    final values = expectLater(stream, emitsInOrder([null, null, 'abc']));
    for (final status in [null, 'abc']) {
      server.sink.add({
        'jsonrpc': '2.0',
        'method': 'review.status.subscribe',
        'params': ['sh', status],
      });
    }
    await values;
  });

  group('scripthash subscriptions in one batch', () {
    late FakeServer remote;
    late ElectrumClient electrum;

    setUp(() {
      remote = FakeServer();
      electrum = ElectrumClient(remote.channel, 'host', 1, false, null,
          requestTimeout: const Duration(milliseconds: 100));
      remote.respond = (request) {
        final scripthash = (request['params'] as List).first;
        if (scripthash != 'silent') remote.reply(request, 'status-$scripthash');
      };
    });
    tearDown(() => electrum.close());

    test('each get their stream', () async {
      final streams = await electrum.subscribeScripthashes(['a', 'b']);
      expect(remote.messages.single, hasLength(2));
      final b = expectLater(streams[1], emitsInOrder(['status-b', 'new']));
      remote.sink.add({
        'jsonrpc': '2.0',
        'method': 'blockchain.scripthash.subscribe',
        'params': ['b', 'new'],
      });
      await b;
      await expectLater(streams[0], emits('status-a'));
    });

    test('an unanswered one fails alone', () async {
      late Future<Stream<String?>> answered, silent;
      electrum.peer.withBatch(() {
        answered = electrum.subscribeScripthash('a');
        silent = electrum.subscribeScripthash('silent');
      });
      await expectLater(await answered, emits('status-a'));
      await expectLater(silent, throwsA(isA<TimeoutException>()));
      expect(electrum.peer.isClosed, isFalse);
    });
  });

  test('close does not wait for unlistened or paused subscriptions', () async {
    server.respond = (request) => reply(request, 1);
    final unlistened = await client.subscribe<int>('review.lifecycle');
    final paused =
        (await client.subscribe<int>('review.lifecycle')).listen((_) {});
    paused.pause();
    await client.close().timeout(const Duration(seconds: 1));
    paused.resume();
    await paused.cancel();
    await expectLater(unlistened, emitsInOrder([1, emitsDone]));
  });
}
