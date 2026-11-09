## 5.0.0

- Add an optional `connectionDeadline` for the whole connection, direct or through a SOCKS5 proxy: TCP, SOCKS negotiation and TLS. There is no overall deadline by default. An expired or failed attempt releases its socket, even when the server never hangs up.
- Preserve the legacy `connectionTimeout`: direct TCP only, defaulting to 5 seconds and ignored through a proxy. Proxy setup retains 30 seconds per phase (TCP, greeting, CONNECT and TLS), now configurable with `proxyHandshakeTimeout`. Phase limits still apply alongside an explicit total deadline. Expired setup limits throw `ConnectionTimeoutException`, which is a `TimeoutException` and also, like the dart:io connect timeouts thrown before, a `SocketException`.
- Include `server.version` in an explicitly supplied `connectionDeadline` for Firo and Raven helpers; otherwise it uses `requestTimeout`, with no deadline by default. Close the client when negotiation fails. Raven's helper now also accepts `useSSL` and `proxyInfo`, and both `serverVersion` methods accept a `timeout`.
- Requests can have a deadline: set `requestTimeout` on a client or connect helper, or use `requestWithTimeout()` for one call. There is none by default. An expired request fails with a `TimeoutException`; if nothing at all arrived from the server during the deadline of the oldest pending request, the client closes and fails every pending request, including batch members. A newer request's deadline never closes the client while an older request is pending. Requests are not retried. On a client with a deadline, Firo calls that can return a whole anonymity set or serial list use at least 2 minutes (`firoSetRequestTimeout`); they accept a `timeout` of their own, as do `broadcastTransaction` and `broadcastTransactions`.
- **Behavior change:** `close()` fails pending requests at once and returns without waiting for queued output or for the connection to close. Output queued before it is still sent, for up to `closeTimeout` (5 seconds by default, accepted by every client and connect helper), before the connection is aborted. `client.done` completes when the client closes, not when the connection does; the `done` of a channel from `connect()` completes when the connection is released. Pending requests on a failed connection still fail with a `StateError`, whose message names the request and the failure; `client.done` reports the error.
- **Behavior change:** helpers with a deadline of their own (`serverVersion`, `broadcastTransaction(s)`, the Firo set calls) call `requestWithTimeout()` directly, which `request()` also uses. Override `requestWithTimeout()` to intercept every request.
- **Behavior change:** propagate initial subscription failures, and end subscription streams when the client closes; when it fails, the streams first receive its error, which is uncaught without an `onError` handler. Remove cancelled listeners. A notification read together with a subscription's first result is delivered after it. A scripthash notification with a null status reaches subscription streams as null instead of an empty set.
- Batch helpers on a closed client fail with the closure instead of leaving one unhandled error per request, and an empty batch is never sent.
- `connect()` decodes each line from the server as one JSON message while it arrives, without holding it as a string: a malformed line is skipped without affecting the next, and invalid UTF-8 is replaced. A server that closes in the middle of a message now ends the client.
- Add an optional `maxMessageBytes` to `connect()` and the connect helpers: detecting a longer line from the server aborts the transport, discards queued output, and reports `MessageTooLargeException`. No later messages are delivered, and pending writes fail with the same error. Unfinished and malformed lines count toward the limit too. Pausing or cancelling during decoding does not delay the abort; stream errors are suppressed after cancellation or closing the sink. There is no limit by default.
- **Breaking:** remove `client/json_newline_transformer.dart` (`jsonNewlineDocument`, `ContinuousJsonDecoder`), which `connect()` no longer uses.
- `connect()` returns a `TransportChannel`; `withChannel` keeps its `abort`, `done` and received byte count for a wrapped channel. Closing its sink ends its stream at once, sends queued output and then shuts down sending, as closing a dart:io `Socket` does; the connection closes when the server closes its side, or at once with `abort()`. `ConnectionTimeoutException` names the host and port.
- **Behavior change:** the adapter negotiates SOCKS5 itself, so a proxied channel's stream can be listened to once, like a direct one; proxy failures keep socks_socket's exception types. Direct plaintext connections no longer go through `IOOverrides`.
- Expose `client.done` and document that the retained `aliveTimerDuration` parameter has no effect. Connection and request deadlines must be positive.

## 4.1.0

- Add `onBadCertificate` to `connect()` and to the `ElectrumClient`, `FiroElectrumClient` and `RavenElectrumClient` connect helpers. It is called with a certificate that fails verification, on a direct TLS connection and through a SOCKS5 proxy, and accepts it by returning true, so a caller can pin a server's certificate. `acceptUnverified: true` without a `securityContext` still accepts every certificate on a direct connection without calling it.
- Require `socks_socket` ^2.1.0, which passes `onBadCertificate` through to the TLS upgrade after the SOCKS5 CONNECT.

## 4.0.1

- Require `socks_socket` ^2.0.0; proxied connections use its managed streams and TLS.

## 4.0.0

- **Breaking:** `acceptUnverified` defaults to `false` in `connect()` and the connect helpers, so a direct TLS connection verifies the server's certificate. Pass `acceptUnverified: true`, or a `securityContext` that trusts the certificate, to reach a server with a self-signed or expired one.
- **Breaking:** `serverVersion()` on `ElectrumClient` returns the reply as a `List<String>` (software version, protocol version) instead of a `Map`, a cast that always threw. It also takes optional `clientName` and `protocolVersion`.
- Add `securityContext` to `connect()` and to the `ElectrumClient`, `FiroElectrumClient` and `RavenElectrumClient` connect helpers, to trust a server's self-signed certificate. It applies to direct TLS and to TLS through a SOCKS5 proxy, and is enforced even when `acceptUnverified` is true. On macOS and iOS the certificate needs the serverAuth extended key usage.
- Require `socks_socket` ^1.4.0, so a proxied request still reaches a server that has closed its side, and Dart 3.5, which it needs.
- `FiroElectrumClient.connect()` negotiates protocol 1.4 by default and sends its client name and protocol version; it no longer ignores `protocolVersion`.
- `RavenElectrumClient.connect()` and Raven's `serverVersion()` ask for any protocol version from 1.4 to 1.10, set by the new `minProtocolVersion` and the existing `protocolVersion`. That reaches current ElectrumX Ravencoin, which rejects 1.9, and older releases, which stop at 1.9. `connect()` keeps the version the server agreed to in `protocolVersion`.
- Fix closing a client leaving its connection through a SOCKS5 proxy open.
- Fix `BaseClient.handleError` throwing on errors that are not strings.
- Fix Raven `getMeta` and `getTransaction` throwing on real server replies. `getMeta` throws a `FormatException` for an asset flag other than 0 or 1.
- Fix OP_RETURN memos: `getMemo` returned a memo of four bytes or fewer as a decimal number and threw on a bare OP_RETURN, and `TxScriptPubKey.memo` put the push length before the memo. Both now decode the script hex with the new `memoFromScript`, which also reads the one-byte pushes `OP_1NEGATE` and `OP_1` to `OP_16`; `parseAsmForMemo` is deprecated.
- Tag the tests that need live servers `integration` and skip them in a plain `dart test`; run them with `dart test -P integration`.

## 3.0.2

- Moved `tor_plugin_ffi` to dev deps.

## 3.0.1

- Moved `lints` to dev deps.

## 3.0.0

- Rename package from ravencoin_electrum to electrum_adapter.
- Generalize package to support multiple coins.
- Fix and demonstrate Tor support.

## 2.0.0

- Rename package from ravencoin_electrum_client to ravencoin_electrum

## 1.2.1

- Fix type returned by subscribe

## 1.2.0
- Add getAssetBalance(s)
- Add getAssetUnspent(s)
- Add getOurStats (experimental)

## 1.1.0
- Add subscribeAsset, subscribeScripthash

## 1.0.0
- Initial version.
