import 'package:cloud_firestore/cloud_firestore.dart';

/// Mirrors one `groups/{groupId}` Firestore document (see GroupService).
/// Group MEMBERSHIP lives here — group MESSAGE CONTENT never does (see
/// GroupMessageRelayService, which fans a message out through the same
/// Supabase `message_relay` table 1:1 chat uses, one encrypted copy per
/// member, using the Double Ratchet sessions from Phase 5).
class Group {
  final String id;
  final String name;
  final String? avatarUrl;
  final String ownerId;
  final List<String> admins;
  final List<String> members;
  final DateTime createdAt;
  final int? chatTtlHours;

  /// Short shared context for the group ("what this chat is for") — set
  /// and edited by admins only (see GroupService.updateDescription),
  /// visible to every member. Empty string, not null, when unset — same
  /// convention `name` already uses.
  final String description;

  /// Feature: group security setting. When true, only admins can send
  /// messages — everyone else can still read and react, same as
  /// Telegram/WhatsApp's own "only admins can send" toggle. Defaults to
  /// false (missing) so every existing group keeps working exactly as
  /// before. See GroupService.setOnlyAdminsCanSend and GroupChatScreen's
  /// input-bar gating.
  final bool onlyAdminsCanSend;

  /// Group security settings added 2026-09-10 — all default to their
  /// current always-on-before-this behavior, so an existing group with
  /// none of these fields set keeps working exactly as it did before:
  final bool mediaAutoDownload; // default true — off means members must tap to fetch photos/videos
  final bool readReceiptsEnabled; // default true — off means no "seen by" tracking group-wide
  final bool hideMemberListFromNonAdmins; // default false

  /// Feature: "clear on exit" ephemeral view mode, group version.
  /// Admin-only to turn on/off (enforced by firestore.rules — same
  /// admin-only gate already covers every field on this whole document,
  /// see GroupService.setEphemeralViewEnabled). Default false. When true,
  /// each member's OWN device independently wipes ITS OWN local copy of
  /// this one group's messages when THEIR OWN GroupChatScreen closes —
  /// never a bulk clear of every member at once, and never anything
  /// besides this one groupId. See GroupChatScreen.dispose().
  final bool ephemeralViewEnabled;

  /// Feature: Community. True for a group that is ALSO listed publicly in
  /// the Community tab (its public listing lives in `communities/{id}` —
  /// see CommunityService). Anyone signed in can join an open community
  /// themselves, up to [maxMembers]. Missing = false, so every existing
  /// group is untouched.
  final bool isCommunity;

  /// Hard member cap for a community (each message is encrypted once per
  /// member, so this stays small on purpose). Enforced by firestore.rules.
  final int? maxMembers;

  /// People an admin removed AND banned from a community — they cannot
  /// join it again on their own (enforced by firestore.rules).
  final List<String> bannedUids;

  const Group({
    required this.id,
    required this.name,
    this.avatarUrl,
    required this.ownerId,
    required this.admins,
    required this.members,
    required this.createdAt,
    this.chatTtlHours,
    this.description = '',
    this.onlyAdminsCanSend = false,
    this.mediaAutoDownload = true,
    this.readReceiptsEnabled = true,
    this.hideMemberListFromNonAdmins = false,
    this.ephemeralViewEnabled = false,
    this.isCommunity = false,
    this.maxMembers,
    this.bannedUids = const [],
  });

  factory Group.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    return Group(
      id: doc.id,
      name: (data['name'] as String?) ?? 'Group',
      avatarUrl: data['avatarUrl'] as String?,
      ownerId: (data['ownerId'] as String?) ?? '',
      admins: List<String>.from(data['admins'] ?? []),
      members: List<String>.from(data['members'] ?? []),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      chatTtlHours: (data['chatTtlHours'] as num?)?.toInt(),
      description: (data['description'] as String?) ?? '',
      onlyAdminsCanSend: (data['onlyAdminsCanSend'] as bool?) ?? false,
      mediaAutoDownload: (data['mediaAutoDownload'] as bool?) ?? true,
      readReceiptsEnabled: (data['readReceiptsEnabled'] as bool?) ?? true,
      hideMemberListFromNonAdmins: (data['hideMemberListFromNonAdmins'] as bool?) ?? false,
      ephemeralViewEnabled: (data['ephemeralViewEnabled'] as bool?) ?? false,
      isCommunity: (data['isCommunity'] as bool?) ?? false,
      maxMembers: (data['maxMembers'] as num?)?.toInt(),
      bannedUids: List<String>.from(data['bannedUids'] ?? const []),
    );
  }

  bool isAdmin(String uid) => admins.contains(uid);
  bool isOwner(String uid) => ownerId == uid;
  List<String> otherMembers(String myUid) => members.where((m) => m != myUid).toList();
}
