import '../../electrum_adapter.dart';

/// Takes [startNumber], if it is 0, we get the full set,
/// otherwise the used tags after that number
extension GetUsedCoinsTagsMethod on FiroElectrumClient {
  Future<Map<String, dynamic>> getUsedCoinsTags({
    required int startNumber,
  }) async {
    return await request(
      'spark.getusedcoinstags',
      [
        "$startNumber",
      ],
    );
  }
}

/// Returns the whole Spark anonymity set for denomination in the groupId.
///
/// Takes [coinGroupId] and [startBlockHash], if the last is empty it returns
/// the full set, otherwise returns mint after that block, we need to call this
/// to keep our anonymity set data up to date.
///
/// Returns blockHash (last block hash),
/// setHash (hash of current set)
/// and coins (the list of pairs serialized coin and tx hash)
extension GetSparkAnonymitySet on FiroElectrumClient {
  Future<Map<String, dynamic>> getSparkAnonymitySet({
    String coinGroupId = "1",
    String startBlockHash = "",
  }) async {
    return await request(
      'spark.getsparkanonymityset',
      [
        coinGroupId,
        startBlockHash,
      ],
    );
  }
}

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

