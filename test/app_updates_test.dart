import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/data/services/app_updates.dart';

void main() {
  test('version comparison', () {
    expect(compareVersions('1.2.0', '1.1.9'), greaterThan(0));
    expect(compareVersions('1.10.0', '1.9.0'), greaterThan(0));
    expect(compareVersions('1.1.1', '1.1.1'), 0);
    expect(compareVersions('1.1.1+5', '1.1.1'), 0);
    expect(compareVersions('2.0', '2.0.1'), lessThan(0));
  });

  test('picks the APK for the running ABI', () {
    final assets = [
      {'name': 'MangaFlow-v1.2.0-universal.apk', 'browser_download_url': 'u'},
      {'name': 'MangaFlow-v1.2.0-arm64.apk', 'browser_download_url': 'a64'},
      {'name': 'MangaFlow-v1.2.0-armv7.apk', 'browser_download_url': 'a7'},
      {'name': 'checksums.txt', 'browser_download_url': 'x'},
    ];
    expect(AppUpdater.pickAsset(assets, '3.10 (stable) on "android_arm64"')!['browser_download_url'], 'a64');
    expect(AppUpdater.pickAsset(assets, '3.10 (stable) on "android_arm"')!['browser_download_url'], 'a7');
    expect(AppUpdater.pickAsset(assets, '3.10 (stable) on "android_x64"')!['browser_download_url'], 'u');
    expect(AppUpdater.pickAsset([], 'x'), isNull);
  });
}
