import '../../electrum_adapter.dart';

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
