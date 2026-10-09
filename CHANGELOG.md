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
