import '../../electrum_adapter.dart';

extension FeaturesMethod on FiroElectrumClient {
  Future<Map<String, dynamic>> features() async =>
      await request('server.features');
}
