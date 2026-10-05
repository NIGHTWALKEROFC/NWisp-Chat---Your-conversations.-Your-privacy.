import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'group_message_relay_service.dart';
import 'message_relay_service.dart';
import 'signal_session_service.dart';

/// The content of one poll. Stored as the text of a `poll` group message.
class PollData {
  final String question;
  final List<String> options;
  final bool multi;
  const PollData(this.question, this.options, this.multi);

  String toJson() => jsonEncode({'q': question, 'o': options, 'm': multi});

  static PollData? parse(String text) {
    try {
      final m = jsonDecode(text) as Map<String, dynamic>;
      final opts = (m['o'] as List).map((e) => e.toString()).toList();
      if (opts.length < 2) return null;
      return PollData((m['q'] as String?) ?? '', opts, m['m'] == true);
    } catch (_) {
      return null;
    }
  }
}

/// Feature: polls in groups.
///
/// A poll is a normal end-to-end-encrypted group message of type `poll`.
/// Every vote is a tiny encrypted `poll_vote` note sent to all members, and
/// each phone counts the votes it has received — nothing is kept on a server.
/// One vote per person; voting again changes it. A phone that was offline
/// catches up on votes when it comes back, like any other message.
class PollService {
  PollService._();
  static final instance = PollService._();

  static const _uuid = Uuid();

  /// Ticks whenever any vote changes, so poll bubbles redraw.
  final ValueNotifier<int> changes = ValueNotifier(0);

  String? _loadedFor;
  // pollId -> voterUid -> chosen option numbers
  Map<String, Map<String, List<int>>> _votes = {};

  String get _myUid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Not signed in.');
    return uid;
  }

  String get _prefKey => 'poll_votes_v1_$_myUid';

  Future<void> ensureLoaded() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _loadedFor == uid) return;
    _loadedFor = uid;
    _votes = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw != null) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((pollId, voters) {
          _votes[pollId] = {
            for (final e in (voters as Map<String, dynamic>).entries)
              e.key: (e.value as List).map((n) => (n as num).toInt()).toList(),
          };
        });
      }
    } catch (e) {
      debugPrint('PollService: could not read votes: $e');
    }
    changes.value++;
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(_votes));
    } catch (_) {}
    changes.value++;
  }

  /// Everyone's votes for one poll: voterUid -> option numbers.
  Map<String, List<int>> votesFor(String pollId) => _votes[pollId] ?? const {};

  List<int> myChoices(String pollId) => votesFor(pollId)[FirebaseAuth.instance.currentUser?.uid] ?? const [];

  Future<String> createPoll({
    required String groupId,
    required List<String> memberUids,
    required PollData poll,
    required int ttlHours,
  }) {
    return GroupMessageRelayService.sendGroupMessage(
      groupId: groupId,
      memberUids: memberUids,
      text: poll.toJson(),
      messageType: 'poll',
      ttlHours: ttlHours,
    );
  }

  /// Casts (or changes, or — with an empty list — withdraws) my vote.
  Future<void> vote({
    required String groupId,
    required List<String> memberUids,
    required String pollId,
    required List<int> choices,
  }) async {
    await ensureLoaded();
    final me = _myUid;
    final voters = _votes.putIfAbsent(pollId, () => {});
    if (choices.isEmpty) {
      voters.remove(me);
    } else {
      voters[me] = List<int>.of(choices);
    }
    await _save();

    final payload = jsonEncode({'ref': pollId, 'choices': choices});
    for (final uid in memberUids.where((u) => u != me)) {
      try {
        final (ciphertext, nonce) = await SignalSessionService.instance.encryptForPeer(uid, payload);
        await insertMessageRelayRow({
          'conversation_id': groupId,
          'sender_uid': me,
          'recipient_uid': uid,
          'ciphertext': ciphertext,
          'nonce': nonce,
          'message_type': 'poll_vote',
          'client_id': _uuid.v4(),
          'ttl_hours': 24,
        });
      } catch (e) {
        debugPrint('PollService: could not send vote to $uid: $e');
      }
    }
  }

  /// Called by MessageRelayService when someone else's vote arrives.
  Future<void> receiveVote({required String voterUid, required String payload}) async {
    await ensureLoaded();
    final m = jsonDecode(payload) as Map<String, dynamic>;
    final pollId = m['ref'] as String;
    final choices = (m['choices'] as List).map((n) => (n as num).toInt()).toList();
    final voters = _votes.putIfAbsent(pollId, () => {});
    if (choices.isEmpty) {
      voters.remove(voterUid);
    } else {
      voters[voterUid] = choices;
    }
    await _save();
  }

  /// For the encrypted backup.
  Future<Map<String, Map<String, List<int>>>> exportVotes() async {
    await ensureLoaded();
    return {for (final e in _votes.entries) e.key: {for (final v in e.value.entries) v.key: List<int>.of(v.value)}};
  }

  Future<void> importVotes(Map<String, dynamic> data) async {
    await ensureLoaded();
    data.forEach((pollId, voters) {
      final m = _votes.putIfAbsent(pollId, () => {});
      (voters as Map<String, dynamic>).forEach((uid, list) {
        m.putIfAbsent(uid, () => (list as List).map((n) => (n as num).toInt()).toList());
      });
    });
    await _save();
  }

  /// A poll message was deleted — forget its votes too.
  Future<void> forget(String pollId) async {
    await ensureLoaded();
    if (_votes.remove(pollId) != null) await _save();
  }

  void resetMemory() {
    _loadedFor = null;
    _votes = {};
  }
}
