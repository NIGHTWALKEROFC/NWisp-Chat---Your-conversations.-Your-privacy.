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
    );
  }

  bool isAdmin(String uid) => admins.contains(uid);
  bool isOwner(String uid) => ownerId == uid;
  List<String> otherMembers(String myUid) => members.where((m) => m != myUid).toList();
}
