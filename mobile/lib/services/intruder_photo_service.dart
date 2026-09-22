import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'media_vault_service.dart';

/// What the owner is told after their next real unlock.
class IntruderNotice {
  final int wrongAttempts;
  final int photosSaved;
  const IntruderNotice({required this.wrongAttempts, required this.photosSaved});
}

/// Feature: Intruder photo. After N wrong app-lock PINs in a row, the FRONT
/// camera quietly takes a photo and puts it in the Media vault (labelled
/// "Intruder" with the time). OFF by default; switched on in Settings >
/// Security > Intruder photo. Everything happens on this phone — no server.
///
/// HOW IT WORKS
///  * The lock screen calls [onWrongPin] for every wrong app PIN. The
///    running count is saved on the phone, so closing and reopening the app
///    can't reset it; it is cleared only by a correct unlock ([onRealUnlock]).
///  * On every Nth wrong PIN a photo is taken — at most [_maxPhotosPerStreak]
///    per streak, so a long guessing session can't fill the vault.
///  * The camera permission is asked for when the feature is switched ON (see
///    [prepare]) and never at the lock screen, where a permission pop-up
///    would tip the intruder off.
///  * The photo goes into the vault, so it is protected by the vault's own
///    PIN — someone who guessed the app PIN can't open it. The vault must be
///    set up first.
///
/// HONEST LIMITS: some phones refuse to take a photo without a visible
/// camera preview, and none of this works if the app is in the background.
/// The "Test it now" button exists so you can check your own phone.
class IntruderPhotoService {
  IntruderPhotoService._();
  static final instance = IntruderPhotoService._();

  static const _kEnabled = 'intruder_photo_enabled';
  static const _kThreshold = 'intruder_photo_threshold';
  static const _kWrongCount = 'intruder_wrong_count';
  static const _kPhotosThisStreak = 'intruder_photos_streak';
  static const _maxPhotosPerStreak = 5;

  /// How many wrong PINs in a row trigger a photo.
  static const List<int> thresholdOptions = [1, 2, 3, 5];
  static const int defaultThreshold = 3;

  bool _capturing = false;

  Future<bool> isEnabled() async => (await SharedPreferences.getInstance()).getBool(_kEnabled) ?? false;

  Future<int> getThreshold() async {
    final v = (await SharedPreferences.getInstance()).getInt(_kThreshold) ?? defaultThreshold;
    return thresholdOptions.contains(v) ? v : defaultThreshold;
  }

  Future<void> setThreshold(int n) async => (await SharedPreferences.getInstance()).setInt(_kThreshold, n);

  Future<void> setEnabled(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, on);
    if (!on) {
      await prefs.remove(_kWrongCount);
      await prefs.remove(_kPhotosThisStreak);
    }
  }

  /// Called by the lock screen for every wrong PIN. Never throws, and never
  /// delays the "Incorrect PIN" message — the photo is taken in the
  /// background.
  Future<void> onWrongPin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(_kEnabled) ?? false)) return;
      final count = (prefs.getInt(_kWrongCount) ?? 0) + 1;
      await prefs.setInt(_kWrongCount, count);
      final threshold = await getThreshold();
      final photos = prefs.getInt(_kPhotosThisStreak) ?? 0;
      if (count % threshold != 0 || photos >= _maxPhotosPerStreak) return;
      unawaited(_captureForStreak());
    } catch (_) {}
  }

  Future<void> _captureForStreak() async {
    final error = await _takePhoto();
    if (error != null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPhotosThisStreak, (prefs.getInt(_kPhotosThisStreak) ?? 0) + 1);
  }

  /// Called when the person gets in with the REAL PIN, fingerprint or the
  /// forgot-PIN flow. Clears the counters, and returns what happened while
  /// they were away (null if nothing worth telling them).
  Future<IntruderNotice?> onRealUnlock() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final wrong = prefs.getInt(_kWrongCount) ?? 0;
      final photos = prefs.getInt(_kPhotosThisStreak) ?? 0;
      await prefs.remove(_kWrongCount);
      await prefs.remove(_kPhotosThisStreak);
      if (!(prefs.getBool(_kEnabled) ?? false) || photos == 0) return null;
      return IntruderNotice(wrongAttempts: wrong, photosSaved: photos);
    } catch (_) {
      return null;
    }
  }

  /// Run when the feature is being switched on: checks the vault is ready and
  /// makes Android show the camera permission question NOW (with the person
  /// present), by opening the front camera for a moment. Returns null if all
  /// is well, or a plain-words problem.
  Future<String?> prepare() async {
    if (!await MediaVaultService.instance.isSetUp()) {
      return 'Set up your Media vault first — intruder photos are saved there, protected by the vault PIN.';
    }
    CameraController? controller;
    try {
      final front = await _frontCamera();
      if (front == null) return 'This phone has no front camera.';
      controller = CameraController(front, ResolutionPreset.low, enableAudio: false);
      await controller.initialize().timeout(const Duration(seconds: 10));
      return null;
    } on CameraException catch (e) {
      if (e.code.toLowerCase().contains('denied')) {
        return 'Camera permission was refused. Allow the camera for this app in your phone settings, then try again.';
      }
      return e.description ?? 'The camera could not be opened (${e.code}).';
    } on TimeoutException {
      return 'The camera took too long to open.';
    } catch (e) {
      return 'The camera could not be opened.';
    } finally {
      try {
        await controller?.dispose();
      } catch (_) {}
    }
  }

  /// The "Test it now" button: takes a photo exactly the way the lock screen
  /// would. Returns null on success (the photo is in the vault), or the
  /// reason it didn't work on this phone.
  Future<String?> testCapture() => _takePhoto();

  Future<CameraDescription?> _frontCamera() async {
    final cameras = await availableCameras();
    for (final c in cameras) {
      if (c.lensDirection == CameraLensDirection.front) return c;
    }
    return null;
  }

  /// Takes one silent front-camera photo (no preview widget is ever shown)
  /// and files it in the vault. Returns null on success, else a reason.
  Future<String?> _takePhoto() async {
    if (_capturing) return 'Already taking a photo.';
    _capturing = true;
    CameraController? controller;
    File? shot;
    try {
      final front = await _frontCamera();
      if (front == null) return 'This phone has no front camera.';
      controller = CameraController(front, ResolutionPreset.medium, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await controller.initialize().timeout(const Duration(seconds: 8));
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (_) {}
      final taken = await controller.takePicture().timeout(const Duration(seconds: 8));
      shot = File(taken.path);
      await MediaVaultService.instance.importFile(shot, isVideo: false, extension: '.jpg', origin: 'intruder');
      return null;
    } on CameraException catch (e) {
      return e.description ?? 'Camera error (${e.code}).';
    } on TimeoutException {
      return 'The camera took too long to respond.';
    } on StateError catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not take or save the photo.';
    } finally {
      _capturing = false;
      try {
        await controller?.dispose();
      } catch (_) {}
      try {
        if (shot != null && await shot.exists()) await shot.delete();
      } catch (_) {}
    }
  }
}
