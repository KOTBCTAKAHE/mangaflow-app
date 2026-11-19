import 'dart:io';

import 'package:flutter/services.dart';

/// Files opened with / shared to MangaFlow (Telegram, Files, Quick Share…).
/// MainActivity copies the content:// stream into the cache and hands us a path.
abstract final class IncomingFiles {
  static const _ch = MethodChannel('mangaflow/transfer');

  static Future<void> listen(void Function(String path) open) async {
    if (!Platform.isAndroid) return;
    Future<void> fetch() async {
      final path = await _ch.invokeMethod<String>('pending');
      if (path != null && path.isNotEmpty) open(path);
    }

    _ch.setMethodCallHandler((call) async {
      if (call.method == 'incoming') await fetch();
    });
    try {
      await fetch();
    } on MissingPluginException {
      // older native side
    } on PlatformException {
      // ignore
    }
  }
}
