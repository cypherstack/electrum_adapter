import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io' as io;
import 'dart:io';

import 'package:electrum_adapter/client/json_newline_transformer.dart';
// ignore: implementation_imports
import 'package:json_rpc_2/src/utils.dart' as utils;
import 'package:socks_socket/socks_socket.dart';
import 'package:stream_channel/stream_channel.dart';

const connectionTimeout = Duration(seconds: 5);
const aliveTimerDuration = Duration(seconds: 2);

/// [acceptUnverified] accepts any certificate on a direct TLS connection,
/// which lets anyone on the path impersonate the server; certificates are
/// always verified through a proxy.
///
/// [securityContext] sets the certificates trusted for TLS, such as a server's
/// self-signed certificate; null uses the platform's trusted roots. A given
/// [securityContext] is always enforced, even when [acceptUnverified] is true.
/// On macOS and iOS the certificate must also list the serverAuth extended
/// key usage.
///
/// [onBadCertificate] is called with a certificate that fails verification,
/// on a direct TLS connection and through a proxy; return true to accept it.
/// It is not called on a direct connection when [acceptUnverified] is true
/// without a [securityContext], which accepts every certificate.
Future<StreamChannel> connect(
  String host, {
  int port = 50002,
  Duration connectionTimeout = connectionTimeout,
  Duration aliveTimerDuration = aliveTimerDuration,
  bool acceptUnverified = false,
  bool useSSL = true,
  ({InternetAddress host, int port})? proxyInfo,
  SecurityContext? securityContext,
  bool Function(X509Certificate)? onBadCertificate,
}) async {
  var socket;
  if (proxyInfo == null) {
    if (useSSL) {
      socket = await io.SecureSocket.connect(host, port,
          timeout: connectionTimeout,
          context: securityContext,
          onBadCertificate: acceptUnverified && securityContext == null
              ? (_) => true
              : onBadCertificate);
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
      sslEnabled: useSSL,
      securityContext: securityContext,
      onBadCertificate: onBadCertificate,
    );
    await socket.connect();

    // Then connect to destination host.
    await socket.connectTo(host, port);

    final proxied = socket as SOCKSSocket;
    final output = proxied.outputStream;
    // Closing the output only drains it, so close the connection as well.
    output.done.whenComplete(proxied.close).ignore();
    var channel = StreamChannel(
        proxied.inputStream as Stream<dynamic>, output as StreamSink<dynamic>);
    var channelUtf8 =
        channel.transform(StreamChannelTransformer.fromCodec(convert.utf8));
    var channelJson = jsonNewlineDocument
        .bind(channelUtf8)
        .transformStream(utils.ignoreFormatExceptions);
    return channelJson;
  }
}
