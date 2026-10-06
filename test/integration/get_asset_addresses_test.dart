@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:electrum_adapter/electrum_adapter.dart';

void main() {
  group('electrum_client', () {
    test('get our asset addresses', () async {
      var client =
          await RavenElectrumClient.connect('electrum1.rvn.rocks'); // mainnet
      addTearDown(client.close);
      var addresses = await client.getAddresses('CATE');
      expect(addresses!.owner, '');
      addresses = await client.getAddresses('CATE!');
      // will fail if CATE! changes ownership...
      expect(addresses!.owner, 'RWaahojLNr4VCQ8j9hwndqfA1UuzN3tanW');
    },
        skip: 'No reachable server answers '
            'blockchain.asset.list_addresses_by_asset: electrum1.rvn.rocks '
            'refuses connections, electrum1.cipig.net lacks the asset methods '
            'and testnet.rvn.rocks replies "server busy - request timed out".');
  });
}
