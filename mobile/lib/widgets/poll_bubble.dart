import 'package:flutter/material.dart';
import '../services/poll_service.dart';

/// The poll inside a group chat bubble: question, options with live bars,
/// tap to vote, and a "who voted" list.
class PollBubble extends StatefulWidget {
  final String pollId;
  final String text;
  final bool isMine;
  final String Function(String uid) nameFor;
  final Future<void> Function(List<int> choices) onVote;

  const PollBubble({
    super.key,
    required this.pollId,
    required this.text,
    required this.isMine,
    required this.nameFor,
    required this.onVote,
  });

  @override
  State<PollBubble> createState() => _PollBubbleState();
}

class _PollBubbleState extends State<PollBubble> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    PollService.instance.ensureLoaded();
  }

  Future<void> _tap(PollData poll, int index) async {
    if (_busy) return;
    final mine = List<int>.of(PollService.instance.myChoices(widget.pollId));
    if (poll.multi) {
      mine.contains(index) ? mine.remove(index) : mine.add(index);
    } else {
      if (mine.length == 1 && mine.first == index) {
        mine.clear(); // tap again to withdraw
      } else {
        mine
          ..clear()
          ..add(index);
      }
    }
    setState(() => _busy = true);
    try {
      await widget.onVote(mine);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Couldn't send your vote — check your connection.")));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showVoters(PollData poll) {
    final votes = PollService.instance.votesFor(widget.pollId);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              Text(poll.question, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 12),
              for (var i = 0; i < poll.options.length; i++) ...[
                Builder(builder: (_) {
                  final who = votes.entries.where((e) => e.value.contains(i)).map((e) => widget.nameFor(e.key)).toList();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${poll.options[i]}  ·  ${who.length}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(who.isEmpty ? 'No votes' : who.join(', '), style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 14),
                    ],
                  );
                }),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final poll = PollData.parse(widget.text);
    final fg = widget.isMine ? scheme.onPrimary : scheme.onSurface;
    if (poll == null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text('Poll unavailable', style: TextStyle(color: fg)),
      );
    }
    return ValueListenableBuilder<int>(
      valueListenable: PollService.instance.changes,
      builder: (context, _, __) {
        final votes = PollService.instance.votesFor(widget.pollId);
        final counts = List<int>.filled(poll.options.length, 0);
        for (final choice in votes.values) {
          for (final c in choice) {
            if (c >= 0 && c < counts.length) counts[c]++;
          }
        }
        final voters = votes.length;
        final mine = PollService.instance.myChoices(widget.pollId);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Icon(Icons.poll_outlined, size: 18, color: fg),
                const SizedBox(width: 6),
                Text(poll.multi ? 'Poll · pick several' : 'Poll', style: TextStyle(fontSize: 11.5, color: fg.withValues(alpha: 0.75))),
              ]),
              const SizedBox(height: 6),
              Text(poll.question, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5, color: fg)),
              const SizedBox(height: 10),
              for (var i = 0; i < poll.options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _tap(poll, i),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(
                            mine.contains(i)
                                ? (poll.multi ? Icons.check_box : Icons.radio_button_checked)
                                : (poll.multi ? Icons.check_box_outline_blank : Icons.radio_button_unchecked),
                            size: 20,
                            color: fg,
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(poll.options[i], style: TextStyle(color: fg))),
                          Text('${counts[i]}', style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
                        ]),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            minHeight: 5,
                            value: voters == 0 ? 0 : counts[i] / voters,
                            backgroundColor: fg.withValues(alpha: 0.18),
                            valueColor: AlwaysStoppedAnimation(fg.withValues(alpha: 0.9)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Row(children: [
                Text('$voters ${voters == 1 ? 'vote' : 'votes'}', style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.75))),
                const Spacer(),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: fg, padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: const Size(0, 28)),
                  onPressed: () => _showVoters(poll),
                  child: const Text('Who voted', style: TextStyle(fontSize: 12.5)),
                ),
              ]),
            ],
          ),
        );
      },
    );
  }
}

/// Full-screen "New poll" page. Returns the poll to send, or null.
Future<PollData?> showCreatePoll(BuildContext context) {
  return Navigator.of(context).push<PollData>(MaterialPageRoute(builder: (_) => const _CreatePollScreen()));
}

class _CreatePollScreen extends StatefulWidget {
  const _CreatePollScreen();

  @override
  State<_CreatePollScreen> createState() => _CreatePollScreenState();
}

class _CreatePollScreenState extends State<_CreatePollScreen> {
  final _question = TextEditingController();
  final List<TextEditingController> _options = [TextEditingController(), TextEditingController()];
  bool _multi = false;
  static const _maxOptions = 8;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _filled => _options.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
  bool get _valid => _question.text.trim().isNotEmpty && _filled.length >= 2 && _filled.toSet().length == _filled.length;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New poll'),
        actions: [
          TextButton(
            onPressed: _valid ? () => Navigator.pop(context, PollData(_question.text.trim(), _filled, _multi)) : null,
            child: const Text('Send'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _question,
            maxLength: 200,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Question', prefixIcon: Icon(Icons.help_outline)),
          ),
          const SizedBox(height: 8),
          Text('Options', style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (var i = 0; i < _options.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: _options[i],
                maxLength: 100,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Option ${i + 1}',
                  counterText: '',
                  suffixIcon: _options.length > 2
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _options.removeAt(i).dispose()),
                        )
                      : null,
                ),
              ),
            ),
          if (_options.length < _maxOptions)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _options.add(TextEditingController())),
                icon: const Icon(Icons.add),
                label: const Text('Add option'),
              ),
            ),
          if (_filled.toSet().length != _filled.length)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Each option must be different.', style: TextStyle(color: scheme.error, fontSize: 12.5)),
            ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow several answers'),
            subtitle: const Text('Members can pick more than one option'),
            value: _multi,
            onChanged: (v) => setState(() => _multi = v),
          ),
        ],
      ),
    );
  }
}
