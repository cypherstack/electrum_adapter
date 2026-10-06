@Tags(['integration'])
library;

import 'package:test/test.dart';

import 'package:electrum_adapter/electrum_adapter.dart';

void main() {
  group('electrum_client', () {
    late RavenElectrumClient client;
    setUp(() async {
      // Our mainnet server:
      // var channel = await connect('143.198.142.78', port: 50002);

      // Our testnet server:
      // var channel = await connect('143.198.142.78', port: 50012);

      // Raven Foundation testnet server:
      // var channel = await connect('168.119.100.140', port: 50012);

      // HyperPeek's testnet server:
      // testnet.rvn.rocks's certificate has expired.
      var channel = await connect('testnet.rvn.rocks',
          port: 50002, acceptUnverified: true);
      //var channel = await connect('mainnet.rvn.rocks', port: 50002);

      client = RavenElectrumClient(channel);
    });

    test('get unspent', () async {
      var scripthash =
          'b3bbdf50410b85299f914d2c573a7cadc2133d8e6cc088dc400dd174937f86e1';
      var utxos = await client.getUnspent(scripthash);
      expect(utxos, [
        ScripthashUnspent(
            scripthash: scripthash,
            txHash:
                '84ab4db04a5d32fc81025db3944e6534c4c201fcc93749da6d1e5ecf98355533',
            txPos: 1,
            height: 765913,
            value: 5000087912000)
      ]);
    });

    test('withBatch', () async {
      var scripthash =
          '93bfc0b3df3f7e2a033ca8d70582d5cf4adf6cc0587e10ef224a78955b636923';

      var futures = <Future>[];
      client.peer.withBatch(() {
        futures.add(client.getHistory(scripthash));
        futures.add(client.features());
      });
      var results = await Future.wait(futures);

      var features = results[1];
      expect(features['genesis_hash'],
          '000000ecfc5e6324a079542221d00e10362bdc894d56500c414060eea8a3ad5a');

      var history = results[0];
      expect(history, [
        ScripthashHistory(
            txHash:
                '56fcc747b8067133a3dc8907565fa1b31e452c98b3f200687cb836f98c3c46ae',
            height: 747308),
        ScripthashHistory(
            txHash:
                '2dada22848277e6a23b49c1e63d47b661f94819b2001e2789a5fd947b51907d5',
            height: 769767)
      ]);
    });

    test('subscribes to scripthash', () async {
      var scripthash =
          '93bfc0b3df3f7e2a033ca8d70582d5cf4adf6cc0587e10ef224a78955b636923';
      var stream = await client.subscribeScripthash(scripthash);
      var result = await stream.first;
      expect(result,
          '615dd2dec158d531d2875cee60c37e9e72f264d221a267a9ab512e0741ba4eb4');
    });
  });

  group('electrum_client on mainnet', () {
    late RavenElectrumClient client;
    setUp(() async {
      // The testnet daemon no longer answers transaction requests, so read a
      // mainnet coinbase, which carries the same witness commitment memo.
      client = await RavenElectrumClient.connect('electrum1.cipig.net',
          port: 20051, protocolVersion: '1.4');
    });
    tearDown(() => client.close());

    test('get transaction', () async {
      var results = await client.getTransaction(
          '5bd67190fb59b15e7bfbfffb6e444bef4fab1af3aed674325e612fe3f2486fe6');
      expect(results.toString(),
          'Transaction(txid: 5bd67190fb59b15e7bfbfffb6e444bef4fab1af3aed674325e612fe3f2486fe6, hash: a3896d4c7ce3b2224ada5a852259523a83c5e02cb8d0eda5c5a463d65496b2a6, blockhash: 0000000000007d69bf8de4ad59368871dfc340bebdb2dd2ff81689c3459e2e3a, blocktime: 1726449055, confirmations: ${results.confirmations}, height: 3500000, hex: 010000000001010000000000000000000000000000000000000000000000000000000000000000ffffffff2e03e06735049f85e7660406b6c72f000000001b324d696e6572732068747470733a2f2f326d696e6572732e636f6dffffffff02004429353a0000001976a91459d584c2da3735f24af4ed3eb8e2abeb63fbffd688ac0000000000000000266a24aa21a9ede2f61c3f71d1defd3fa999dfa36953755c690689799962b48bebd836974e8cf90120000000000000000000000000000000000000000000000000000000000000000000000000, locktime: 0, size: 214, vsize: 187, time: 1726449055, version: 1, memo: null, vin: [TxVin(03e06735049f85e7660406b6c72f000000001b324d696e6572732068747470733a2f2f326d696e6572732e636f6d, 4294967295, null, null, null)], vout: [TxVout(2500.0, 0, 250000000000, TxScriptPubKey(asm: OP_DUP OP_HASH160 59d584c2da3735f24af4ed3eb8e2abeb63fbffd6 OP_EQUALVERIFY OP_CHECKSIG, hex: 76a91459d584c2da3735f24af4ed3eb8e2abeb63fbffd688ac, type: pubkeyhash, reqSigs: 1, addresses: [RHUC17zAVjNqXDtkqwLPRvQ2XgoRZsXeeG], asset: null, amount: 0.0, units: null, reissuable: null, assetMemo: null, ipfsHash: null)), TxVout(0.0, 1, 0, TxScriptPubKey(asm: OP_RETURN aa21a9ede2f61c3f71d1defd3fa999dfa36953755c690689799962b48bebd836974e8cf9, hex: 6a24aa21a9ede2f61c3f71d1defd3fa999dfa36953755c690689799962b48bebd836974e8cf9, type: nulldata, reqSigs: null, addresses: null, asset: null, amount: 0.0, units: null, reissuable: null, assetMemo: null, ipfsHash: null))])');
    });
    test('get memo', () async {
      var results = await client.getMemo(
          '5bd67190fb59b15e7bfbfffb6e444bef4fab1af3aed674325e612fe3f2486fe6');
      expect(results.toString(),
          'aa21a9ede2f61c3f71d1defd3fa999dfa36953755c690689799962b48bebd836974e8cf9');
    });
  });
}
