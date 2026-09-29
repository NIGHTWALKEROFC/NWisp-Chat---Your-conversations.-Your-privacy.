import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

/// Inline play/pause + waveform scrubber for a voice message, played
/// directly from the local decrypted file (see
/// MessageRelayService._receiveMediaMessage / sendMediaMessage) — no
/// network access at playback time, same as images/video.
///
/// Feature: unified voice/media UI (chat + group). Previously
/// chat_detail_screen.dart had its own `_VoiceBubbleContent` (a plain
/// linear progress bar) and group_chat_screen.dart had its own, visually
/// nicer `_VoiceBubble` (a waveform made of bars). This widget is the one
/// canonical implementation both screens now use — built on the group
/// version's waveform look, since that was the better of the two designs.
class VoiceMessageBubble extends StatefulWidget {
  final String path;
  final bool isMine;
  const VoiceMessageBubble({super.key, required this.path, required this.isMine});

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  /// Playback speeds the little chip cycles through: 1x -> 1.5x -> 2x -> 1x.
  static const _speeds = [1.0, 1.5, 2.0];

  /// The speed last picked on ANY voice message, so if you listen to a
  /// string of them at 2x you don't have to tap it again on every one.
  /// Only lives until the app is closed — not saved anywhere.
  static double _lastSpeed = 1.0;

  final _player = AudioPlayer();
  double _speed = _lastSpeed;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  bool _loaded = false;
  late final List<double> _bars;

  @override
  void initState() {
    super.initState();
    // A stable pseudo-waveform derived from the file path's hash — purely
    // decorative (this app doesn't analyze real audio amplitude). It just
    // needs to look the same every time this exact message re-renders, not
    // represent the actual recorded waveform.
    final seed = widget.path.hashCode;
    _bars = List.generate(26, (i) {
      final v = ((seed >> (i % 20)) & 0xF) / 15.0;
      return 0.28 + v * 0.72;
    });
    _player.setFilePath(widget.path).then((d) {
      if (!mounted) return;
      // Applied after the file is loaded (setSpeed before that is ignored
      // on some phones). just_audio keeps the voice's pitch natural.
      if (_speed != 1.0) _player.setSpeed(_speed);
      setState(() {
        _duration = d ?? Duration.zero;
        _loaded = true;
      });
    }).catchError((_) {
      if (mounted) setState(() => _loaded = true); // show a disabled control rather than spin forever
    });
    _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _player.seek(Duration.zero);
        _player.pause();
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  void _cycleSpeed() {
    final next = _speeds[(_speeds.indexOf(_speed) + 1) % _speeds.length];
    setState(() => _speed = next);
    _lastSpeed = next;
    _player.setSpeed(next);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = widget.isMine ? scheme.onPrimary : scheme.onSurface;
    final dim = fg.withValues(alpha: 0.32);
    final total = _duration.inMilliseconds == 0 ? 1 : _duration.inMilliseconds;
    final progress = (_position.inMilliseconds / total).clamp(0.0, 1.0);
    final playedBars = (progress * _bars.length).round();

    return SizedBox(
      width: 240,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          StreamBuilder<PlayerState>(
            stream: _player.playerStateStream,
            builder: (context, snap) {
              final playing = snap.data?.playing ?? false;
              return InkWell(
                customBorder: const CircleBorder(),
                onTap: !_loaded ? null : () => playing ? _player.pause() : _player.play(),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: fg.withValues(alpha: 0.18), width: 1),
                ),
                  child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: fg, size: 20),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 22,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: List.generate(_bars.length, (i) {
                      final played = i < playedBars;
                      return Expanded(
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 0.8),
                          height: 22 * _bars[i],
                          decoration: BoxDecoration(color: played ? fg : dim, borderRadius: BorderRadius.circular(2)),
                        ),
                      );
                    }),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _fmt(_position.inMilliseconds > 0 ? _position : _duration),
                  style: TextStyle(fontSize: 10.5, color: fg.withValues(alpha: 0.75)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // Speed chip — tap to switch between 1x, 1.5x and 2x.
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: !_loaded ? null : _cycleSpeed,
            child: Container(
              width: 38,
              padding: const EdgeInsets.symmetric(vertical: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fg.withValues(alpha: _speed == 1.0 ? 0.12 : 0.28),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _speed == _speed.roundToDouble() ? '${_speed.toInt()}x' : '${_speed}x',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: fg),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
