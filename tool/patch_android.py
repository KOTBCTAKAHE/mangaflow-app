#!/usr/bin/env python3
"""Idempotent post-`flutter create` patches for the Android project.

* INTERNET / notification / boot permissions in the main manifest
* cleartext HTTP allowed (self-hosted backends on a LAN without TLS)
* app label "MangaFlow" and launcher icons
* core library desugaring (required by flutter_local_notifications)

Usage: python3 tool/patch_android.py   (run from the repository root)
"""
from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ANDROID = ROOT / "android"
MANIFEST = ANDROID / "app/src/main/AndroidManifest.xml"


def patch_manifest() -> None:
    text = MANIFEST.read_text()
    perms = [
        "android.permission.INTERNET",
        "android.permission.ACCESS_NETWORK_STATE",
        "android.permission.POST_NOTIFICATIONS",
        "android.permission.RECEIVE_BOOT_COMPLETED",
        "android.permission.WAKE_LOCK",
        "android.permission.FOREGROUND_SERVICE",
        "android.permission.FOREGROUND_SERVICE_SPECIAL_USE",
        "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
        "android.permission.ACCESS_WIFI_STATE",
    ]
    for p in perms:
        if p not in text:
            text = text.replace("<application", f'<uses-permission android:name="{p}"/>\n    <application', 1)
    text = re.sub(r'android:label="[^"]*"', 'android:label="MangaFlow"', text, count=1)
    if "flutter_foreground_task.service.ForegroundService" not in text:
        service = (
            '        <!-- Offline chapter downloads (specialUse: no 6-hour dataSync limit on Android 15+) -->\n'
            '        <service\n'
            '            android:name="com.pravera.flutter_foreground_task.service.ForegroundService"\n'
            '            android:foregroundServiceType="specialUse"\n'
            '            android:stopWithTask="false"\n'
            '            android:exported="false">\n'
            '            <property\n'
            '                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"\n'
            '                android:value="Downloading manga chapters for offline reading" />\n'
            '        </service>\n'
        )
        text = text.replace("    </application>", service + "    </application>", 1)
    if "com.vivo.permissionmanager" not in text:
        vendors = [
            "com.vivo.permissionmanager", "com.iqoo.secure", "com.vivo.abe",
            "com.miui.securitycenter", "com.miui.powerkeeper",
            "com.huawei.systemmanager", "com.hihonor.systemmanager",
            "com.coloros.safecenter", "com.oppo.safe", "com.oneplus.security",
            "com.samsung.android.lool", "com.samsung.android.sm",
        ]
        entries = "        <!-- vendor background-settings screens (package visibility, Android 11+) -->\n"
        entries += "".join(f'        <package android:name="{v}"/>\n' for v in vendors)
        entries += ('        <intent>\n            <action android:name="android.intent.action.VIEW"/>\n'
                    '            <data android:scheme="https"/>\n        </intent>\n')
        if "</queries>" in text:
            text = text.replace("    </queries>", entries + "    </queries>", 1)
        else:
            text = text.replace("</manifest>", "    <queries>\n" + entries + "    </queries>\n</manifest>", 1)
    if "mangaflow-transfer" not in text:
        # «Передать главы»: open/share .cbz/.zip files with MangaFlow
        mimes = "".join(f'                <data android:mimeType="{m}" />\n' for m in (
            "application/zip", "application/x-zip-compressed", "application/x-cbz",
            "application/vnd.comicbook+zip", "application/octet-stream"))
        filters = (
            '            <!-- mangaflow-transfer -->\n'
            '            <intent-filter android:label="Открыть в MangaFlow">\n'
            '                <action android:name="android.intent.action.VIEW" />\n'
            '                <category android:name="android.intent.category.DEFAULT" />\n'
            '                <data android:scheme="content" />\n'
            '                <data android:scheme="file" />\n' + mimes +
            '            </intent-filter>\n'
            '            <intent-filter android:label="Добавить в MangaFlow">\n'
            '                <action android:name="android.intent.action.SEND" />\n'
            '                <category android:name="android.intent.category.DEFAULT" />\n' + mimes +
            '            </intent-filter>\n'
            '            <!-- content:// URIs of opened files must not become go_router routes -->\n'
            '            <meta-data android:name="flutter_deeplinking_enabled" android:value="false" />\n'
        )
        launcher = text.find("android.intent.category.LAUNCHER")
        end = text.find("</intent-filter>", launcher)
        if launcher < 0 or end < 0:
            raise SystemExit("patch_android: launcher intent-filter not found")
        end += len("</intent-filter>\n")
        text = text[:end] + filters + text[end:]
    if "ContinueWidgetProvider" not in text:
        widget = (
            '        <!-- Home-screen widget "Продолжить чтение" -->\n'
            '        <receiver android:name=".ContinueWidgetProvider" android:exported="false" android:label="Продолжить чтение">\n'
            '            <intent-filter>\n'
            '                <action android:name="android.appwidget.action.APPWIDGET_UPDATE" />\n'
            '            </intent-filter>\n'
            '            <meta-data android:name="android.appwidget.provider" android:resource="@xml/continue_widget_info" />\n'
            '        </receiver>\n'
        )
        text = text.replace("    </application>", widget + "    </application>", 1)
    if "allowBackup" not in text:
        # Android auto-backup restores the encrypted token file but not its Keystore key →
        # undecryptable credentials after reinstall/phone transfer. The server sync is the backup.
        text = text.replace("<application", '<application\n        android:allowBackup="false"\n        android:fullBackupContent="false"', 1)
    if "usesCleartextTraffic" not in text:
        text = text.replace("<application", '<application\n        android:usesCleartextTraffic="true"', 1)
    MANIFEST.write_text(text)


SIGN_KTS = """    // Stable release key (CI decodes the ANDROID_KEYSTORE_B64 secret into MF_KEYSTORE).
    // Same key for every build → updates install over the previous version.
    signingConfigs {
        create("mangaflow") {
            val ks = System.getenv("MF_KEYSTORE")
            if (ks != null && file(ks).exists()) {
                storeFile = file(ks)
                storePassword = System.getenv("MF_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("MF_KEY_ALIAS") ?: "mangaflow"
                keyPassword = System.getenv("MF_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            val ks = System.getenv("MF_KEYSTORE")
            signingConfig = if (ks != null && file(ks).exists()) signingConfigs.getByName("mangaflow")
                            else signingConfigs.getByName("debug")
        }
    }"""


def patch_gradle() -> None:
    kts = ANDROID / "app/build.gradle.kts"
    groovy = ANDROID / "app/build.gradle"
    if kts.exists():
        text = kts.read_text()
        if "isCoreLibraryDesugaringEnabled" not in text:
            text = re.sub(r"compileOptions\s*\{", "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", text, count=1)
        if "desugar_jdk_libs" not in text:
            text += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
        # ONNX Runtime now comes with the local plugin packages/mangaflow_upscale
        text = text.replace('    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.24.3")\n', "")
        text = text.replace('    testImplementation("junit:junit:4.13.2")\n', "")
        if "MF_KEYSTORE" not in text:
            text = re.sub(r"    buildTypes \{.*?\n    \}\n", lambda _: SIGN_KTS + "\n", text, count=1, flags=re.S)
        kts.write_text(text)
    elif groovy.exists():
        text = groovy.read_text()
        if "coreLibraryDesugaringEnabled" not in text:
            text = re.sub(r"compileOptions\s*\{", "compileOptions {\n        coreLibraryDesugaringEnabled true", text, count=1)
        if "desugar_jdk_libs" not in text:
            text += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n"
        groovy.write_text(text)
    else:
        raise SystemExit("android/app/build.gradle(.kts) not found — run `flutter create .` first")


def copy_icons() -> None:
    for density in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"):
        src = ROOT / f"assets/icon/ic_launcher_{density}.png"
        dst = ANDROID / f"app/src/main/res/mipmap-{density}/ic_launcher.png"
        if src.exists() and dst.parent.exists():
            shutil.copyfile(src, dst)


GRAPHITE = "#0D0E11"

_LAUNCH = f"""<?xml version="1.0" encoding="utf-8"?>
<!-- MangaFlow dark splash: graphite background + centered app icon. -->
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item><color android:color="{GRAPHITE}" /></item>
    <item android:width="96dp" android:height="96dp" android:gravity="center">
        <bitmap android:gravity="fill" android:src="@mipmap/ic_launcher" />
    </item>
</layer-list>
"""

_STYLES = f"""<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="LaunchTheme" parent="@android:style/Theme.Black.NoTitleBar">
        <item name="android:windowBackground">@drawable/launch_background</item>
        <item name="android:statusBarColor">{GRAPHITE}</item>
        <item name="android:navigationBarColor">{GRAPHITE}</item>
    </style>
    <style name="NormalTheme" parent="@android:style/Theme.Black.NoTitleBar">
        <item name="android:windowBackground">@color/mf_graphite</item>
    </style>
    <color name="mf_graphite">{GRAPHITE}</color>
</resources>
"""

_STYLES_V31 = f"""<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="LaunchTheme" parent="@android:style/Theme.Black.NoTitleBar">
        <item name="android:windowBackground">@drawable/launch_background</item>
        <item name="android:windowSplashScreenBackground">{GRAPHITE}</item>
        <item name="android:windowSplashScreenAnimatedIcon">@mipmap/ic_launcher</item>
        <item name="android:statusBarColor">{GRAPHITE}</item>
        <item name="android:navigationBarColor">{GRAPHITE}</item>
    </style>
    <style name="NormalTheme" parent="@android:style/Theme.Black.NoTitleBar">
        <item name="android:windowBackground">@color/mf_graphite</item>
    </style>
    <color name="mf_graphite">{GRAPHITE}</color>
</resources>
"""




def copy_native_sources() -> None:
    """Kotlin sources live in tool/android (main + JVM unit tests) and are copied into the project."""
    pkg = "com/mangaflow/mangaflow"
    for kind in ("main", "test"):
        src_root = ROOT / "tool/android" / kind
        if not src_root.exists():
            continue
        dst_root = ANDROID / f"app/src/{kind}/kotlin" / pkg
        for f in src_root.rglob("*.kt"):
            dst = dst_root / f.relative_to(src_root)
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(f, dst)
    shutil.copyfile(ROOT / "tool/android/proguard-rules.pro", ANDROID / "app/proguard-rules.pro")
    res_src = ROOT / "tool/android/res"
    for f in res_src.rglob("*.xml"):
        dst = ANDROID / "app/src/main/res" / f.relative_to(res_src)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(f, dst)


def write_splash() -> None:
    res = ANDROID / "app/src/main/res"
    if not res.exists():
        return
    files = {
        "drawable/launch_background.xml": _LAUNCH,
        "drawable-v21/launch_background.xml": _LAUNCH,
        "values/styles.xml": _STYLES,
        "values-night/styles.xml": _STYLES,
        "values-v31/styles.xml": _STYLES_V31,
        "values-night-v31/styles.xml": _STYLES_V31,
    }
    for rel, content in files.items():
        f = res / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(content, encoding="utf-8")


if __name__ == "__main__":
    patch_manifest()
    patch_gradle()
    copy_icons()
    write_splash()
    copy_native_sources()
    print("android project patched")
