import 'dart:async';
import 'dart:io';

/// Default deadline for a direct connection: TCP and TLS.
const connectionTimeout = Duration(seconds: 5);

/// Default deadline for a connection through a SOCKS5 proxy: TCP to the proxy,
/// SOCKS negotiation, the proxy reaching the server, and TLS. A Tor proxy may
/// first have to build a circuit.
const proxyConnectionTimeout = Duration(seconds: 30);

/// Thrown when an Electrum connection attempt does not finish within its
/// deadline.
///
/// It is a [TimeoutException]. It is also a [SocketException], as the connect
/// timeouts of dart:io are, so handlers written for those still catch it.
class ConnectionTimeoutException extends SocketException
    implements TimeoutException {
  @override
  final Duration duration;

  ConnectionTimeoutException(super.message, this.duration);

  @override
  String toString() => 'ConnectionTimeoutException after $duration: $message';
}

/// The deadline for a connection attempt: [timeout] when given, otherwise the
/// default for a direct or [proxied] connection.
Duration resolveConnectionTimeout(Duration? timeout, {required bool proxied}) {
  final resolved =
      timeout ?? (proxied ? proxyConnectionTimeout : connectionTimeout);
  checkPositive(resolved, 'connectionTimeout');
  return resolved;
}

/// Throws an [ArgumentError] naming [name] unless [duration] is positive.
void checkPositive(Duration duration, String name) {
  if (duration <= Duration.zero) {
    throw ArgumentError.value(duration, name, 'Must be positive');
  }
}
