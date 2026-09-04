import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'crypto_service.dart';
import 'local_message_store.dart';
import 'pin_service.dart';
import 'secure_storage_service.dart';
import 'signal_session_service.dart';

/// Account deletion, data export, and temporary self-disable ("deactivate").
///
/// Kept separate from AuthService (which owns day-to-day sign-in/settings)
/// because these three operations each reach into several OTHER services
/// (Supabase relay + Storage, the local SQLite store, the Signal Protocol
/// store) that AuthService itself has no reason to know about.
class AccountLifecycleService {
  static final _auth = FirebaseAuth.instance;
  static final _db = FirebaseFirestore.instance;

  static DocumentReference<Map<String, dynamic>> _profileRef(String uid) =>
      _db.collection('users').doc(uid).collection('private').doc('profile');

  // ---------------------------------------------------------------------
  // Temporary self-disable ("deactivate" — Instagram-style)
  // ---------------------------------------------------------------------

  /// 'active' (the default, including for every account that predates this
  /// field) or 'self_disabled'. Lives on the same private/profile doc as
  /// the rest of this account's private settings — a future admin-driven
  /// 'suspended' status (see the reporting/appeals feature) is expected to
  /// share this same field; this class only ever sets or reads the two
  /// values this feature needs and leaves that value alone otherwise.
  static Future<String> getAccountStatus() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return 'active';
    final snap = await _profileRef(uid).get();
    return (snap.data()?['accountStatus'] as String?) ?? 'active';
  }

  static Future<void> setSelfDisabled(bool disabled) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw Exception('No signed-in user');
    await _profileRef(uid).set({
      'accountStatus': disabled ? 'self_disabled' : 'active',
    }, SetOptions(merge: true));
  }

  // ---------------------------------------------------------------------
  // Data export
  // ---------------------------------------------------------------------

  /// Firestore Timestamps aren't directly JSON-encodable — convert every
  /// one found anywhere in the export to an ISO-8601 string first.
  static dynamic _stripTimestamps(dynamic value) {
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is Map) return value.map((k, v) => MapEntry(k.toString(), _stripTimestamps(v)));
    if (value is List) return value.map(_stripTimestamps).toList();
    return value;
  }

  static Future<File> _buildExportFile() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw Exception('No signed-in user');

    final userSnap = await _db.collection('users').doc(uid).get();
    final profileSnap = await _profileRef(uid).get();
    final presenceSnap =
        await _db.collection('users').doc(uid).collection('private').doc('presence').get();

    // fcmTokens are per-device push identifiers, not user content or
    // account settings — leave them out of a "my data" export.
    final privateSettings = Map<String, dynamic>.from(profileSnap.data() ?? {})
      ..remove('fcmTokens');

    final export = {
      'exportedAt': DateTime.now().toIso8601String(),
      'account': {
        'uid': uid,
        'email': _auth.currentUser?.email,
      },
      'profile': userSnap.data(),
      'privateSettings': privateSettings,
      'presence': presenceSnap.data(),
    };

    final clean = _stripTimestamps(export);
    final dir = await getTemporaryDirectory();
    final shortUid = uid.length > 8 ? uid.substring(0, 8) : uid;
    final file = File('${dir.path}/nwisp_data_export_$shortUid.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(clean));
    return file;
  }

  /// Builds the export file client-side (no backend cost) and hands it to
  /// the OS share sheet so the person can save it wherever they like or
  /// send it to themselves.
  static Future<void> exportAndShareUserData() async {
    final file = await _buildExportFile();
    await Share.shareXFiles([XFile(file.path)], text: 'NWisp data export');
  }

  // ---------------------------------------------------------------------
  // Account deletion
  // ---------------------------------------------------------------------

  /// Irreversible. Order matters: every step below (Supabase, Storage,
  /// Firestore) still needs a live, signed-in session to be allowed at
  /// all — by Supabase's anon-key access and by firestore.rules'
  /// isOwner() checks respectively — so `user.delete()` runs LAST, once
  /// nothing else still needs that session.
  ///
  /// Known, accepted gaps — none of these leave message CONTENT behind,
  /// only metadata that either can't be removed under the current
  /// firestore.rules, or belongs to someone else's document, not this
  /// account's:
  ///  - `users/{uid}/private/session/history/*` (the login-activity log)
  ///    is an intentionally append-only audit trail (`allow delete: if
  ///    false`) and cannot be deleted by the client. It holds only login
  ///    timestamps/device ids, never message content.
  ///  - Groups this account owned or belonged to are NOT deleted or
  ///    re-owned — their `members`/`admins` arrays keep listing this uid,
  ///    but since the Firebase Auth account is gone, nothing can ever
  ///    authenticate as this uid again to exploit that.
  ///  - `contactRequests` / `groupInviteRequests` / block docs that
  ///    OTHER people created referencing this uid are their documents,
  ///    not this account's, and are left alone.
  static Future<void> deleteAccount(String password) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('No signed-in user');
    final uid = user.uid;

    // Firebase refuses to delete an account without a recent sign-in —
    // reauthenticate up front instead of letting a stale session surface
    // a confusing "requires recent login" error partway through cleanup.
    if (user.email != null) {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: user.email!, password: password),
      );
    }

    final userRef = _db.collection('users').doc(uid);
    final userSnap = await userRef.get();
    final usernameLower = userSnap.data()?['usernameLower'] as String?;

    // 1) Supabase: drop every message_relay row this account is party to.
    // Best-effort — a row this fails to remove either purges itself once
    // the recipient's device processes it, or now has no live account to
    // ever be delivered to; either way it doesn't block account deletion.
    try {
      final client = Supabase.instance.client;
      await client.from('message_relay').delete().eq('sender_uid', uid);
      await client.from('message_relay').delete().eq('recipient_uid', uid);
    } catch (_) {}

    // 2) Supabase Storage: this account's avatar, if it ever set one.
    try {
      await Supabase.instance.client.storage.from('avatars').remove(['avatars/$uid.jpg']);
    } catch (_) {}

    // 3) Firestore: the single-doc pieces this account owns, in one batch.
    final batch = _db.batch();
    batch.delete(userRef.collection('private').doc('profile'));
    batch.delete(userRef.collection('private').doc('presence'));
    batch.delete(userRef.collection('private').doc('session'));
    batch.delete(userRef.collection('signal').doc('bundle'));
    batch.delete(userRef);
    // Frees the username for reuse — requires the matching firestore.rules
    // change (a username reservation's own owner may now delete it; see
    // firestore.rules) since usernames/{name} previously disallowed
    // delete entirely.
    if (usernameLower != null && usernameLower.isNotEmpty) {
      batch.delete(_db.collection('usernames').doc(usernameLower));
    }
    await batch.commit();

    // Unbounded collections (one-time prekeys, this account's own block
    // entries, this account's stories) need their own queries rather than
    // a single delete — each is best-effort so one slow/failed cleanup
    // doesn't stop the rest of deletion.
    try {
      final prekeys =
          await userRef.collection('signal').doc('bundle').collection('oneTimePreKeys').get();
      for (final doc in prekeys.docs) {
        await doc.reference.delete();
      }
    } catch (_) {}
    try {
      final blocks = await _db.collection('blocks').where('blockerUid', isEqualTo: uid).get();
      for (final doc in blocks.docs) {
        await doc.reference.delete();
      }
    } catch (_) {}
    try {
      final stories = await _db.collection('stories').where('userId', isEqualTo: uid).get();
      for (final doc in stories.docs) {
        await doc.reference.delete();
      }
    } catch (_) {}

    // 4) Wipe every bit of this device's local state for this account —
    // the same set of calls SessionService already runs when a DIFFERENT
    // account signs in on this device (see session_service.dart).
    await SecureStorageService.clearAll();
    CryptoService.clearInMemoryKeys();
    await LocalMessageStore.resetForNewUser();
    await PinService.clearAll();
    await SignalSessionService.instance.wipe();

    // 5) Finally, delete the Firebase Auth user itself. AuthGate's
    // authStateChanges listener picks this up and drops back to
    // LoginScreen automatically — nothing else needs to happen here.
    await user.delete();
  }
}
