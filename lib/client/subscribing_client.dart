import 'dart:async';

import 'package:electrum_adapter/client/base_client.dart';
import 'package:electrum_adapter/client/subscribable.dart';
import 'package:json_rpc_2/json_rpc_2.dart';
import 'package:stream_channel/stream_channel.dart';

export 'subscribable.dart';

// Maintain a list of registered Subscribables, one per RPC method prefix
final Map<String, Subscribable> _subscribables = {};
void registerSubscribable(String methodPrefix, int paramsCount) {
  if (!_subscribables.containsKey(methodPrefix)) {
    var subscribable = Subscribable(methodPrefix, paramsCount);
    _subscribables[methodPrefix] = subscribable;
  }
}

class SubscribingClient extends BaseClient {
  final Map<String, List<StreamController<dynamic>>> _subscriptions = {};

  SubscribingClient(StreamChannel<dynamic> channel,
      {super.requestTimeout, super.closeTimeout})
      : super(channel) {
    done.then<void>((_) => _closeSubscriptions(), onError: _closeSubscriptions);
    // This "fallback" handles all valid notifications from the server
    peer.registerFallback((Parameters params) async {
      var methodPrefix = Subscribable.getMethodPrefix(params.method);
      var subscribable = _subscribables[methodPrefix];
      if (subscribable == null) {
        throw RpcException.methodNotFound(methodPrefix);
      }

      var key = subscribable.key(params.asList);
      final controllers =
          List<StreamController<dynamic>>.of(_subscriptions[key] ?? []);
      try {
        var result = subscribable.notificationResult(params.asList);
        for (var controller in controllers) {
          if (!controller.isClosed) controller.add(result);
        }
      } catch (err, stack) {
        for (var controller in controllers) {
          if (!controller.isClosed) controller.addError(err, stack);
        }
      }
    });
  }

  /// Registers a controller for notifications matching [params]. On a closed
  /// client it returns a controller that reports the closure and ends, so a
  /// stream-returning caller reports it through its stream.
  StreamController<T> makeSubscription<T>(
      Subscribable subscribable, List<dynamic> params) {
    if (peer.isClosed) {
      return StreamController<T>()
        ..addError(StateError('Electrum client is closed'))
        ..close().ignore();
    }
    var key = subscribable.key(params);
    var controllers = _subscriptions[key];
    late final StreamController<T> newController;
    newController = StreamController<T>(onCancel: () {
      _removeSubscription(key, newController);
    });
    if (controllers != null) {
      controllers.add(newController);
    } else {
      _subscriptions[key] = [newController];
    }

    return newController;
  }

  Future<Stream<T>> subscribe<T>(String methodPrefix,
      [List<dynamic> params = const []]) async {
    var subscribable = _subscribables[methodPrefix];
    if (subscribable == null) {
      throw RpcException.methodNotFound(methodPrefix);
    }

    final key = subscribable.key(params);
    var controller = makeSubscription<T>(subscribable, params);
    try {
      final result = await request(subscribable.methodSubscribe, params);
      if (controller.isClosed) throw StateError('Electrum subscription closed');
      controller.add(result as T);
      return controller.stream;
    } catch (_) {
      _removeSubscription(key, controller);
      controller.close().ignore();
      rethrow;
    }
  }

  Stream<T> subscribeNonBatch<T>(String methodPrefix,
      [List<dynamic> params = const []]) {
    var subscribable = _subscribables[methodPrefix];
    if (subscribable == null) {
      throw RpcException.methodNotFound(methodPrefix);
    }

    // Invalid params throw here rather than from the failure handler below.
    final key = subscribable.key(params);
    var controller = makeSubscription<T>(subscribable, params);
    request(subscribable.methodSubscribe, params).then<void>((result) {
      if (!controller.isClosed) controller.add(result as T);
    }).catchError((Object error, StackTrace stack) {
      if (!controller.isClosed) {
        controller.addError(error, stack);
        controller.close().ignore();
      }
      _removeSubscription(key, controller);
    });

    return controller.stream;
  }

  void _removeSubscription(String key, StreamController<dynamic> controller) {
    final controllers = _subscriptions[key];
    controllers?.remove(controller);
    if (controllers?.isEmpty ?? false) _subscriptions.remove(key);
  }

  void _closeSubscriptions([Object? error, StackTrace? stack]) {
    final controllers = _subscriptions.values.expand((value) => value).toList();
    _subscriptions.clear();
    for (final controller in controllers) {
      if (controller.isClosed) continue;
      // A subscribe() still awaiting its response has already removed its
      // controller: its request fails before done reports the closure, so it
      // reports the failure through its Future instead.
      if (error != null) controller.addError(error, stack);
      // An unlistened or paused controller need not finish delivering done
      // before the client can release the connection.
      controller.close().ignore();
    }
  }
}
