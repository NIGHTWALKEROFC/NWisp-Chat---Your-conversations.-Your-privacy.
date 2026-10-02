import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class BotException implements Exception {
  final String message;
  final int status;
  BotException(this.message, [this.status = 0]);
  @override
  String toString() => message;
}

/// One switch on a bot's "Rules" page. Every rule starts OFF; the bot's owner
/// turns on what the bot needs. The server (nwisp-bot-api) enforces them.
class BotRuleInfo {
  final String key;
  final String title;
  final String subtitle;
  final IconData icon;
  const BotRuleInfo(this.key, this.title, this.subtitle, this.icon);
}

class BotCommand {
  final String command;
  final String description;
  const BotCommand(this.command, this.description);
}

class BotInfo {
  final String username;
  final String name;
  final String description;
  final String? photoData;
  final Map<String, bool> rules;
  final List<BotCommand> commands;
  final bool isOwner;
  final bool webhook;
  final bool blocked;
  /// active | suspended | banned (only ever shown to the bot's owner).
  final String status;
  final String? statusReason;
  const BotInfo({
    required this.username,
    required this.name,
    required this.description,
    required this.photoData,
    required this.rules,
    required this.commands,
    required this.isOwner,
    this.webhook = false,
    this.blocked = false,
    this.status = 'active',
    this.statusReason,
  });

  bool rule(String key) => rules[key] == true;

  factory BotInfo.fromJson(Map<String, dynamic> j) => BotInfo(
        username: j['username'] as String,
        name: (j['name'] as String?) ?? '',
        description: (j['description'] as String?) ?? '',
        photoData: j['photo_data'] as String?,
        rules: {for (final e in ((j['rules'] as Map?) ?? {}).entries) e.key as String: e.value == true},
        commands: [
          for (final c in (j['commands'] as List? ?? const []))
            BotCommand((c as Map)['command'] as String, (c['description'] as String?) ?? ''),
        ],
        isOwner: j['isOwner'] == true,
        webhook: j['webhook'] == true,
        blocked: j['blocked'] == true,
        status: (j['status'] as String?) ?? 'active',
        statusReason: j['statusReason'] as String?,
      );

  BotInfo copyWith({bool? blocked, List<BotCommand>? commands}) => BotInfo(
        username: username,
        name: name,
        description: description,
        photoData: photoData,
        rules: rules,
        commands: commands ?? this.commands,
        isOwner: isOwner,
        webhook: webhook,
        blocked: blocked ?? this.blocked,
        status: status,
        statusReason: statusReason,
      );
}

class BotMessage {
  final int id;
  final bool fromBot; // false = sent by me
  final String kind; // text | photo | callback
  String body;
  Map<String, dynamic> extra;
  bool edited;
  bool deleted;
  final DateTime createdAt;
  /// Group rooms only: who wrote it.
  final String userUid;
  BotMessage({
    required this.id,
    required this.fromBot,
    required this.kind,
    required this.body,
    required this.extra,
    required this.edited,
    required this.deleted,
    required this.createdAt,
    this.userUid = '',
  });

  bool get isSystem => kind == 'system';
  String get senderName => (extra['name'] as String?) ?? '';

  factory BotMessage.fromJson(Map<String, dynamic> j) => BotMessage(
        id: (j['id'] as num).toInt(),
        fromBot: j['direction'] == 'out',
        kind: (j['kind'] as String?) ?? 'text',
        body: (j['body'] as String?) ?? '',
        extra: Map<String, dynamic>.from((j['extra'] as Map?) ?? {}),
        edited: j['edited'] == true,
        deleted: j['deleted'] == true,
        createdAt: DateTime.tryParse((j['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
        userUid: (j['user_uid'] as String?) ?? '',
      );
}

/// One bot that has reports waiting for an admin.
class BotReportItem {
  final String username;
  final String name;
  final String status;
  final String? statusReason;
  final int count;
  final Map<String, int> reasons;
  final List<String> details;
  BotReportItem({
    required this.username,
    required this.name,
    required this.status,
    required this.statusReason,
    required this.count,
    required this.reasons,
    required this.details,
  });
  factory BotReportItem.fromJson(Map<String, dynamic> j) => BotReportItem(
        username: j['username'] as String,
        name: (j['name'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'active',
        statusReason: j['status_reason'] as String?,
        count: (j['count'] as num?)?.toInt() ?? 0,
        reasons: {for (final e in ((j['reasons'] as Map?) ?? {}).entries) e.key as String: (e.value as num).toInt()},
        details: [for (final d in (j['details'] as List? ?? const [])) d as String],
      );
}

class BotPollResult {
  final List<BotMessage> messages;
  final bool typing;
  final String serverTime;
  BotPollResult(this.messages, this.typing, this.serverTime);
}

/// Talks to the nwisp-bot-manage Edge Function (see supabase/functions).
/// Nothing in here ever sees a bot's API key except right after creating the
/// bot or generating a new one.
class BotService {
  BotService._();
  static final instance = BotService._();

  static const rules = <BotRuleInfo>[
    BotRuleInfo('public', 'Open to everyone',
        'Anyone can find and start this bot. Off = only you can use it (good for testing).', Icons.public),
    BotRuleInfo('shareUsername', 'See usernames',
        "The bot sees each person's NWisp username. Off = people stay anonymous to the bot.", Icons.badge_outlined),
    BotRuleInfo('buttons', 'Buttons',
        'Bot messages can carry tap-able buttons (and receive the taps).', Icons.smart_button_outlined),
    BotRuleInfo('media', 'Send photos', 'The bot can send photos (as links to images).', Icons.image_outlined),
    BotRuleInfo('formatting', 'Text formatting', '**bold**, _italic_ and `code` in bot messages.', Icons.format_bold),
    BotRuleInfo('editDelete', 'Edit & delete', 'The bot can edit or delete its own messages.', Icons.edit_note_outlined),
    BotRuleInfo('typing', 'Typing indicator', 'The bot can show "typing…" while it works.', Icons.more_horiz),
    BotRuleInfo('webhook', 'Webhook delivery',
        'New messages are pushed to your own server. Off = your bot fetches them with getUpdates.', Icons.webhook_outlined),
    BotRuleInfo('commandsMenu', 'Command menu', 'Show the "/" list of commands your bot sets.', Icons.terminal),
    BotRuleInfo('longMessages', 'Long messages', 'Up to 4000 characters per message (otherwise 1000).', Icons.notes),
    BotRuleInfo('groups', 'Allowed in groups',
        'Group admins can add this bot to a group. It gets a shared bot room that every member can use.', Icons.groups_outlined),
    BotRuleInfo('seeAllMessages', 'Read all group messages',
        'In groups the bot sees every message. Off = it only sees /commands, @mentions of the bot and replies to the bot.', Icons.visibility_outlined),
  ];

  static const reportReasons = <String, String>{
    'spam': 'Spam',
    'scam': 'Scam or fraud',
    'abuse': 'Harassment or abuse',
    'illegal': 'Illegal content',
    'impersonation': 'Pretends to be someone else',
    'other': 'Something else',
  };

  static String get functionsBase => '${const String.fromEnvironment('SUPABASE_URL')}/functions/v1';
  static String get apiBase => '$functionsBase/nwisp-bot-api';

  static final RegExp _baseFormat = RegExp(r'^[a-z0-9]([a-z0-9_]*[a-z0-9])?$');

  /// Local check of what is typed before "_bot".
  static String? validateBase(String base) {
    if (base.length < 3) return 'At least 3 characters before _bot';
    if (base.length > 28) return 'At most 28 characters before _bot';
    if (!_baseFormat.hasMatch(base)) {
      return base.endsWith('_')
          ? "Can't end with an underscore (a double underscore is for normal accounts)"
          : 'Lowercase letters, numbers and underscores — start with a letter or number';
    }
    return null;
  }

  Future<Map<String, dynamic>> _call(String action, Map<String, dynamic> body) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw BotException('Please sign in again.');
    final token = await user.getIdToken();
    http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('$functionsBase/nwisp-bot-manage'),
            headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
            body: jsonEncode({'action': action, ...body}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw BotException('No connection. Check your internet and try again.');
    }
    Map<String, dynamic> data;
    try {
      data = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw BotException('The bot service is not set up yet (status ${res.statusCode}).', res.statusCode);
    }
    if (res.statusCode >= 300 || data['error'] != null) {
      throw BotException((data['error'] as String?) ?? 'Something went wrong.', res.statusCode);
    }
    return data;
  }

  /// null = couldn't check; otherwise (valid, available, reason).
  Future<({bool valid, bool available, String? reason})?> checkUsername(String full) async {
    try {
      final d = await _call('check_username', {'username': full});
      return (valid: d['valid'] == true, available: d['available'] == true, reason: d['reason'] as String?);
    } catch (_) {
      return null;
    }
  }

  Future<({BotInfo bot, String token})> createBot({
    required String username,
    required String name,
    required String description,
    String? photoData,
    required Map<String, bool> rules,
  }) async {
    final d = await _call('create_bot', {
      'username': username,
      'name': name,
      'description': description,
      'photo_data': photoData,
      'rules': rules,
    });
    return (bot: BotInfo.fromJson(d['bot'] as Map<String, dynamic>), token: d['token'] as String);
  }

  Future<List<BotInfo>> listMine() async {
    final d = await _call('list_mine', {});
    return [for (final b in (d['bots'] as List)) BotInfo.fromJson(b as Map<String, dynamic>)];
  }

  Future<BotInfo> updateBot(String username, {String? name, String? description, Map<String, bool>? rules, Object? photoData = _keep}) async {
    final body = <String, dynamic>{'username': username};
    if (name != null) body['name'] = name;
    if (description != null) body['description'] = description;
    if (rules != null) body['rules'] = rules;
    if (!identical(photoData, _keep)) body['photo_data'] = photoData;
    final d = await _call('update_bot', body);
    return BotInfo.fromJson(d['bot'] as Map<String, dynamic>);
  }

  static const Object _keep = Object();

  Future<void> deleteBot(String username) => _call('delete_bot', {'username': username});

  Future<String> regenerateToken(String username) async =>
      (await _call('regenerate_token', {'username': username}))['token'] as String;

  /// (bot, reason). reason is 'private' / 'not_found' when bot is null.
  Future<({BotInfo? bot, String? reason})> getBot(String username) async {
    final d = await _call('get_bot', {'username': username});
    final b = d['bot'];
    return (bot: b == null ? null : BotInfo.fromJson(b as Map<String, dynamic>), reason: d['reason'] as String?);
  }

  Future<List<BotInfo>> myChats() async {
    final d = await _call('my_chats', {});
    return [for (final b in (d['bots'] as List)) BotInfo.fromJson(b as Map<String, dynamic>)];
  }

  Future<int> send(String username, String text, {String? fromName}) async {
    final d = await _call('send', {'username': username, 'text': text, if (fromName != null) 'fromName': fromName});
    return (d['id'] as num).toInt();
  }

  Future<int> sendCallback(String username, String data, int messageId) async {
    final d = await _call('callback', {'username': username, 'data': data, 'messageId': messageId});
    return (d['id'] as num).toInt();
  }

  Future<BotPollResult> poll(String username, {bool history = false, int afterId = 0, String? since, int waitSeconds = 0}) async {
    final d = await _call('poll', {
      'username': username,
      'history': history,
      'afterId': afterId,
      if (since != null) 'since': since,
      'waitSeconds': waitSeconds,
    });
    return BotPollResult(
      [for (final m in (d['messages'] as List)) BotMessage.fromJson(m as Map<String, dynamic>)],
      d['typing'] == true,
      (d['serverTime'] as String?) ?? DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> setBlocked(String username, bool blocked) => _call('block', {'username': username, 'blocked': blocked});
  Future<void> clearChat(String username) => _call('clear_chat', {'username': username});

  // ------------------------------------------------------------ reports & admin
  Future<void> report(String username, String reason, {String details = ''}) =>
      _call('report_bot', {'username': username, 'reason': reason, 'details': details});

  Future<bool> isAdmin() async {
    try {
      return (await _call('whoami', {}))['isAdmin'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<BotReportItem>> adminReports() async {
    final d = await _call('admin_reports', {});
    return [for (final i in (d['items'] as List)) BotReportItem.fromJson(i as Map<String, dynamic>)];
  }

  Future<void> adminSetStatus(String username, String status, {String reason = ''}) =>
      _call('admin_set_status', {'username': username, 'status': status, 'reason': reason});

  Future<void> adminDismiss(String username) => _call('admin_dismiss', {'username': username});

  // ------------------------------------------------------------ command menu
  Future<List<BotCommand>> setCommands(String username, List<BotCommand> commands) async {
    final d = await _call('set_commands', {
      'username': username,
      'commands': [for (final c in commands) {'command': c.command, 'description': c.description}],
    });
    return [
      for (final c in (d['commands'] as List? ?? const []))
        BotCommand((c as Map)['command'] as String, (c['description'] as String?) ?? ''),
    ];
  }

  // ------------------------------------------------------------ bots in groups
  Future<List<BotInfo>> groupBots(String groupId) async {
    final d = await _call('group_list_bots', {'groupId': groupId});
    return [for (final b in (d['bots'] as List)) BotInfo.fromJson(b as Map<String, dynamic>)];
  }

  Future<void> groupAddBot(String groupId, String username) => _call('group_add_bot', {'groupId': groupId, 'username': username});
  Future<void> groupRemoveBot(String groupId, String username) => _call('group_remove_bot', {'groupId': groupId, 'username': username});

  /// Returns (id, seenByBot).
  Future<({int id, bool seenByBot})> groupSend(String groupId, String username, String text, {int? replyTo}) async {
    final d = await _call('group_send', {'groupId': groupId, 'username': username, 'text': text, if (replyTo != null) 'replyTo': replyTo});
    return (id: (d['id'] as num).toInt(), seenByBot: d['seenByBot'] == true);
  }

  Future<BotPollResult> groupPoll(String groupId, String username, {bool history = false, int afterId = 0, String? since, int waitSeconds = 0}) async {
    final d = await _call('group_poll', {
      'groupId': groupId,
      'username': username,
      'history': history,
      'afterId': afterId,
      if (since != null) 'since': since,
      'waitSeconds': waitSeconds,
    });
    return BotPollResult(
      [for (final m in (d['messages'] as List)) BotMessage.fromJson(m as Map<String, dynamic>)],
      false,
      (d['serverTime'] as String?) ?? DateTime.now().toUtc().toIso8601String(),
    );
  }
}
