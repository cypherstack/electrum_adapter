import 'package:electrum_adapter/electrum_adapter.dart';

class ServerVersion {
  String name;
  String protocol;
  ServerVersion(this.name, this.protocol);
}

extension ServerVersionMethod on RavenElectrumClient {
  /// Asks for the highest protocol version from [minProtocolVersion] to
  /// [protocolVersion] that the server speaks, or exactly [protocolVersion]
  /// when [minProtocolVersion] is null.
  ///
  /// A range suits both server lines: current ElectrumX Ravencoin speaks 1.4
  /// to 1.11 but rejects 1.9, and older releases stop at 1.9.
  Future<ServerVersion> serverVersion({
    String clientName = 'RavenElectrumClient',
    String? minProtocolVersion = '1.4',
    String protocolVersion = '1.10',
  }) async {
    var proc = 'server.version';
    var response = await request(proc, [
      clientName,
      minProtocolVersion == null || minProtocolVersion == protocolVersion
          ? protocolVersion
          : [minProtocolVersion, protocolVersion],
    ]);
    return ServerVersion(response[0] as String, response[1] as String);
  }
}
