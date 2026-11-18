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
    if "usesCleartextTraffic" not in text:
        text = text.replace("<application", '<application\n        android:usesCleartextTraffic="true"', 1)
    MANIFEST.write_text(text)


def patch_gradle() -> None:
    kts = ANDROID / "app/build.gradle.kts"
    groovy = ANDROID / "app/build.gradle"
    if kts.exists():
        text = kts.read_text()
        if "isCoreLibraryDesugaringEnabled" not in text:
            text = re.sub(r"compileOptions\s*\{", "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", text, count=1)
        if "desugar_jdk_libs" not in text:
            text += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
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


if __name__ == "__main__":
    patch_manifest()
    patch_gradle()
    copy_icons()
    print("android project patched")
