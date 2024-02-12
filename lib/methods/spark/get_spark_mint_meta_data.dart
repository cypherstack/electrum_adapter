import '../../electrum_adapter.dart';

/// Takes a list of [sparkCoinHashes] and returns the set id and block height
/// for each coin.
///
/// arg:
/// {
///   "coinHashes": [
///       "b476ed2b374bb081ea51d111f68f0136252521214e213d119b8dc67b92f5a390",
///       "b476ed2b374bb081ea51d111f68f0136252521214e213d119b8dc67b92f5a390",
///   ]
/// }
extension GetSparkMintMetaDataMethod on FiroElectrumClient {
  Future<List<dynamic>> getSparkMintMetaData({
    required List<String> sparkCoinHashes,
  }) async {
    return await request(
      'spark.getsparkmintmetadata',
      [
        {
          "coinHashes": sparkCoinHashes,
        },
      ],
    );
  }
}
