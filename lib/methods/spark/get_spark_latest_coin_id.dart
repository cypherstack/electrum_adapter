import '../../electrum_adapter.dart';

/// Returns the latest Spark set id
///
/// ex: 1
extension GetSparkLatestCoinId on FiroElectrumClient {
  Future<int> getSparkLatestCoinId() async {
    return await request(
      'spark.getsparklatestcoinid',
    );
  }
}
