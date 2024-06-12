import 'package:electrum_adapter/electrum_adapter.dart';

void main() async {
  final client = await ElectrumClient.connect(
    host:'bitcoin.stackwallet.com',
    port: 50002,
  );
  final features = await client.features();
  print(features.runtimeType);
  print(features);
  await client.close();
}
