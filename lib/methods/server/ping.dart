import '../../electrum_adapter.dart';

extension PingServerMethod on FiroElectrumClient {
  Future<dynamic> ping() async => await request('server.ping');
}
