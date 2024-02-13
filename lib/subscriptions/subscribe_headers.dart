import 'package:electrum_adapter/client/subscribing_client.dart';
import 'package:electrum_adapter/electrum_adapter.dart';
import 'package:equatable/equatable.dart';

class BlockHeader extends Equatable {
  final String hex;
  final int height;

  BlockHeader(this.hex, this.height);

  @override
  List<Object> get props => <Object>[hex, height];
}

extension SubscribeHeadersMethod on RavenElectrumClient {
  Stream<BlockHeader> subscribeHeaders() {
    var methodPrefix = 'blockchain.headers';

    // If this is the first time, register
    registerSubscribable(methodPrefix, 0);

    return subscribeNonBatch(methodPrefix).asyncMap((item) => BlockHeader(
          item['hex'] as String,
          item['height'] as int,
        ));
  }
}
