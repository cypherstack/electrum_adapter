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
