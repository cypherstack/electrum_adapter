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

## Deadlines and connection lifecycle

`connectionTimeout` must be positive. It defaults to five seconds for a direct
connection and to 30 seconds through a proxy (`proxyConnectionTimeout`), and it
covers the whole setup: TCP, SOCKS negotiation when using a proxy, and TLS. An
expired attempt throws a `ConnectionTimeoutException`, which is both a
`TimeoutException` and a `SocketException`, and releases its socket even if the
server never hangs up.

Channels from `connect()` are `TransportChannel`s, which can be aborted and
count the bytes they receive. To keep that for a wrapped or transformed
channel, pass it through the original's `withChannel`:
`BaseClient(transport.withChannel(transport.transformStream(logger)))`. Each
line from the server is one JSON message: lines that are not JSON are skipped,
and invalid UTF-8 is replaced; each line is decoded as it arrives, so a large
reply is never also held as one string. Closing a channel's sink ends its
stream at once, sends queued output and shuts down sending; the connection
closes once the server closes its side, or at once with `abort()`. A channel's
stream can be listened to once.

Limits: direct plaintext connections do not go through `IOOverrides`.

`aliveTimerDuration` is retained for source compatibility but has no effect.

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/cypherstack/electrum_adapter/issues
