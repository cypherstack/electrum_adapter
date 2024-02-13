import 'package:electrum_adapter/client/base_client.dart';
import 'package:electrum_adapter/electrum_adapter.dart';
import 'package:electrum_adapter/methods/specific/firo.dart';
import 'package:test/test.dart';

void main() {
  group('BaseClient', () {
    test('connects', () async {
      var channel = await connect('firo.stackwallet.com');
      var client = BaseClient(channel);
      var response = await client.request('server.features');
      expect(response['genesis_hash'],
          '4381deb85b1b2c9843c222944b616d997516dcbd6a964e1eaf0def0830695233');
    });
  });

  group('FiroElectrumClient Spark tests', () {
    String sparkCoinHash =
        "b476ed2b374bb081ea51d111f68f0136252521214e213d119b8dc67b92f5a390"; // TODO provide valid example.

    test('get full spark anonymity set', () async {
      var channel = await connect('firo.stackwallet.com');
      var client = FiroElectrumClient(channel);
      var response = await client.getSparkAnonymitySet();

      // Following assertions are true as of 2024/02/12:
      //
      // I assume these can't go lower, but I'm not 100% sure about that.

      expect(response.containsKey("blockHash"), true);
      expect(response["blockHash"].length >= 44, true);

      expect(response.containsKey("setHash"), true);
      expect(response["setHash"].length >= 44, true);

      expect(response.containsKey("coins"), true);
      expect(response["coins"].length >= 4311, true);
      // sparkCoinHash = response["coins"].first;
      // TODO convert this value to format needed for sparkCoinHash.
      // Here's an example of the first coin response of getSparkAnonymitySet:
      // [
      //   AYHB7nstGHQ+gJrx+m9pSeccg7jnPSejMthuY14MKo0UAAAlgKacHdJ+ugNg1VfzpgpQpP5M6YFfdUJUjsK/XlRoBQEAMYtUPVHKZuBZzj2NQFqFxeNKmE4FMzxG5MW/ZRxd2DoBAFqaBH6alW2ipuGBijh53+mWmJt3wSdkIpM1zVC5n39DfCF1cbgnlcgWfnYM5Wh6dqySwN/7GZ2eOl+I6AJ4iOxuP/Bs96BHVAWbxA3DEfKy2ZXME2u+KSVdPfYQYs9NRVS88uFCduT80HN2nSBfiOvc19z3y0uJ3vDF9nY2sIq6F5XFJEoEB3Spuq8zGvBlfELhu9aAn50EbWFJ02C5iu+y5qvNSEXVdyXW7269RQKoZGbW2z9jcUZop8gWuSjXBOFsnnLJ+CH7yoSGGMXjqQAA64nOnF8+jG7MlcR++xtiF1PPpLGp86BoM+Wo4OC2RXABAA==,
      //   8GV8QuG71oCfnQRtYUnTYLmK77Lmq81IRdV3Jdbvbr0=,
      //   AqhkZtbbP2NxRminyBa5KNcE4Wyecsn4IfvKhIYYxeOpAADric6cXz6MbsyVxH77G2IXU8+ksanzoGgz5ajg4LZFcAEA,
      // ]
    });

    int latestCoinId = 0;

    test('get spark latest coin id', () async {
      var channel = await connect('firo.stackwallet.com');
      var client = FiroElectrumClient(channel);
      var response = await client.getSparkLatestCoinId();

      expect(response.runtimeType, int);
      latestCoinId = response;

      expect(response > 0, true);
    });

    /*
    // Enable with params which return less than the full set.
    test('get partial spark anonymity set', () async {
      var channel = await connect('firo.stackwallet.com');
      var client = FiroElectrumClient(channel);
      var response = await client.getSparkAnonymitySet(
          coinGroupId: "$latestCoinId",
          startBlockHash:
              "f87a5f605a102dd879fdd0a675812734259d2966e15accd0e4a8137115812ead");
      // TODO tests.
    });
     */

    // Enable with valid param.
    test('get spark mint meta data', () async {
      var channel = await connect('firo.stackwallet.com');
      var client = FiroElectrumClient(channel);
      var response = await client.getSparkMintMetaData(
        sparkCoinHashes: [
          sparkCoinHash,
        ],
      );
      // TODO tests.
    });

    test('get used coins tags', () async {
      var channel = await connect('firo.stackwallet.com');
      var client = FiroElectrumClient(channel);
      var response = await client.getUsedCoinsTags(startNumber: 0);

      expect(response.containsKey("tags"), true);
      expect(response["tags"].runtimeType.toString().replaceAll("_", "replace"),
          "List<dynamic>"); // It can be returned as <_List<dynamic>>.
      expect(response["tags"].length > 2500,
          true); // TODO verify this number can't go lower.
      expect(response["tags"].first.runtimeType.toString().replaceAll("_", ""),
          "String"); // It can be returned as <_String>.
      expect(response["tags"].first.length >= 44, true);
      // Make sure last two characters are "==".
      expect(
          response["tags"].first.substring(response["tags"].first.length - 2),
          "==");
      // expect(
      //     response["tags"].first ==
      //         "lbezEvX1zqCdscr2KRmO0TtX5LN6MJw5EADVKAW9/2QBAA==",
      //     true); // TODO verify this first used coin tag won't change.
    });
  });

  group('FiroElectrumClient Lelantus tests', () {
    test('get lelantus anonymity set', () async {
      var channel = await connect('firo.stackwallet.com');
      var client = FiroElectrumClient(channel);
      var response = await client.getLelantusAnonymitySet();

      expect(response.containsKey("blockHash"), true);
      expect(response.containsKey("setHash"), true);
      expect(response.containsKey("coins"), true);
      expect((response["coins"].first as List).length, 4);
      expect((response["coins"].first as List)[0].runtimeType, String);
      expect((response["coins"].first as List)[0].length >= 48, true);
      expect((response["coins"].first as List)[1].runtimeType, String);
      expect((response["coins"].first as List)[1].length >= 44, true);
      expect((response["coins"].first as List)[2].runtimeType, int);
      expect((response["coins"].first as List)[2] >= 9997057, true);
      expect((response["coins"].first as List)[3].runtimeType, String);
      expect((response["coins"].first as List)[3].length >= 44, true);
    });

    /*
    test('get lelantus mint data', () async {
      var channel = await connect('firo.stackwallet.com');
      var client = FiroElectrumClient(channel);
      var response = await client.getLelantusMintData(
        mints: [
          "b476ed2b374bb081ea51d111f68f0136252521214e213d119b8dc67b92f5a390",
        ],
      );
      // TODO tests.
    });
     */

    test('get lelantus used coin serials', () async {
      var channel = await connect('firo.stackwallet.com');
      var client = FiroElectrumClient(channel);
      var response = await client.getLelantusUsedCoinSerials(
        startNumber: 0,
      );

      expect(response["serials"].first.runtimeType, String);
      expect(response["serials"].first.length >= 44, true);
    });

    test('get lelantus latest coin id', () async {
      var channel = await connect('firo.stackwallet.com');
      var client = FiroElectrumClient(channel);
      var response = await client.getLatestCoinId();

      expect(response.runtimeType, int);
      expect(response >= 2, true);
    });
  });
}
