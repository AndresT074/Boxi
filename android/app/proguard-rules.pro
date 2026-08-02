# =========================================================
# REEMPAQUETADO Y OPTIMIZACIÓN DE R8
# =========================================================
-repackageclasses ''
-allowaccessmodification

# Flutter Framework
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Firebase
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# Google Play Billing (Facturación)
-keep class com.android.vending.billing.** { *; }
-keep class com.google.android.gms.internal.play_billing.** { *; }

# SQLite
-keep class com.tekartik.sqflite.** { *; }

# Google Mobile Ads
-keep class com.google.android.gms.ads.** { *; }

# ML Kit & CameraX (Mobile Scanner / QR)
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**

# Optimización de Bitmaps e Imágenes Nativa
-keep class android.graphics.Bitmap** { *; }
-dontwarn android.graphics.BitmapFactory**