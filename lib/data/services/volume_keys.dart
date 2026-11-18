import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Hardware volume buttons as page-turn keys (Android only).
///
/// Native side (MainActivity) swallows VOLUME_UP/DOWN only while enabled, so the
/// system volume works normally everywhere outside the reader.
class VolumeKeys {
  VolumeKeys._();
  static const _channel = MethodChannel('mangaflow/volume_keys');
  static void Function(bool up)? _handler;

  static Future<void> enable(void Function(bool up) onKey) async {
    if (!Platform.isAndroid) return;
    _handler = onKey;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'key') _handler?.call(call.arguments == 'up');
    });
    try {
      await _channel.invokeMethod<void>('setEnabled', true);
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }

  static Future<void> disable() async {
    if (!Platform.isAndroid) return;
    _handler = null;
    try {
      await _channel.invokeMethod<void>('setEnabled', false);
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
  }
}
