/// An Electrum client for RavenCoin.
///
/// Connects with https://github.com/Electrum-RVN-SIG/electrumx-ravencoin
library electrum_adapter;

import 'dart:async';
import 'dart:io';

import 'package:electrum_adapter/client/base_client.dart';
import 'package:electrum_adapter/client/subscribing_client.dart';
import 'package:electrum_adapter/connect.dart' as conn;
import 'package:electrum_adapter/methods/shared.dart';
import 'package:electrum_adapter/methods/specific/raven/server/version.dart';
import 'package:electrum_adapter/src/connection_timeout.dart';
import 'package:stream_channel/stream_channel.dart';

export 'connect.dart';
export 'methods/shared.dart';
export 'methods/specific/raven/asset/addresses.dart';
export 'methods/specific/raven/asset/assets.dart';
export 'methods/specific/raven/asset/meta.dart';
export 'methods/specific/raven/scripthash/balance.dart';
export 'methods/specific/raven/scripthash/history.dart';
export 'methods/specific/raven/scripthash/unspent.dart';
export 'methods/specific/raven/server/stats.dart';
export 'methods/specific/raven/server/version.dart';
export 'methods/specific/raven/transaction/fee.dart';
export 'methods/specific/raven/transaction/get.dart';
export 'methods/specific/raven/transaction/memo.dart';
export 'subscriptions/shared.dart';
export 'subscriptions/specific/raven/subscribe_asset.dart';

class Header {
  String hex;
  int height;
  Header(this.hex, this.height);
}

/// Methods on RavenElectrumClient are defined in the `methods` directory.
/// See https://electrumx-ravencoin.readthedocs.io/en/latest/protocol-methods.html
class ElectrumClient extends SubscribingClient {
  ElectrumClient(StreamChannel<dynamic> channel, String host, int port,
      bool useSSL, ({InternetAddress host, int port})? proxyInfo,
      {super.requestTimeout, super.closeTimeout})
      : this.host = host,
        this.port = port,
        this.useSSL = useSSL,
        this.proxyInfo = proxyInfo,
        super(channel);
  late final String host;
  late final int port;
  late final bool useSSL;
  late final ({InternetAddress host, int port})? proxyInfo;

  /// Opens a transport within [connectionTimeout], which defaults as for
  /// [conn.connect]. Later RPCs use [requestTimeout], if given; this helper
  /// does not send server.version itself.
  static Future<ElectrumClient> connect({
    required String host,
    required int port,
    Duration? connectionTimeout,
    Duration? requestTimeout,
    Duration closeTimeout = BaseClient.defaultCloseTimeout,
    Duration aliveTimerDuration = conn.aliveTimerDuration,
    bool acceptUnverified = false,
    bool useSSL = true,
    ({InternetAddress host, int port})? proxyInfo,
    SecurityContext? securityContext,
    bool Function(X509Certificate)? onBadCertificate,
  }) =>
      _connectClient(
        host,
        port: port,
        connectionTimeout: connectionTimeout,
        requestTimeout: requestTimeout,
        closeTimeout: closeTimeout,
        acceptUnverified: acceptUnverified,
        useSSL: useSSL,
        proxyInfo: proxyInfo,
        securityContext: securityContext,
        onBadCertificate: onBadCertificate,
        create: (channel) => ElectrumClient(
            channel, host, port, useSSL, proxyInfo,
            requestTimeout: requestTimeout, closeTimeout: closeTimeout),
      );

  @override
  String toString() => 'RavenElectrumClient connected to $host:$port';
}

/// Methods on FiroElectrumClient are defined in the `methods/specific/firo.dart` file.
///
/// See https://github.com/firoorg/electrumx-firo
class FiroElectrumClient extends ElectrumClient {
  FiroElectrumClient(StreamChannel<dynamic> channel, String host, int port,
      bool useSSL, ({InternetAddress host, int port})? proxyInfo,
      {super.requestTimeout, super.closeTimeout})
      : super(channel, host, port, useSSL, proxyInfo);
  String clientName = 'electrum_adapter';
  String clientVersion = '2.0';
  // Firo servers speak protocol 1.4 to 1.6 and reject 1.10.
  String protocolVersion = '1.4';

  /// Opens the transport and negotiates server.version within one
  /// [connectionTimeout], which defaults as for [conn.connect]. Later RPCs
  /// use [requestTimeout], if given.
  static Future<FiroElectrumClient> connect(
    String host, {
    int port = 50002,
    Duration? connectionTimeout,
    Duration? requestTimeout,
    Duration closeTimeout = BaseClient.defaultCloseTimeout,
    Duration aliveTimerDuration = conn.aliveTimerDuration,
    bool acceptUnverified = false,
    String clientName = 'electrum_adapter',
    String clientVersion = '2.0',
    String protocolVersion = '1.4',
    bool useSSL = true,
    ({InternetAddress host, int port})? proxyInfo,
    SecurityContext? securityContext,
    bool Function(X509Certificate)? onBadCertificate,
  }) =>
      _connectClient(
        host,
        port: port,
        connectionTimeout: connectionTimeout,
        requestTimeout: requestTimeout,
        closeTimeout: closeTimeout,
        acceptUnverified: acceptUnverified,
        useSSL: useSSL,
        proxyInfo: proxyInfo,
        securityContext: securityContext,
        onBadCertificate: onBadCertificate,
        create: (channel) => FiroElectrumClient(
            channel, host, port, useSSL, proxyInfo,
            requestTimeout: requestTimeout, closeTimeout: closeTimeout),
        initialize: (client, timeout) async {
          client.clientName = clientName;
          client.clientVersion = clientVersion;
          client.protocolVersion = protocolVersion;
          await client.serverVersion(
              clientName: '$clientName/$clientVersion',
              protocolVersion: protocolVersion,
              timeout: timeout);
        },
      );

  @override
  String toString() => 'FiroElectrumClient connected to $host:$port';
}

/// Methods on RavenElectrumClient are defined in the `methods` directory.
/// See https://electrumx-ravencoin.readthedocs.io/en/latest/protocol-methods.html
class RavenElectrumClient extends ElectrumClient {
  RavenElectrumClient(StreamChannel<dynamic> channel,
      {String host = '',
      int port = 50002,
      bool useSSL = true,
      ({InternetAddress host, int port})? proxyInfo,
      super.requestTimeout,
      super.closeTimeout})
      : super(channel, host, port, useSSL, proxyInfo);
  String clientName = 'MTWallet';
  String clientVersion = '1.0';

  /// The protocol version the server agreed to in [connect].
  String protocolVersion = '1.10';

  /// Opens the transport and negotiates server.version within one
  /// [connectionTimeout], which defaults as for [conn.connect]. Later RPCs
  /// use [requestTimeout], if given.
  static Future<RavenElectrumClient> connect(
    String host, {
    int port = 50002,
    Duration? connectionTimeout,
    Duration? requestTimeout,
    Duration closeTimeout = BaseClient.defaultCloseTimeout,
    Duration aliveTimerDuration = conn.aliveTimerDuration,
    bool acceptUnverified = false,
    String clientName = 'MTWallet',
    String clientVersion = '1.0',
    String? minProtocolVersion = '1.4',
    String protocolVersion = '1.10',
    bool useSSL = true,
    ({InternetAddress host, int port})? proxyInfo,
    SecurityContext? securityContext,
    bool Function(X509Certificate)? onBadCertificate,
  }) =>
      _connectClient(
        host,
        port: port,
        connectionTimeout: connectionTimeout,
        requestTimeout: requestTimeout,
        closeTimeout: closeTimeout,
        acceptUnverified: acceptUnverified,
        useSSL: useSSL,
        proxyInfo: proxyInfo,
        securityContext: securityContext,
        onBadCertificate: onBadCertificate,
        create: (channel) => RavenElectrumClient(channel,
            host: host,
            port: port,
            useSSL: useSSL,
            proxyInfo: proxyInfo,
            requestTimeout: requestTimeout,
            closeTimeout: closeTimeout),
        initialize: (client, timeout) async {
          client.clientName = clientName;
          client.clientVersion = clientVersion;
          final version = await client.serverVersion(
              clientName: '$clientName/$clientVersion',
              minProtocolVersion: minProtocolVersion,
              protocolVersion: protocolVersion,
              timeout: timeout);
          client.protocolVersion = version.protocol;
        },
      );

  @override
  String toString() => 'RavenElectrumClient connected to $host:$port';
}

// Socket establishment and protocol negotiation share one deadline. Failure
// before returning a client must release the channel, including parse errors.
Future<T> _connectClient<T extends ElectrumClient>(
  String host, {
  required int port,
  required Duration? connectionTimeout,
  required Duration? requestTimeout,
  required Duration closeTimeout,
  required bool acceptUnverified,
  required bool useSSL,
  required ({InternetAddress host, int port})? proxyInfo,
  required SecurityContext? securityContext,
  required bool Function(X509Certificate)? onBadCertificate,
  required T Function(StreamChannel<dynamic>) create,
  // Negotiates within the timeout it is given.
  Future<void> Function(T client, Duration timeout)? initialize,
}) async {
  final timeout =
      resolveConnectionTimeout(connectionTimeout, proxied: proxyInfo != null);
  if (requestTimeout != null) checkPositive(requestTimeout, 'requestTimeout');
  checkPositive(closeTimeout, 'closeTimeout');
  final watch = Stopwatch()..start();
  final channel = await conn.connect(
    host,
    port: port,
    connectionTimeout: timeout,
    acceptUnverified: acceptUnverified,
    useSSL: useSSL,
    proxyInfo: proxyInfo,
    securityContext: securityContext,
    onBadCertificate: onBadCertificate,
  );
  T? client;
  try {
    client = create(channel);
    if (initialize != null) {
      // Negotiation gets what the transport left of the deadline, rather than
      // the request timeout, and its expiry is a connection timeout.
      ConnectionTimeoutException expired() => ConnectionTimeoutException(
          'Electrum protocol negotiation with $host:$port timed out', timeout);
      final remaining = timeout - watch.elapsed;
      if (remaining <= Duration.zero) throw expired();
      try {
        await initialize(client, remaining);
      } on TimeoutException {
        throw expired();
      }
    }
    return client;
  } catch (_) {
    // Do not wait for a server that failed to negotiate.
    if (client != null) await client.close();
    channel.abort();
    rethrow;
  }
}
