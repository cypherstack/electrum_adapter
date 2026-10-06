import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:electrum_adapter/electrum_adapter.dart';

import '../mock_electrum_server.dart';

void main() {
  late MockElectrumServer server;
  setUp(() => server = MockElectrumServer());

  group('ElectrumClient', () {
    late RavenElectrumClient client;
    setUp(() => client = RavenElectrumClient(server.channel));

    test('gets server features', () async {
      server.willRespondWith('features', {
        'hosts': {},
        'pruning': null,
        'server_version': 'ElectrumX Ravencoin 1.9',
        'protocol_min': '1.4',
        'protocol_max': '1.9',
        'genesis_hash':
            '000000ecfc5e6324a079542221d00e10362bdc894d56500c414060eea8a3ad5a',
        'hash_function': 'sha256',
        'services': []
      });
      expect((await client.features())['genesis_hash'],
          '000000ecfc5e6324a079542221d00e10362bdc894d56500c414060eea8a3ad5a');
    });
  });

  group('shared methods', () {
    test('gets the server version', () async {
      final client =
          ElectrumClient(server.channel, 'localhost', 50002, true, null);
      server.willRespondWith('server.version', ['ElectrumX 1.19.0', '1.4']);
      expect(await client.serverVersion(), ['ElectrumX 1.19.0', '1.4']);
    });

    Future<Object?> versionRequest(
        Future<void> Function(ElectrumClient) call) async {
      final channel = StreamChannelController<dynamic>();
      final client =
          ElectrumClient(channel.local, 'localhost', 50002, true, null);
      final request = channel.foreign.stream.first;
      final done = call(client);
      final sent = await request as Map<String, dynamic>;
      channel.foreign.sink.add({
        'jsonrpc': '2.0',
        'id': sent['id'],
        'result': ['ElectrumX 1.19.0', '1.4'],
      });
      await done;
      return sent['params'];
    }

    test('sends no parameters by default', () async {
      expect(await versionRequest((c) => c.serverVersion()), isNull);
    });

    Future<Object?> ravenVersionRequest(
        Future<void> Function(RavenElectrumClient) call) async {
      final channel = StreamChannelController<dynamic>();
      final client = RavenElectrumClient(channel.local);
      final request = channel.foreign.stream.first;
      final done = call(client);
      final sent = await request as Map<String, dynamic>;
      channel.foreign.sink.add({
        'jsonrpc': '2.0',
        'id': sent['id'],
        'result': ['ElectrumX Ravencoin 1.9.3', '1.9'],
      });
      await done;
      return sent['params'];
    }

    test('RavenElectrumClient asks for protocol 1.4 to 1.10 by default',
        () async {
      expect(await ravenVersionRequest((c) => c.serverVersion()), [
        'RavenElectrumClient',
        ['1.4', '1.10']
      ]);
    });

    test('RavenElectrumClient can ask for one protocol version', () async {
      expect(
          await ravenVersionRequest(
              (c) => c.serverVersion(minProtocolVersion: null)),
          ['RavenElectrumClient', '1.10']);
      expect(
          await ravenVersionRequest(
              (c) => c.serverVersion(protocolVersion: '1.4')),
          ['RavenElectrumClient', '1.4']);
    });

    test('sends the client name and protocol version', () async {
      expect(
          await versionRequest((c) =>
              c.serverVersion(clientName: 'app/1.0', protocolVersion: '1.4')),
          ['app/1.0', '1.4']);
    });
  });
}
