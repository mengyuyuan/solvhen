# Flutter ProGuard rules
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**

# Keep webview
-keep class com.sywy.solvhen.** { *; }
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable

# Dio / HTTP
-keep class okhttp3.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**

# sqflite
-keep class com.tekartik.sqflite.** { *; }
