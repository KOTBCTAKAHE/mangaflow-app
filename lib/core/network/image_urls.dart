/// Image-proxy links (`/api/v1/images/<token>`) are built by the server from
/// `PUBLIC_BASE_URL` or from the request it saw — behind a TLS proxy that can be
/// `http://…`, an internal host or a stale address. They are only valid on the
/// server that signed them, which is the one the app talks to, so we always load
/// them from that origin.
abstract final class ImageUrls {
  static Uri? _origin;

  static void setApiBase(String base) {
    final u = Uri.tryParse(base.trim());
    if (u != null && (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty) _origin = u;
  }

  static const _marker = '/api/v1/images/';

  static String fix(String url) {
    final o = _origin;
    if (o == null || !url.contains(_marker)) return url;
    final u = Uri.tryParse(url);
    if (u == null || !u.hasScheme) return url;
    if (u.scheme == o.scheme && u.host == o.host && u.port == o.port) return url;
    final i = u.path.indexOf(_marker);
    if (i < 0) return url;
    var base = o.path;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return u.replace(scheme: o.scheme, host: o.host, port: o.port, path: '$base${u.path.substring(i)}').toString();
  }
}
