import 'package:electrum_adapter/client/base_client.dart';
import 'package:electrum_adapter/connect.dart';
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
}
