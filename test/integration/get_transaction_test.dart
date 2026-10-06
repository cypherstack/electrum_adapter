@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:electrum_adapter/electrum_adapter.dart';

void main() {
  test('getTransaction and parse', () async {
    // The testnet daemon no longer answers transaction requests, so read a
    // mainnet coinbase, which carries the same witness commitment memo.
    var client =
        RavenElectrumClient(await connect('electrum1.cipig.net', port: 20051));
    await client.serverVersion(protocolVersion: '1.4');
    var tx = await client.getTransaction(
        '5bd67190fb59b15e7bfbfffb6e444bef4fab1af3aed674325e612fe3f2486fe6');
    expect(tx.vout[1].memo,
        'aa21a9ede2f61c3f71d1defd3fa999dfa36953755c690689799962b48bebd836974e8cf9');
  });
}
