import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../core/network/proxy.dart';
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

/// On-device AI upscaling of pages (waifu2x on ONNX Runtime).
enum UpscaleMode {
  off('off', 'Выключено'),
  auto('auto', 'Авто'),
  always('always', 'Всегда');

  const UpscaleMode(this.api, this.label);
  final String api;
  final String label;

  static UpscaleMode parse(String? v) => values.firstWhere((x) => x.api == v, orElse: () => UpscaleMode.off);
}

enum UpscaleQuality {
  fast('fast', 'Быстро', 'waifu2x UpConv7'),
  balanced('balanced', 'Баланс', 'waifu2x CUNet'),
  max('max', 'Максимум', 'waifu2x Swin (сканы манги)');

  const UpscaleQuality(this.api, this.label, this.model);
  final String api;
  final String label;
  final String model;

  static UpscaleQuality parse(String? v) => values.firstWhere((x) => x.api == v, orElse: () => UpscaleQuality.fast);
}

/// «По кадрам»: in which order panels are read.
enum PanelOrder {
  auto('auto', 'Авто'),
  rtl('rtl', 'Справа налево'),
  ltr('ltr', 'Слева направо');

  const PanelOrder(this.api, this.label);
  final String api;
  final String label;

  static PanelOrder parse(String? v) => values.firstWhere((o) => o.api == v, orElse: () => PanelOrder.auto);
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
    this.novel = const NovelPrefs(),
    this.tapZones = true,
    this.preloadPages = 4,
    this.autoNextChapter = true,
    this.imageQuality = ImageQuality.original,
    this.showNsfw = false,
    this.disabledSources = const [],
    this.sourceLanguages = const ['ru', 'en'],
    this.excludedGenres = const [],
    this.primarySource = 'mangalib',
    this.notifyUpdates = true,
    this.readerBrightness = 1.0,
    this.downloadWifiOnly = false,
    this.hideReadChapters = false,
    this.accent = AccentPalette.wallpaper,
    this.libraryView = LibraryView.grid,
    this.volumeKeys = false,
    this.volumeKeysInverted = false,
    this.readerWarmth = 0,
    this.autoScrollSpeed = 120,
    this.upscaleMode = UpscaleMode.auto,
    this.upscaleQuality = UpscaleQuality.fast,
    this.upscaleDownloads = true,
    this.panelMode = false,
    this.autoCrop = true,
    this.mergeSources = true,
    this.panelOrder = PanelOrder.auto,
    this.mobileDataSaver = true,
    this.autoDownloadNew = false,
    this.incognito = false,
    this.appLock = false,
    this.lockBiometrics = true,
    this.lockTimeoutSec = 60,
    this.hideInRecents = false,
    this.proxy = const ProxyConfig(),
  });

  /// Always the official server (custom servers are no longer supported).
  final String apiBaseUrl;

  /// Device-only: proxy to reach the server through.
  final ProxyConfig proxy;
  final ThemeMode themeMode;

  /// null = choose automatically from the title format.
  final ReadingMode? defaultReadingMode;
  final ReaderBackground readerBackground;
  final bool keepScreenOn;

  /// Ранобэ: how text reads (synced with the account).
  final NovelPrefs novel;
  final bool tapZones;
  final int preloadPages;
  final bool autoNextChapter;
  final ImageQuality imageQuality;
  final bool showNsfw;
  final List<String> disabledSources;

  /// Catalog languages shown in the app (sources in other languages are hidden).
  final List<String> sourceLanguages;
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

  /// Night-reading warm filter strength, 0 = off (device-local, like brightness).
  final double readerWarmth;

  /// Webtoon auto-scroll speed in logical px/s.
  final double autoScrollSpeed;

  /// AI upscaling of pages on the phone.
  final UpscaleMode upscaleMode;
  final UpscaleQuality upscaleQuality;

  /// Upscale downloaded chapters in the background download service (e.g. overnight).
  final bool upscaleDownloads;

  /// Paged reader: zoom from panel to panel («по кадрам»).
  final bool panelMode;

  /// Paged modes: cut the white margins around a page so the picture is bigger.
  final bool autoCrop;

  /// One title, every source: chapters missing on the title's site come from the others.
  final bool mergeSources;

  /// auto: manga right-to-left, manhwa / manhua / comics left-to-right.
  final PanelOrder panelOrder;

  /// On mobile data load pages at 720px (AI upscaling on the phone restores sharpness).
  final bool mobileDataSaver;

  /// Download new chapters of «Читаю» titles on Wi-Fi while charging.
  final bool autoDownloadNew;

  /// Device-only privacy: no history, progress or search history is written; nothing is synced.
  final bool incognito;

  /// PIN (stored hashed in secure storage) + optional fingerprint/face to open the app.
  final bool appLock;
  final bool lockBiometrics;

  /// Lock again after this long in the background (0 = right away).
  final int lockTimeoutSec;

  /// Blank preview in «Недавние приложения» (Android 13+; older Android also blocks screenshots).
  final bool hideInRecents;
  final DateTime updatedAt;

  AppSettings copyWith({
    String? apiBaseUrl,
    ThemeMode? themeMode,
    ReadingMode? Function()? defaultReadingMode,
    ReaderBackground? readerBackground,
    bool? keepScreenOn,
    NovelPrefs? novel,
    bool? tapZones,
    int? preloadPages,
    bool? autoNextChapter,
    ImageQuality? imageQuality,
    bool? showNsfw,
    List<String>? disabledSources,
    List<String>? sourceLanguages,
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
    double? readerWarmth,
    double? autoScrollSpeed,
    UpscaleMode? upscaleMode,
    UpscaleQuality? upscaleQuality,
    bool? upscaleDownloads,
    bool? panelMode,
    bool? autoCrop,
    bool? mergeSources,
    ProxyConfig? proxy,
    PanelOrder? panelOrder,
    bool? mobileDataSaver,
    bool? autoDownloadNew,
    bool? incognito,
    bool? appLock,
    bool? lockBiometrics,
    int? lockTimeoutSec,
    bool? hideInRecents,
    DateTime? updatedAt,
  }) =>
      AppSettings(
        apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
        themeMode: themeMode ?? this.themeMode,
        defaultReadingMode: defaultReadingMode != null ? defaultReadingMode() : this.defaultReadingMode,
        readerBackground: readerBackground ?? this.readerBackground,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
        novel: novel ?? this.novel,
        tapZones: tapZones ?? this.tapZones,
        preloadPages: preloadPages ?? this.preloadPages,
        autoNextChapter: autoNextChapter ?? this.autoNextChapter,
        imageQuality: imageQuality ?? this.imageQuality,
        showNsfw: showNsfw ?? this.showNsfw,
        disabledSources: disabledSources ?? this.disabledSources,
        sourceLanguages: sourceLanguages ?? this.sourceLanguages,
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
        readerWarmth: readerWarmth ?? this.readerWarmth,
        autoScrollSpeed: autoScrollSpeed ?? this.autoScrollSpeed,
        upscaleMode: upscaleMode ?? this.upscaleMode,
        upscaleQuality: upscaleQuality ?? this.upscaleQuality,
        upscaleDownloads: upscaleDownloads ?? this.upscaleDownloads,
        panelMode: panelMode ?? this.panelMode,
        autoCrop: autoCrop ?? this.autoCrop,
        mergeSources: mergeSources ?? this.mergeSources,
        proxy: proxy ?? this.proxy,
        panelOrder: panelOrder ?? this.panelOrder,
        mobileDataSaver: mobileDataSaver ?? this.mobileDataSaver,
        autoDownloadNew: autoDownloadNew ?? this.autoDownloadNew,
        incognito: incognito ?? this.incognito,
        appLock: appLock ?? this.appLock,
        lockBiometrics: lockBiometrics ?? this.lockBiometrics,
        lockTimeoutSec: lockTimeoutSec ?? this.lockTimeoutSec,
        hideInRecents: hideInRecents ?? this.hideInRecents,
        updatedAt: updatedAt ?? DateTime.now().toUtc(),
      );

  /// Synced part (no device-specific keys).
  Map<String, dynamic> toSyncJson() => {
        'theme_mode': themeMode.name,
        'default_reading_mode': defaultReadingMode?.api,
        'reader_background': readerBackground.api,
        'keep_screen_on': keepScreenOn,
        'novel': novel.toJson(),
        'tap_zones': tapZones,
        'preload_pages': preloadPages,
        'auto_next_chapter': autoNextChapter,
        'image_quality': imageQuality.api,
        'show_nsfw': showNsfw,
        'disabled_sources': disabledSources,
        'source_languages': sourceLanguages,
        'excluded_genres': excludedGenres,
        'primary_source': primarySource,
        'notify_updates': notifyUpdates,
        'download_wifi_only': downloadWifiOnly,
        'hide_read_chapters': hideReadChapters,
        'accent': accent.api,
        'accent_v': 2,
        'library_view': libraryView.api,
        'volume_keys': volumeKeys,
        'volume_keys_inverted': volumeKeysInverted,
        'auto_scroll_speed': autoScrollSpeed,
        'upscale_mode_v2': upscaleMode.api,
        'upscale_quality': upscaleQuality.api,
        'upscale_downloads': upscaleDownloads,
        'panel_mode': panelMode,
        'auto_crop': autoCrop,
        'merge_sources': mergeSources,
        'panel_order': panelOrder.api,
        'mobile_data_saver': mobileDataSaver,
        'auto_download_new': autoDownloadNew,
      };

  Map<String, dynamic> toJson() => {
        ...toSyncJson(),
        'api_base_url': apiBaseUrl,
        'reader_brightness': readerBrightness,
        'reader_warmth': readerWarmth,
        // device-only: never synced to the account
        'incognito': incognito,
        'app_lock': appLock,
        'lock_biometrics': lockBiometrics,
        'lock_timeout_sec': lockTimeoutSec,
        'hide_in_recents': hideInRecents,
        'proxy': proxy.toJson(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory AppSettings.fromJson(Map<String, dynamic> j, {required String fallbackUrl}) {
    List<String> strs(Object? v) => [for (final x in (v as List? ?? const [])) x as String];
    final rm = j['default_reading_mode'] as String?;
    return AppSettings(
      apiBaseUrl: AppConfig.defaultApiBaseUrl,
      themeMode: ThemeMode.values.firstWhere((m) => m.name == j['theme_mode'], orElse: () => ThemeMode.dark),
      defaultReadingMode: rm == null ? null : ReadingMode.parse(rm),
      readerBackground: ReaderBackground.parse(j['reader_background'] as String?),
      keepScreenOn: j['keep_screen_on'] as bool? ?? true,
      novel: NovelPrefs.fromJson(j['novel']),
      tapZones: j['tap_zones'] as bool? ?? true,
      preloadPages: (j['preload_pages'] as num?)?.toInt().clamp(1, 10) ?? 4,
      autoNextChapter: j['auto_next_chapter'] as bool? ?? true,
      imageQuality: ImageQuality.parse(j['image_quality'] as String?),
      showNsfw: j['show_nsfw'] as bool? ?? false,
      disabledSources: strs(j['disabled_sources']),
      sourceLanguages: j['source_languages'] == null ? const ['ru', 'en'] : strs(j['source_languages']),
      excludedGenres: strs(j['excluded_genres']),
      primarySource: j['primary_source'] as String? ?? 'mangalib',
      notifyUpdates: j['notify_updates'] as bool? ?? true,
      readerBrightness: (j['reader_brightness'] as num?)?.toDouble().clamp(0.15, 1.0) ?? 1.0,
      downloadWifiOnly: j['download_wifi_only'] as bool? ?? false,
      hideReadChapters: j['hide_read_chapters'] as bool? ?? false,
      // 2.9: everyone starts on Material You (wallpaper colours) once; a later choice sticks
      accent: j['accent_v'] == 2 ? AccentPalette.parse(j['accent'] as String?) : AccentPalette.wallpaper,
      libraryView: LibraryView.parse(j['library_view'] as String?),
      volumeKeys: j['volume_keys'] as bool? ?? false,
      volumeKeysInverted: j['volume_keys_inverted'] as bool? ?? false,
      readerWarmth: (j['reader_warmth'] as num?)?.toDouble().clamp(0.0, 1.0) ?? 0,
      autoScrollSpeed: (j['auto_scroll_speed'] as num?)?.toDouble().clamp(30.0, 600.0) ?? 120,
      upscaleMode: j['upscale_mode_v2'] == null ? UpscaleMode.auto : UpscaleMode.parse(j['upscale_mode_v2'] as String?),
      upscaleQuality: UpscaleQuality.parse(j['upscale_quality'] as String?),
      upscaleDownloads: j['upscale_downloads'] as bool? ?? true,
      panelMode: j['panel_mode'] as bool? ?? false,
      autoCrop: j['auto_crop'] as bool? ?? true,
      mergeSources: j['merge_sources'] as bool? ?? true,
      panelOrder: PanelOrder.parse(j['panel_order'] as String?),
      mobileDataSaver: j['mobile_data_saver'] as bool? ?? true,
      autoDownloadNew: j['auto_download_new'] as bool? ?? false,
      incognito: j['incognito'] as bool? ?? false,
      appLock: j['app_lock'] as bool? ?? false,
      lockBiometrics: j['lock_biometrics'] as bool? ?? true,
      lockTimeoutSec: (j['lock_timeout_sec'] as num?)?.toInt().clamp(0, 3600) ?? 60,
      hideInRecents: j['hide_in_recents'] as bool? ?? false,
      proxy: ProxyConfig.fromJson(j['proxy']),
      updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  /// Applies server-synced keys on top of local device-specific ones.
  AppSettings mergeRemote(Map<String, dynamic> remote, DateTime remoteUpdatedAt) {
    final merged = {...toJson(), ...remote, 'updated_at': remoteUpdatedAt.toIso8601String()};
    merged['api_base_url'] = apiBaseUrl;
    merged['reader_brightness'] = readerBrightness;
    merged['reader_warmth'] = readerWarmth;
    merged['proxy'] = proxy.toJson();
    return AppSettings.fromJson(merged, fallbackUrl: apiBaseUrl);
  }
}

enum NovelFont {
  serif('serif', 'С засечками', 'serif'),
  sans('sans', 'Без засечек', 'sans-serif'),
  app('app', 'Manrope', 'Manrope');

  const NovelFont(this.api, this.label, this.family);
  final String api;
  final String label;
  final String family;

  static NovelFont parse(String? v) => values.firstWhere((f) => f.api == v, orElse: () => NovelFont.serif);
}

enum NovelTheme {
  night('night', 'Ночь', Color(0xFF16151A), Color(0xFFD9D4CC)),
  black('black', 'Чёрная', Color(0xFF000000), Color(0xFFB9B4AC)),
  sepia('sepia', 'Сепия', Color(0xFFF3E8D2), Color(0xFF4A3B2A)),
  day('day', 'День', Color(0xFFFBFAF7), Color(0xFF1E1D1B));

  const NovelTheme(this.api, this.label, this.background, this.text);
  final String api;
  final String label;
  final Color background;
  final Color text;
  bool get isDark => background.computeLuminance() < 0.2;

  static NovelTheme parse(String? v) => values.firstWhere((t) => t.api == v, orElse: () => NovelTheme.night);
}

/// Ранобэ reader: typography and page colours.
@immutable
class NovelPrefs {
  const NovelPrefs({
    this.fontSize = 19,
    this.lineHeight = 1.65,
    this.font = NovelFont.serif,
    this.theme = NovelTheme.night,
    this.margin = 22,
    this.justify = true,
    this.indent = true,
  });

  final double fontSize;
  final double lineHeight;
  final NovelFont font;
  final NovelTheme theme;
  final double margin;
  final bool justify;
  final bool indent;

  NovelPrefs copyWith({double? fontSize, double? lineHeight, NovelFont? font, NovelTheme? theme, double? margin, bool? justify, bool? indent}) =>
      NovelPrefs(
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        font: font ?? this.font,
        theme: theme ?? this.theme,
        margin: margin ?? this.margin,
        justify: justify ?? this.justify,
        indent: indent ?? this.indent,
      );

  Map<String, dynamic> toJson() => {
        'font_size': fontSize,
        'line_height': lineHeight,
        'font': font.api,
        'theme': theme.api,
        'margin': margin,
        'justify': justify,
        'indent': indent,
      };

  factory NovelPrefs.fromJson(Object? j) {
    if (j is! Map) return const NovelPrefs();
    return NovelPrefs(
      fontSize: ((j['font_size'] as num?)?.toDouble() ?? 19).clamp(13, 32).toDouble(),
      lineHeight: ((j['line_height'] as num?)?.toDouble() ?? 1.65).clamp(1.2, 2.2).toDouble(),
      font: NovelFont.parse(j['font'] as String?),
      theme: NovelTheme.parse(j['theme'] as String?),
      margin: ((j['margin'] as num?)?.toDouble() ?? 22).clamp(8, 48).toDouble(),
      justify: j['justify'] as bool? ?? true,
      indent: j['indent'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NovelPrefs &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.font == font &&
      other.theme == theme &&
      other.margin == margin &&
      other.justify == justify &&
      other.indent == indent;

  @override
  int get hashCode => Object.hash(fontSize, lineHeight, font, theme, margin, justify, indent);
}

