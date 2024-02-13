import 'package:electrum_adapter/electrum_adapter.dart';

extension SharedMethods on ElectrumClient {
  Future<dynamic> ping() async => await request('server.ping');

  Future<Map<String, dynamic>> features() async =>
      (await request('server.features')) as Map<String, dynamic>;

  Future<String> broadcastTransaction(String rawTx) async => await request(
        'blockchain.transaction.broadcast',
        [rawTx],
      ) as String;

  /// returns transaction hashs as hexadecimal strings in the same order as rawTxs passed in
  Future<List<String>> broadcastTransactions(List<String> rawTxs) async {
    var futures = <Future<String>>[];
    if (rawTxs.isNotEmpty) {
      peer.withBatch(() {
        for (var rawTx in rawTxs) {
          futures.add(broadcastTransaction(rawTx));
        }
      });
    }
    List<String> results = await Future.wait<String>(futures);
    return results;
  }
}
