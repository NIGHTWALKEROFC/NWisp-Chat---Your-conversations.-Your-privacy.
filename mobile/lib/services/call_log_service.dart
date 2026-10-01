import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'local_message_store.dart';

/// Feature: call history lines inside chats ("Missed voice call",
/// "Voice call · 02:31" …). Each phone writes its own line into its own local
/// chat — nothing is sent through the message relay, so it costs nothing and
/// leaks nothing.
class CallLogService {
  CallLogService._();
  static final instance = CallLogService._();

  static const _doneKey = 'call_log_done_v1';

  static String mmss(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  Future<bool> _firstTime(String key) async {
    final p = await SharedPreferences.getInstance();
    final done = p.getStringList(_doneKey) ?? <String>[];
    if (done.contains(key)) return false;
    done.add(key);
    if (done.length > 300) done.removeRange(0, done.length - 300);
    await p.setStringList(_doneKey, done);
    return true;
  }

  /// A line in a 1:1 chat.
  Future<void> logDirect({
    required String callId,
    required String conversationId,
    required String peerUid,
    required bool outgoing,
    required String text,
    DateTime? at,
  }) async {
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me == null || conversationId.isEmpty) return;
    if (!await _firstTime('d_$callId')) return;
    try {
      await LocalMessageStore.insert(
        id: 'calllog_${callId}_$me',
        conversationId: conversationId,
        peerUid: peerUid,
        senderUid: outgoing ? me : peerUid,
        isMine: outgoing,
        text: '📞 $text',
        status: outgoing ? 'sent' : 'delivered',
        createdAt: at ?? DateTime.now(),
      );
    } catch (_) {}
  }

  /// A line in a group chat.
  Future<void> logGroup({
    required String callId,
    required String groupId,
    required String starterUid,
    required String text,
    DateTime? at,
  }) async {
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me == null) return;
    if (!await _firstTime('g_${callId}_$text')) return;
    final mine = starterUid == me;
    try {
      await LocalMessageStore.insert(
        id: 'calllog_${callId}_${text.hashCode}_$me',
        conversationId: groupId,
        // Group rows: peer_uid is always the sender (see LocalMessageStore).
        peerUid: mine ? me : starterUid,
        senderUid: mine ? me : starterUid,
        isMine: mine,
        text: '📞 $text',
        status: mine ? 'sent' : 'delivered',
        createdAt: at ?? DateTime.now(),
      );
    } catch (_) {}
  }

  /// Calls that rang while this phone had NWisp closed: the caller marks them
  /// "missed", and the next time NWisp opens we turn each into a chat line
  /// and tidy the record away.
  Future<void> syncMissed() async {
    final me = FirebaseAuth.instance.currentUser?.uid;
    if (me == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('calls')
          .where('calleeUid', isEqualTo: me)
          .where('status', isEqualTo: 'missed')
          .get();
      for (final d in snap.docs) {
        final data = d.data();
        await logDirect(
          callId: d.id,
          conversationId: (data['conversationId'] as String?) ?? '',
          peerUid: data['callerUid'] as String,
          outgoing: false,
          text: 'Missed voice call',
          at: (data['createdAt'] as Timestamp?)?.toDate(),
        );
        try {
          await d.reference.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
