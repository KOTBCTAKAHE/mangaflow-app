import 'dart:async';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../../data/models/settings.dart';

/// Is the phone on mobile data right now (no Wi-Fi/Ethernet)? Kept up to date
/// from connectivity events; read synchronously when choosing image sizes.
abstract final class NetworkStatus {
  static bool mobile = false;
  static StreamSubscription<List<ConnectivityResult>>? _sub;

  static void _apply(List<ConnectivityResult> r) {
    mobile = r.contains(ConnectivityResult.mobile) &&
        !r.contains(ConnectivityResult.wifi) &&
        !r.contains(ConnectivityResult.ethernet);
  }

  static Future<void> start() async {
    if (_sub != null) return;
    final c = Connectivity();
    try {
      _apply(await c.checkConnectivity());
    } catch (_) {}
    _sub = c.onConnectivityChanged.listen(_apply, onError: (Object _) {});
  }
}

/// Page width to request: the chosen quality, capped at 720px on mobile data with «Экономия трафика».
int? effectivePageWidth(AppSettings s, {bool? onMobile}) {
  final w = s.imageQuality.width;
  if (s.mobileDataSaver && (onMobile ?? NetworkStatus.mobile)) return w == null ? 720 : min(w, 720);
  return w;
}
