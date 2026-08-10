import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Web is not configured for this app.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError('Unsupported platform.');
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyA4_QHFNvRDCX7OMG990N5_jbbUF4FGx38',
    appId: '1:39179591297:android:ac003ce4e627e4639bb780',
    messagingSenderId: '39179591297',
    projectId: 'nwisp-c2f49',
    storageBucket: 'nwisp-c2f49.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDjGyLD_CuTcv16LF2Y7uZ-gq8Ab0Uj_5s',
    appId: '1:39179591297:ios:201c6062555a40be9bb780',
    messagingSenderId: '39179591297',
    projectId: 'nwisp-c2f49',
    storageBucket: 'nwisp-c2f49.firebasestorage.app',
    iosBundleId: 'com.nightwalker.securechat',
  );
}
