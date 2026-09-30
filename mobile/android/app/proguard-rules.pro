# Feature: voice calls — keep the WebRTC classes when the release build shrinks the app.
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**
