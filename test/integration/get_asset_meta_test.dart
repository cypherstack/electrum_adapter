@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:electrum_adapter/electrum_adapter.dart';

void main() {
  group('electrum_client', () {
    late RavenElectrumClient client;
    setUp(() async {
      // testnet.rvn.rocks's certificate has expired.
      client = await RavenElectrumClient.connect('testnet.rvn.rocks',
          acceptUnverified: true);
    });
    tearDown(() => client.close());

    test('get our asset meta (original owner)', () async {
      var meta = await client.getMeta('ZVZZT!');
      expect(
          meta,
          AssetMeta(
              symbol: 'ZVZZT!',
              satsInCirculation: 100000000,
              divisions: 0,
              reissuable: false,
              hasIpfs: false,
              source: TxSource(
                  txHash:
                      'a9cfdad9cd3d1a8084578b68e70aac8bfea157ef68dc2007161a1192ad97ec18',
                  txPos: 2,
                  height: 59021)));
    });

    test('get our asset transaction (original owner)', () async {
      var meta = await client.getMeta('ZVZZT!');
      var tx = await client.getTransaction(meta!.source.txHash);
      expect(tx.txid, meta.source.txHash);
    },
        skip: 'testnet.rvn.rocks answers blockchain.transaction.get with '
            '"server busy - request timed out".');
  });

  test('get our asset meta and transaction (original owner) MAIN', () async {
    var client = await RavenElectrumClient.connect('electrum1.rvn.rocks');
    var meta = await client.getMeta('PORKYPUNX/AIRDROP2');
    expect(meta != null, true);
    var tx = await client.getTransaction(meta!.source.txHash);
    expect(tx.txid, meta.source.txHash);
  },
      skip: 'No reachable mainnet server serves blockchain.asset.*: '
          'electrum1.rvn.rocks refuses connections and electrum1.cipig.net '
          'lacks the asset methods.');
}
