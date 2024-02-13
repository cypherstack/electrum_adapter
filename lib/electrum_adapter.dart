/// An Electrum client for RavenCoin.
///
/// Connects with https://github.com/Electrum-RVN-SIG/electrumx-ravencoin
library electrum_adapter;

import 'dart:async';

import 'client/subscribing_client.dart';
import 'connect.dart' as conn;
import 'methods/server/version.dart';

export 'connect.dart';
export 'methods/asset/addresses.dart';
export 'methods/asset/assets.dart';
export 'methods/asset/meta.dart';
export 'methods/scripthash/balance.dart';
export 'methods/scripthash/history.dart';
export 'methods/scripthash/unspent.dart';
export 'methods/server/features.dart';
export 'methods/server/ping.dart';
export 'methods/server/stats.dart';
export 'methods/server/version.dart';
export 'methods/transaction/broadcast.dart';
export 'methods/transaction/fee.dart';
export 'methods/transaction/get.dart';
export 'methods/transaction/memo.dart';
export 'subscriptions/subscribe_asset.dart';
export 'subscriptions/subscribe_headers.dart';
export 'subscriptions/subscribe_scripthash.dart';
export 'subscriptions/unsubscribe_scripthash.dart';

class Header {
  String hex;
  int height;
  Header(this.hex, this.height);
}

/// Methods on RavenElectrumClient are defined in the `methods` directory.
/// See https://electrumx-ravencoin.readthedocs.io/en/latest/protocol-methods.html
class ElectrumClient extends SubscribingClient {
  ElectrumClient(channel, String host, int port)
      : this.host = host,
        this.port = port,
        super(channel);
  late final String host;
  late final int port;

  static Future<ElectrumClient> connect({
    required String host,
    required int port,
    Duration connectionTimeout = conn.connectionTimeout,
    Duration aliveTimerDuration = conn.aliveTimerDuration,
    bool acceptUnverified = true,
  }) async {
    final client = ElectrumClient(
      await conn.connect(
        host,
        port: port,
        connectionTimeout: connectionTimeout,
        aliveTimerDuration: aliveTimerDuration,
        acceptUnverified: acceptUnverified,
      ),
      host,
      port,
    );

    return client;
  }
}

/// Methods on RavenElectrumClient are defined in the `methods` directory.
/// See https://electrumx-ravencoin.readthedocs.io/en/latest/protocol-methods.html
class RavenElectrumClient extends ElectrumClient {
  RavenElectrumClient(channel, {String host = '', int port = 50002})
      : super(channel, host, port);
  String clientName = 'MTWallet';
  String clientVersion = '1.0';
  String protocolVersion = '1.10';

  static Future<RavenElectrumClient> connect(
    String host, {
    int port = 50002,
    Duration connectionTimeout = conn.connectionTimeout,
    Duration aliveTimerDuration = conn.aliveTimerDuration,
    bool acceptUnverified = true,
    String clientName = 'MTWallet',
    String clientVersion = '1.0',
    String protocolVersion = '1.10',
  }) async {
    var client = RavenElectrumClient(
      await conn.connect(
        host,
        port: port,
        connectionTimeout: connectionTimeout,
        aliveTimerDuration: aliveTimerDuration,
        acceptUnverified: acceptUnverified,
      ),
      host: host,
      port: port,
    );
    client.clientName = clientName;
    client.protocolVersion = protocolVersion;
    await client.serverVersion(
        clientName: '$clientName/$clientVersion',
        protocolVersion: protocolVersion);
    return client;
  }

  @override
  String toString() => 'RavenElectrumClient connected to $host:$port';
}
