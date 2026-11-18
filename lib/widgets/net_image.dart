import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

/// Test/screenshot hook: substitute every network image (covers, pages).
ImageProvider Function(String url)? debugNetworkImageOverride;

/// Widths the backend image proxy produces (`?w=`); anything else is snapped to these.
const proxyWidths = [160, 320, 480, 720, 1080];

/// Smallest proxy width that still covers [logicalWidth] at [dpr] — sharp on
/// high-density screens without downloading originals for tiny thumbnails.
int fitProxyWidth(double logicalWidth, double dpr) {
  final px = logicalWidth * dpr;
  for (final w in proxyWidths) {
    if (w >= px * 0.92) return w;
  }
  return proxyWidths.last;
}

/// Adds/replaces `?w=` on an image-proxy URL.
String withWidth(String url, int width) {
  if (url.isEmpty) return url;
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  return uri.replace(queryParameters: {...uri.queryParameters, 'w': '$width'}).toString();
}

ImageProvider netImage(String url, {int? decodeWidth}) {
  final o = debugNetworkImageOverride;
  final ImageProvider base = o != null ? o(url) : CachedNetworkImageProvider(url);
  return decodeWidth == null ? base : ResizeImage(base, width: decodeWidth, allowUpscaling: false);
}
