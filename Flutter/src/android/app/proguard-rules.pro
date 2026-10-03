# OkHttp probes these optional TLS providers reflectively. Android does not
# bundle them, and their absence does not affect the platform TLS provider.
-dontwarn org.conscrypt.Conscrypt$Version
-dontwarn org.conscrypt.Conscrypt
-dontwarn org.conscrypt.ConscryptHostnameVerifier
-dontwarn org.openjsse.javax.net.ssl.SSLParameters
-dontwarn org.openjsse.javax.net.ssl.SSLSocket
-dontwarn org.openjsse.net.ssl.OpenJSSE

# The realtime ASR bridge resolves supported Tencent SDK signatures by
# reflection, so these shipped AAR classes must retain their names and members.
-keep class com.tencent.aai.** { *; }
-keep interface com.tencent.aai.** { *; }
