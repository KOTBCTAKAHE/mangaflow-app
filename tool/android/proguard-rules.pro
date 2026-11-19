# ONNX Runtime uses JNI and reflection from native code.
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# package:jni (used by newer Flutter plugins) looks Java classes up by name from
# Dart; R8 must not strip or rename them, nor the Android classes it reaches.
-keep class com.github.dart_lang.jni.** { *; }
-keep class com.github.dart_lang.jni_flutter.** { *; }
-dontwarn com.github.dart_lang.jni.**
