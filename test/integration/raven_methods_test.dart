@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:electrum_adapter/electrum_adapter.dart';

void main() {
  group('assets', () {
    late RavenElectrumClient client;
    setUp(() async {
      // testnet.rvn.rocks's certificate has expired.
      client = await RavenElectrumClient.connect('testnet.rvn.rocks',
          port: 50002, acceptUnverified: true);
    });
    tearDown(() => client.close());

    test('negotiates 1.9 with an older server', () async {
      // testnet.rvn.rocks runs ElectrumX Ravencoin 1.9.3, which stops at 1.9.
      expect(client.protocolVersion, '1.9');
    });

    test('getMeta', () async {
      var results = await client.getMeta('MOONTREE');
      expect(
        results,
        AssetMeta(
            symbol: 'MOONTREE',
            satsInCirculation: 100000400000000,
            divisions: 0,
            reissuable: true,
            hasIpfs: true,
            source: TxSource(
                txHash:
                    'f84c85076c19d1430441de474bd31cf439b07e1988ec372fd4da748d69d2676b',
                txPos: 3,
                height: 1190766)),
      );
    });
  });

  group('fees', () {
    late RavenElectrumClient client;
    setUp(() async {
      // The testnet daemon no longer answers fee requests, so ask a mainnet
      // server, which speaks protocol 1.4 to 1.7.
      client = await RavenElectrumClient.connect('electrum1.cipig.net',
          port: 20051, protocolVersion: '1.4');
    });
    tearDown(() => client.close());

    test('getRelayFee', () async {
      var results = await client.getRelayFee();
      expect(results, 0.01);
    });
    test('getEstimateFee', () async {
      var results = await client.getFeeEstimate(100);
      expect(results, greaterThanOrEqualTo(0.01));
    });
  });
}
