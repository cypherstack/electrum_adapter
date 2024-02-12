// dart --sound-null-safety test test/integration/get_stats_test.dart --concurrency=1
import 'package:test/test.dart';
import 'package:electrum_adapter/electrum_adapter.dart';

void main() {
  group('electrum_client', () {
    test('get our stats', () async {
      var client = await FiroElectrumClient.connect('testnet.rvn.rocks');
      var stats = await client.getOurStats();
      print(stats);
      expect(stats == null, true);
    });
  });
}
