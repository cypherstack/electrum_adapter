import 'dart:async';

import 'package:electrum_adapter/electrum_adapter.dart';
import 'package:electrum_adapter/methods/specific/firo.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/fake_server.dart';

void main() {
  late FakeServer server;
  late FiroElectrumClient client;

  setUp(() {
    server = FakeServer();
    client = FiroElectrumClient(server.channel, 'host', 1, false, null,
        requestTimeout: const Duration(milliseconds: 100));
  });
  tearDown(() => client.close());

  void reply(Object? result) => server.reply(server.requests.last, result);

  test('whole-set calls outlast a short client deadline by default', () async {
    final serials = client.getLelantusUsedCoinSerials(startNumber: 0);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(client.peer.isClosed, isFalse);
    reply({'serials': <String>[]});
    expect(await serials, {'serials': <String>[]});
  });

  test('whole-set calls accept a deadline of their own', () async {
    await expectLater(
        client.getUsedCoinsTags(
            startNumber: 0, timeout: const Duration(milliseconds: 30)),
        throwsA(isA<TimeoutException>().having(
            (e) => e.duration, 'duration', const Duration(milliseconds: 30))));
    expect(client.peer.isClosed, isTrue);
  });

  test('whole-set calls use the longer of the client deadline and two minutes',
      () async {
    Future<List<Duration>> deadlines(Duration requestTimeout) async {
      final recording = _Recording(requestTimeout);
      addTearDown(recording.close);
      recording.getSparkAnonymitySet().ignore();
      recording.getUsedCoinsTags(startNumber: 0).ignore();
      recording
          .getUsedCoinsTags(startNumber: 0, timeout: const Duration(seconds: 7))
          .ignore();
      return recording.deadlines;
    }

    expect(await deadlines(const Duration(seconds: 60)), [
      firoSetRequestTimeout,
      firoSetRequestTimeout,
      const Duration(seconds: 7)
    ]);
    expect(await deadlines(const Duration(minutes: 3)), [
      const Duration(minutes: 3),
      const Duration(minutes: 3),
      const Duration(seconds: 7)
    ]);
  });
}

/// Records each request's deadline, as a subclass that intercepts requests
/// does.
class _Recording extends FiroElectrumClient {
  final deadlines = <Duration>[];

  _Recording(Duration requestTimeout)
      : super(StreamChannelController<dynamic>().local, 'host', 1, false, null,
            requestTimeout: requestTimeout);

  @override
  Future<dynamic> requestWithTimeout(String method,
      {dynamic parameters, required Duration timeout}) {
    deadlines.add(timeout);
    return super
        .requestWithTimeout(method, parameters: parameters, timeout: timeout);
  }
}
