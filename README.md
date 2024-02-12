A Dart 3 client for Firo ElectrumX servers

## Notes

The Firo ElectrumX server is quite similar to the Bitcion Electrum server, but has additional methods for retrieving the used coin serials and anonymity sets.

## Usage

```dart
import 'package:electrum_adapter/electrum_adapter.dart';

void main() async {
  var client =
      await FiroElectrumClient.connect('testnet.rvn.rocks', port: 50002);
  var features = await client.features();
  print(features);
  await client.close();
}
```

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/cypherstack/electrum_adapter/issues
