import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io' as io;
import 'dart:io';

import 'package:electrum_adapter/client/json_newline_transformer.dart';
// ignore: implementation_imports
import 'package:json_rpc_2/src/utils.dart' as utils;
import 'package:stream_channel/stream_channel.dart';
import 'package:tor_ffi_plugin/socks_socket.dart';

const connectionTimeout = Duration(seconds: 5);
const aliveTimerDuration = Duration(seconds: 2);

Future<StreamChannel> connect(
  String host, {
  int port = 50002,
  Duration connectionTimeout = connectionTimeout,
  Duration aliveTimerDuration = aliveTimerDuration,
  bool acceptUnverified = true,
  bool useSSL = true,
  ({InternetAddress host, int port})? proxyInfo,
}) async {
  var socket;
  if (proxyInfo == null) {
    if (useSSL) {
      socket = await io.SecureSocket.connect(host, port,
          timeout: connectionTimeout,
          onBadCertificate: acceptUnverified ? (_) => true : null);
      // TODO do not automatically accept unverified certificates.
    } else {
      socket = await io.Socket.connect(host, port, timeout: connectionTimeout);
    }
    var channel =
        StreamChannel(socket.cast<List<int>>() as Stream, socket as StreamSink);
    var channelUtf8 =
        channel.transform(StreamChannelTransformer.fromCodec(convert.utf8));
    var channelJson = jsonNewlineDocument
        .bind(channelUtf8)
        .transformStream(utils.ignoreFormatExceptions);
    return channelJson;
  } else {
    // Proxy info is provided, so we should use it.
    //
    // First, connect to Tor proxy.
    socket = await SOCKSSocket.create(
      proxyHost: proxyInfo.host.address,
      proxyPort: proxyInfo.port,
      sslEnabled: true,
    );
    await socket.connect();

    // Then connect to destination host.
    await socket.connectTo(host, port);

    var channel = StreamChannel(socket.inputStream as Stream<dynamic>,
        socket.outputStream as StreamSink<dynamic>);
    var channelUtf8 =
        channel.transform(StreamChannelTransformer.fromCodec(convert.utf8));
    var channelJson = jsonNewlineDocument
        .bind(channelUtf8)
        .transformStream(utils.ignoreFormatExceptions);
    return channelJson;
  }
}
