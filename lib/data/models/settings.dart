import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import 'library.dart';

enum ImageQuality {
  original('original', 'Оригинал', null),
  high('high', 'Высокое (1080px)', 1080),
  dataSaver('data_saver', 'Экономия трафика (720px)', 720);

  const ImageQuality(this.api, this.label, this.width);
  final String api;
  final String label;
  final int? width;

  static ImageQuality parse(String? v) => values.firstWhere((q) => q.api == v, orElse: () => ImageQuality.original);
}

enum LibraryView {
  grid('grid', 'Сетка'),
  compact('compact', 'Компактно'),
  list('list', 'Список');

  const LibraryView(this.api, this.label);
  final String api;
  final String label;

  static LibraryView parse(String? v) => values.firstWhere((x) => x.api == v, orElse: () => LibraryView.grid);
}

enum ReaderBackground {
  black('black', 'Чёрный'),
  gray('gray', 'Графит'),
  white('white', 'Светлый');

  const ReaderBackground(this.api, this.label);
  final String api;
  final String label;

  static ReaderBackground parse(String? v) =>
      values.firstWhere((b) => b.api == v, orElse: () => ReaderBackground.black);
}

/// User-tunable settings. Persisted locally and synced via `/users/me/settings`
/// (last-write-wins on [updatedAt]). Device-specific values (server URL) are
/// not synced.
@immutable
class AppSettings {
  const AppSettings({
    required this.apiBaseUrl,
    required this.updatedAt,
    this.themeMode = ThemeMode.dark,
    this.defaultReadingMode,
    this.readerBackground = ReaderBackground.black,
    this.keepScreenOn = true,
    this.tapZones = true,
    this.preloadPages = 4,
    this.autoNextChapter = true,
    this.imageQuality = ImageQuality.original,
    this.showNsfw = false,
    this.disabledSources = const [],
    this.excludedGenres = const [],
    this.primarySource = 'mangalib',
    this.notifyUpdates = true,
    this.readerBrightness = 1.0,
    this.downloadWifiOnly = false,
    this.hideReadChapters = false,
    this.accent = AccentPalette.ember,
    this.libraryView = LibraryView.grid,
    this.volumeKeys = false,
    this.volumeKeysInverted = false,
  });

  final String apiBaseUrl;
  final ThemeMode themeMode;

  /// null = choose automatically from the title format.
  final ReadingMode? defaultReadingMode;
  final ReaderBackground readerBackground;
  final bool keepScreenOn;
  final bool tapZones;
  final int preloadPages;
  final bool autoNextChapter;
  final ImageQuality imageQuality;
  final bool showNsfw;
  final List<String> disabledSources;
  final List<String> excludedGenres;
  final String primarySource;
  final bool notifyUpdates;
  final double readerBrightness;
  final bool downloadWifiOnly;
  final bool hideReadChapters;
  final AccentPalette accent;
  final LibraryView libraryView;

  /// Turn pages with the phone's volume buttons (Android).
  final bool volumeKeys;

  /// false: volume-down = next page; true: volume-up = next page.
  final bool volumeKeysInverted;
  final DateTime updatedAt;

  AppSettings copyWith({
    String? apiBaseUrl,
    ThemeMode? themeMode,
    ReadingMode? Function()? defaultReadingMode,
    ReaderBackground? readerBackground,
    bool? keepScreenOn,
    bool? tapZones,
    int? preloadPages,
    bool? autoNextChapter,
    ImageQuality? imageQuality,
    bool? showNsfw,
    List<String>? disabledSources,
    List<String>? excludedGenres,
    String? primarySource,
    bool? notifyUpdates,
    double? readerBrightness,
    bool? downloadWifiOnly,
    bool? hideReadChapters,
    AccentPalette? accent,
    LibraryView? libraryView,
    bool? volumeKeys,
    bool? volumeKeysInverted,
    DateTime? updatedAt,
  }) =>
      AppSettings(
        apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
        themeMode: themeMode ?? this.themeMode,
        defaultReadingMode: defaultReadingMode != null ? defaultReadingMode() : this.defaultReadingMode,
        readerBackground: readerBackground ?? this.readerBackground,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
        tapZones: tapZones ?? this.tapZones,
        preloadPages: preloadPages ?? this.preloadPages,
        autoNextChapter: autoNextChapter ?? this.autoNextChapter,
        imageQuality: imageQuality ?? this.imageQuality,
        showNsfw: showNsfw ?? this.showNsfw,
        disabledSources: disabledSources ?? this.disabledSources,
        excludedGenres: excludedGenres ?? this.excludedGenres,
        primarySource: primarySource ?? this.primarySource,
        notifyUpdates: notifyUpdates ?? this.notifyUpdates,
        readerBrightness: readerBrightness ?? this.readerBrightness,
        downloadWifiOnly: downloadWifiOnly ?? this.downloadWifiOnly,
        hideReadChapters: hideReadChapters ?? this.hideReadChapters,
        accent: accent ?? this.accent,
        libraryView: libraryView ?? this.libraryView,
        volumeKeys: volumeKeys ?? this.volumeKeys,
        volumeKeysInverted: volumeKeysInverted ?? this.volumeKeysInverted,
        updatedAt: updatedAt ?? DateTime.now().toUtc(),
      );

  /// Synced part (no device-specific keys).
  Map<String, dynamic> toSyncJson() => {
        'theme_mode': themeMode.name,
        'default_reading_mode': defaultReadingMode?.api,
        'reader_background': readerBackground.api,
        'keep_screen_on': keepScreenOn,
        'tap_zones': tapZones,
        'preload_pages': preloadPages,
        'auto_next_chapter': autoNextChapter,
        'image_quality': imageQuality.api,
        'show_nsfw': showNsfw,
        'disabled_sources': disabledSources,
        'excluded_genres': excludedGenres,
        'primary_source': primarySource,
        'notify_updates': notifyUpdates,
        'download_wifi_only': downloadWifiOnly,
        'hide_read_chapters': hideReadChapters,
        'accent': accent.api,
        'library_view': libraryView.api,
        'volume_keys': volumeKeys,
        'volume_keys_inverted': volumeKeysInverted,
      };

  Map<String, dynamic> toJson() => {
        ...toSyncJson(),
        'api_base_url': apiBaseUrl,
        'reader_brightness': readerBrightness,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory AppSettings.fromJson(Map<String, dynamic> j, {required String fallbackUrl}) {
    List<String> strs(Object? v) => [for (final x in (v as List? ?? const [])) x as String];
    final rm = j['default_reading_mode'] as String?;
    return AppSettings(
      apiBaseUrl: (j['api_base_url'] as String?)?.trim().isNotEmpty == true ? j['api_base_url'] as String : fallbackUrl,
      themeMode: ThemeMode.values.firstWhere((m) => m.name == j['theme_mode'], orElse: () => ThemeMode.dark),
      defaultReadingMode: rm == null ? null : ReadingMode.parse(rm),
      readerBackground: ReaderBackground.parse(j['reader_background'] as String?),
      keepScreenOn: j['keep_screen_on'] as bool? ?? true,
      tapZones: j['tap_zones'] as bool? ?? true,
      preloadPages: (j['preload_pages'] as num?)?.toInt().clamp(1, 10) ?? 4,
      autoNextChapter: j['auto_next_chapter'] as bool? ?? true,
      imageQuality: ImageQuality.parse(j['image_quality'] as String?),
      showNsfw: j['show_nsfw'] as bool? ?? false,
      disabledSources: strs(j['disabled_sources']),
      excludedGenres: strs(j['excluded_genres']),
      primarySource: j['primary_source'] as String? ?? 'mangalib',
      notifyUpdates: j['notify_updates'] as bool? ?? true,
      readerBrightness: (j['reader_brightness'] as num?)?.toDouble().clamp(0.15, 1.0) ?? 1.0,
      downloadWifiOnly: j['download_wifi_only'] as bool? ?? false,
      hideReadChapters: j['hide_read_chapters'] as bool? ?? false,
      accent: AccentPalette.parse(j['accent'] as String?),
      libraryView: LibraryView.parse(j['library_view'] as String?),
      volumeKeys: j['volume_keys'] as bool? ?? false,
      volumeKeysInverted: j['volume_keys_inverted'] as bool? ?? false,
      updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  /// Applies server-synced keys on top of local device-specific ones.
  AppSettings mergeRemote(Map<String, dynamic> remote, DateTime remoteUpdatedAt) {
    final merged = {...toJson(), ...remote, 'updated_at': remoteUpdatedAt.toIso8601String()};
    merged['api_base_url'] = apiBaseUrl;
    merged['reader_brightness'] = readerBrightness;
    return AppSettings.fromJson(merged, fallbackUrl: apiBaseUrl);
  }
}
