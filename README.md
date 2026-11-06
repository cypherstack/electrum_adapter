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
covers the whole setup: TCP, SOCKS negotiation when using a proxy, and TLS.
`FiroElectrumClient.connect()` and `RavenElectrumClient.connect()` also include
the initial `server.version` exchange in that budget. An expired attempt throws
a `ConnectionTimeoutException`, which is both a `TimeoutException` and a
`SocketException`, and releases its socket even if the server never hangs up.
`ElectrumClient.connect()` only establishes the transport and does not send
`server.version`.

All client constructors and connect helpers accept an optional, positive
`requestTimeout`; without one, requests have no deadline. It applies to each
RPC response, including requests in a batch and the initial subscription
response. A server answers a
batch in one reply once every member is done, so batch helpers, which have no
`timeout` of their own, need a `requestTimeout` long enough for the largest
batch. Use a longer timeout for operations that legitimately take longer:

```dart
final client = await ElectrumClient.connect(
  host: 'bitcoin.stackwallet.com',
  port: 50002,
  connectionTimeout: const Duration(seconds: 30),
  requestTimeout: const Duration(seconds: 60),
);
try {
  final result = await client.requestWithTimeout(
    'blockchain.transaction.get',
    parameters: [transactionId, true],
    timeout: const Duration(minutes: 5),
  );
  print(result);
} finally {
  await client.close();
}
```

The existing `request(method, [parameters])` API uses the client's
`requestTimeout`, and `requestWithTimeout()` overrides it for one call. Every request goes through
`requestWithTimeout()`, so a subclass that intercepts requests overrides that
method rather than `request()`. Firo calls that can return a whole anonymity
set or list of serials, such as `getLelantusUsedCoinSerials`, use at least two
minutes on a client with a deadline, and take a `timeout` of their own, as do
`serverVersion`, `broadcastTransaction` and `broadcastTransactions`.

A deadline runs from when the request is sent, so it includes time spent
waiting behind earlier replies on the same connection. When it passes, the
request fails with a `TimeoutException`; its reply, if it still comes, is read
and discarded. If nothing at all arrived from the server during the deadline of
the oldest pending request, the connection is presumed dead: the client closes
and every pending request fails with a `TimeoutException`. While an older
request is pending the server may be busy with it, so the deadline of a newer
request fails only that request. Bytes count as they are received, under TLS
as each record of up to 16 KB is decrypted, so a long response in progress
keeps the connection open. The adapter does not retry requests: a missing
response does not establish whether the server executed the operation.
Requests sent directly through `client.peer` have no deadline; use the client's
request methods inside `peer.withBatch()`, and keep its callback synchronous,
as the deadlines of requests it holds run meanwhile.

`close()` fails pending requests at once. Output already queued, such as a
notification sent just before, is still sent for up to `closeTimeout` (five
seconds by default, accepted by every client and connect helper) before the
connection is aborted. When the connection fails, pending requests fail with a
`StateError` naming their method, and `client.done` reports the error.

Subscriptions report initial failures through the returned Future (`subscribe`)
or stream (`subscribeNonBatch`, including `subscribeHeaders`), also when the
client is already closed. Active streams receive a terminal error on failure
and end when the connection closes, so listen with an `onError` handler.
Closing the client does not wait for paused or unlistened subscription streams.
Cancelling a subscription stream stops local delivery but does not unsubscribe
on the server; use `unsubscribeScripthash` where the server supports it.

Channels from `connect()` are `TransportChannel`s, which a client can abort and
whose received bytes it counts. To keep that for a wrapped or transformed
channel, pass it through the original's `withChannel`:
`BaseClient(transport.withChannel(transport.transformStream(logger)))`. Each
line from the server is one JSON message: lines that are not JSON are skipped,
and invalid UTF-8 is replaced; each line is decoded as it arrives, so a large
reply is never also held as one string. `maxMessageBytes`, on `connect()` and
the connect helpers, limits the size of one message: a longer one fails the
connection with a `MessageTooLargeException`. There is no limit by default.
Closing a channel's sink ends its stream at once, sends queued output and
shuts down sending; the connection closes once the server closes its side, or
at once with `abort()`. A channel's stream can be listened to once.

Limits: a deadline that passes while the app is suspended may close the client;
create a new client then. Data that the operating system or a proxy such as Tor
has buffered while sending is invisible to the client, so give a large
broadcast on a slow link a longer `timeout`. A server that stops reading but
keeps sending keeps the connection open: requests fail at their deadlines, and
unsent output stays queued until the client is closed. Direct plaintext
connections do not go through `IOOverrides`.

`aliveTimerDuration` is retained for source compatibility but has no effect.
These deadlines bound pending operations; they do not ping an idle connection.
To notice a dead server between requests, set a `requestTimeout` and call
`ping()` periodically.

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/cypherstack/electrum_adapter/issues
