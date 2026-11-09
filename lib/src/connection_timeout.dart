import 'dart:async';
import 'dart:io';

/// Legacy timeout for establishing direct TCP. It does not bound TLS or RPCs.
const connectionTimeout = Duration(seconds: 5);

/// Legacy timeout for each proxy setup phase separately: TCP to the proxy,
/// the SOCKS greeting, CONNECT, and TLS. This is not an overall deadline.
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

/// A setup phase's timeout: [timeout] when given, otherwise the legacy direct
/// TCP or proxy phase timeout. This never supplies an overall deadline.
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
