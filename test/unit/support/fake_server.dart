import 'dart:async';

import 'package:stream_channel/stream_channel.dart';

/// The server's end of an in-memory JSON-RPC connection, for a client under
/// test. It records each request it reads, including each one sent in a
/// batch, and can answer them.
class FakeServer {
  final StreamChannelController<dynamic> _wire;

  /// The messages read so far, a batch being one.
  final messages = <dynamic>[];

  /// The requests read so far, in order.
  final requests = <Map<String, dynamic>>[];

  /// Called with each request as it is read.
  void Function(Map<String, dynamic> request)? respond;

  /// With [sync], a message reaches the other end as it is sent, as messages
  /// read at once are delivered one after the other.
  FakeServer({bool sync = false})
      : _wire = StreamChannelController<dynamic>(sync: sync) {
    _wire.foreign.stream.listen((dynamic message) {
      messages.add(message);
      for (final dynamic request in message is List ? message : [message]) {
        final item = request as Map<String, dynamic>;
        requests.add(item);
        respond?.call(item);
      }
    });
  }

  /// The client's end.
  StreamChannel<dynamic> get channel => _wire.local;

  /// Sends to the client.
  StreamSink<dynamic> get sink => _wire.foreign.sink;

  /// Answers [request] with [result].
  void reply(Map<String, dynamic> request, Object? result) =>
      sink.add({'jsonrpc': '2.0', 'id': request['id'], 'result': result});
}
