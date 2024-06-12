A Dart-based client for ElectrumX and/or Fulcrum servers based on https://github.com/moontreeapp/electrum_adapter

## Notes

Most ElectrumX servers are quite similar to the Bitcoin Electrum server, but some have additional methods that add extra functionality or similar methods that have slightly different response formats.

## Usage

```dart
import 'package:electrum_adapter/electrum_adapter.dart';

void main() async {
  final client = await ElectrumClient.connect(
    host:'bitcoin.stackwallet.com',
    port: 50002,
  );
  final features = await client.features();
  print(features);
  await client.close();
}
```

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/cypherstack/electrum_adapter/issues
