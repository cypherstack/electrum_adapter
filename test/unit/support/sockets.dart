import 'dart:io';
import 'dart:typed_data';

/// SO_LINGER {on, 0 s}, which makes closing a socket send a reset, or null
/// where that cannot be forced. On Windows the option can be set, but Dart
/// still closes the socket gracefully, so tests that need a reset skip there.
RawSocketOption? resetOption() {
  final value = Uint8List.view(Int32List.fromList([1, 0]).buffer);
  // SO_LINGER's number differs between platforms.
  final option = Platform.isLinux || Platform.isAndroid
      ? 13
      : Platform.isMacOS || Platform.isIOS
          ? 0x80
          : null;
  return option == null
      ? null
      : RawSocketOption(RawSocketOption.levelSocket, option, value);
}
