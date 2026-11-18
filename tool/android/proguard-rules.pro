# ONNX Runtime uses JNI and reflection from native code.
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**
