/// Build-time configuration.
///
/// Override the default server with:
///   flutter build apk --dart-define=API_BASE_URL=https://manga.example.com
/// Users can also change it at runtime in Settings → Server.
abstract final class AppConfig {
  static const defaultApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    // 10.0.2.2 is the host machine from the Android emulator.
    defaultValue: 'http://10.0.2.2:8080',
  );

  static const appName = 'MangaFlow';
  static const backupFormat = 'mangaflow-backup';
  static const backupVersion = 1;

  static const connectTimeout = Duration(seconds: 10);
  static const receiveTimeout = Duration(seconds: 30);
  static const searchDebounce = Duration(milliseconds: 350);
  static const progressSaveDebounce = Duration(milliseconds: 400);
  static const syncInterval = Duration(minutes: 5);
  static const titleCacheTtl = Duration(minutes: 30);
}
