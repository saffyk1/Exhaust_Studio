import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart' as fflog;

// ─────────────────────────────────────────────────────────────────────────────
// WaveformScreen
//
// Phase 1 — PROCESSING: runs the FFmpeg session, streams log output into an
//   animated bar-graph waveform.
// Phase 2 — PREVIEW: once FFmpeg succeeds, loads the output file into a
//   VideoPlayerController so the user can listen to the enhanced audio before
//   deciding whether to save or discard.
// ─────────────────────────────────────────────────────────────────────────────

class WaveformScreen extends StatefulWidget {
  final String inputPath;
  final String outputPath;
  final String filterChain;

  /// Called when the user taps "Save to Gallery" after previewing.
  final VoidCallback onComplete;

  /// Called if FFmpeg exits with a non-zero return code.
  final void Function(String error) onError;
  final void Function(String) onProcessed; // ← ADD THIS

  const WaveformScreen({
    super.key,
    required this.inputPath,
    required this.outputPath,
    required this.filterChain,
    required this.onComplete,
    required this.onError,
    required this.onProcessed,
  });

  @override
  State<WaveformScreen> createState() => _WaveformScreenState();
}

// ── Phase enum ────────────────────────────────────────────────────────────────
enum _Phase { processing, preview, saving }

class _WaveformScreenState extends State<WaveformScreen>
    with SingleTickerProviderStateMixin {
  static const int _barCount = 32;

  // ── Waveform state ────────────────────────────────────────────────────────
  final List<double> _bars = List.filled(_barCount, 0.02);
  double _progress = 0.0;
  String _logLine = 'Initialising session…';
  double _idlePhase = 0.0;

  // ── Phase ─────────────────────────────────────────────────────────────────
  _Phase _phase = _Phase.processing;

  // ── Preview player ────────────────────────────────────────────────────────
  VideoPlayerController? _previewCtrl;
  bool _previewPlaying = false;
  Duration _previewPosition = Duration.zero;
  Duration _previewDuration = Duration.zero;

  // ── Animation ticker ──────────────────────────────────────────────────────
  late AnimationController _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
    )..addListener(_onTick)
     ..repeat();

    _startSession();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _previewCtrl?.dispose();
    super.dispose();
  }

  // ── Idle waveform animation ───────────────────────────────────────────────

  void _onTick() {
    if (_phase != _Phase.processing || !mounted) return;
    setState(() {
      _idlePhase += 0.12;
      for (int i = 0; i < _barCount; i++) {
        final wave = (sin(_idlePhase + i * 0.4) + 1) / 2;
        _bars[i] = _bars[i] * 0.85 + wave * 0.15 * 0.4 + 0.02;
      }
    });
  }

  // ── FFmpeg log → bar amplitudes ───────────────────────────────────────────

  void _onLog(fflog.Log log) {
    final message = log.getMessage() ?? '';
    if (message.isEmpty) return;

    final timeMatch = RegExp(r'time=(\d+):(\d+):([\d.]+)').firstMatch(message);
    if (timeMatch != null) {
      final h = int.parse(timeMatch.group(1)!);
      final m = int.parse(timeMatch.group(2)!);
      final s = double.parse(timeMatch.group(3)!);
      final totalSecs = h * 3600 + m * 60 + s;
      if (mounted) {
        setState(() {
          _progress = min(0.98, totalSecs / 120.0);
          _logLine = message.trim().replaceAll(RegExp(r'\s+'), ' ');
        });
      }
    }
    _injectLogEnergy(message);
  }

  void _injectLogEnergy(String message) {
    if (!mounted) return;
    final bytes = message.codeUnits;
    setState(() {
      for (int i = 0; i < bytes.length && i < _barCount; i++) {
        final energy = (bytes[i] % 100) / 100.0;
        final barIdx = (i * _barCount ~/ max(bytes.length, 1)) % _barCount;
        _bars[barIdx] = max(_bars[barIdx], energy * 0.9 + 0.08);
      }
      for (int i = 0; i < _barCount; i++) {
        _bars[i] = (_bars[i] * 0.92).clamp(0.02, 1.0);
      }
    });
  }

  // ── Start FFmpeg session ───────────────────────────────────────────────────
  Future<void> _startSession() async {
    await FFmpegKit.executeWithArgumentsAsync(
      ['-y', '-i', widget.inputPath, '-c:v', 'copy', '-af', widget.filterChain, widget.outputPath],
          (session) async {
        final rc = await session.getReturnCode();
        if (!mounted) return;
        if (ReturnCode.isSuccess(rc)) {
          widget.onProcessed(widget.outputPath);
          await _initPreview();
        } else {
          final logs = await session.getAllLogsAsString();
          setState(() => _progress = 0.0);
          _ticker.stop();
          widget.onError(logs ?? 'Unknown FFmpeg error');
        }
      },
          (log) => _onLog(log),
    );
  }

  // ── Initialise preview player ─────────────────────────────────────────────

  Future<void> _initPreview() async {
    final ctrl = VideoPlayerController.file(File(widget.outputPath));
    await ctrl.initialize();
    ctrl.setLooping(false);

    ctrl.addListener(() {
      if (!mounted) return;
      setState(() {
        _previewPlaying = ctrl.value.isPlaying;
        _previewPosition = ctrl.value.position;
        _previewDuration = ctrl.value.duration;
      });
    });

    _previewDuration = ctrl.value.duration;

    _ticker.stop();

    if (!mounted) {
      ctrl.dispose();
      return;
    }

    setState(() {
      _previewCtrl = ctrl;
      _progress = 1.0;
      _logLine = 'Processing complete — preview ready';
      _phase = _Phase.preview;
    });
  }

  // ── Preview controls ──────────────────────────────────────────────────────

  void _togglePlay() {
    final ctrl = _previewCtrl;
    if (ctrl == null) return;
    if (ctrl.value.isPlaying) {
      ctrl.pause();
    } else {
      // Restart from beginning if finished
      if (ctrl.value.position >= ctrl.value.duration) {
        ctrl.seekTo(Duration.zero);
      }
      ctrl.play();
    }
  }

  void _seekTo(double fraction) {
    final ctrl = _previewCtrl;
    if (ctrl == null) return;
    final target = _previewDuration * fraction;
    ctrl.seekTo(target);
  }

  // ── Save / discard ────────────────────────────────────────────────────────

  Future<void> _save() async {
    setState(() => _phase = _Phase.saving);
    await _previewCtrl?.pause();
    widget.onComplete(); // triggers _saveToGallery in main.dart
  }

  void _discard() {
    _previewCtrl?.pause();
    // Delete the temp output file to free space
    try { File(widget.outputPath).deleteSync(); } catch (_) {}
    Navigator.pop(context);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isPreview  = _phase == _Phase.preview;
    final isSaving   = _phase == _Phase.saving;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        leading: isPreview
            ? IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF555555)),
                onPressed: _discard,
                tooltip: 'Discard and go back',
              )
            : const SizedBox.shrink(),
        title: Row(
          children: [
            const Icon(Icons.graphic_eq, color: Color(0xFFFF6B00), size: 18),
            const SizedBox(width: 8),
            Text(
              isPreview ? 'PREVIEW' : 'PROCESSING',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
                color: Color(0xFFFF6B00),
              ),
            ),
          ],
        ),
      ),
      body: isSaving
          ? _buildSavingOverlay()
          : isPreview
              ? _buildPreviewBody()
              : _buildProcessingBody(),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PROCESSING BODY
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildProcessingBody() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          _buildStatusLabel(),
          const SizedBox(height: 40),
          _buildWaveform(),
          const SizedBox(height: 32),
          _buildProgressBar(),
          const SizedBox(height: 20),
          _buildLogReadout(),
          const Spacer(),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PREVIEW BODY
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildPreviewBody() {
    final ctrl = _previewCtrl!;
    final totalSecs = _previewDuration.inSeconds.toDouble();
    final posSecs   = _previewPosition.inSeconds.toDouble();
    final fraction  = totalSecs > 0 ? (posSecs / totalSecs).clamp(0.0, 1.0) : 0.0;

    String _fmt(Duration d) {
      final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$m:$s';
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Ready badge ──────────────────────────────────────────────────
          Row(
            children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  color: const Color(0xFF00E676),
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(
                    color: const Color(0xFF00E676).withOpacity(0.5),
                    blurRadius: 8, spreadRadius: 2,
                  )],
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'ENHANCED — READY TO PREVIEW',
                style: TextStyle(
                  fontFamily: 'monospace', fontSize: 11,
                  fontWeight: FontWeight.w800, letterSpacing: 2.5,
                  color: Color(0xFF00E676),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Video player (shows poster frame; audio plays through speaker) ─
          AspectRatio(
            aspectRatio: ctrl.value.isInitialized
                ? ctrl.value.aspectRatio
                : 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ctrl.value.isInitialized
                      ? VideoPlayer(ctrl)
                      : Container(color: const Color(0xFF1A1A1A)),

                  // Play/pause overlay
                  GestureDetector(
                    onTap: _togglePlay,
                    child: AnimatedOpacity(
                      opacity: _previewPlaying ? 0.0 : 1.0,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        width: 64, height: 64,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFFFF6B00).withOpacity(0.6),
                            width: 1.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.play_arrow,
                          color: Color(0xFFFF6B00), size: 32,
                        ),
                      ),
                    ),
                  ),

                  // Tap anywhere to pause when playing
                  if (_previewPlaying)
                    GestureDetector(
                      onTap: _togglePlay,
                      child: Container(color: Colors.transparent),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // ── Seek bar ─────────────────────────────────────────────────────
          Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  activeTrackColor: const Color(0xFFFF6B00),
                  inactiveTrackColor: const Color(0xFF2A2A2A),
                  thumbColor: const Color(0xFFFFAA00),
                  overlayColor: const Color(0x22FF6B00),
                ),
                child: Slider(
                  value: fraction,
                  onChanged: _seekTo,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_fmt(_previewPosition),
                      style: const TextStyle(fontSize: 10, color: Color(0xFF666666), fontFamily: 'monospace')),
                    Text(_fmt(_previewDuration),
                      style: const TextStyle(fontSize: 10, color: Color(0xFF666666), fontFamily: 'monospace')),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // ── Enhanced audio label ─────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F0F0F),
              border: Border.all(color: const Color(0xFF1E1E1E)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: const [
                Icon(Icons.graphic_eq, color: Color(0xFFFF6B00), size: 14),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Audio enhanced — HPF · LPF · EQ · Compressor · Limiter',
                    style: TextStyle(
                      fontFamily: 'monospace', fontSize: 9,
                      color: Color(0xFF555555), letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // ── Action buttons ────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_alt, size: 20),
              label: const Text('SAVE TO GALLERY'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B00),
                foregroundColor: Colors.black,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(4)),
                ),
                textStyle: const TextStyle(
                  fontFamily: 'monospace', fontSize: 14,
                  fontWeight: FontWeight.w800, letterSpacing: 1.6,
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              onPressed: _discard,
              icon: const Icon(Icons.delete_outline, size: 18,
                color: Color(0xFF666666)),
              label: const Text('DISCARD',
                style: TextStyle(color: Color(0xFF666666))),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF2A2A2A)),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(4)),
                ),
                textStyle: const TextStyle(
                  fontFamily: 'monospace', fontSize: 13,
                  fontWeight: FontWeight.w700, letterSpacing: 1.6,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SAVING OVERLAY
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildSavingOverlay() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 40, height: 40,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Color(0xFFFF6B00),
              backgroundColor: Color(0xFF2A2A2A),
            ),
          ),
          SizedBox(height: 20),
          Text(
            'Saving to Gallery…',
            style: TextStyle(
              fontFamily: 'monospace', fontSize: 13,
              color: Color(0xFFCCCCCC), letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SHARED PROCESSING WIDGETS
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildStatusLabel() {
    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          width: 8, height: 8,
          decoration: BoxDecoration(
            color: const Color(0xFFFF6B00),
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(
              color: const Color(0xFFFF6B00).withOpacity(0.6),
              blurRadius: 8, spreadRadius: 2,
            )],
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          'MASTERING ENGINE AUDIO',
          style: TextStyle(
            fontFamily: 'monospace', fontSize: 11,
            fontWeight: FontWeight.w800, letterSpacing: 2.5,
            color: Color(0xFFFF6B00),
          ),
        ),
      ],
    );
  }

  Widget _buildWaveform() {
    return SizedBox(
      height: 140,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(_barCount, (i) {
          final amp = _bars[i].clamp(0.02, 1.0);
          final barColor = Color.lerp(
            const Color(0xFF2A2A2A),
            amp > 0.7 ? const Color(0xFFFFAA00) : const Color(0xFFFF6B00),
            amp,
          )!;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 60),
                height: 140 * amp,
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
                  boxShadow: amp > 0.6
                      ? [BoxShadow(color: barColor.withOpacity(0.4), blurRadius: 6, spreadRadius: 1)]
                      : [],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildProgressBar() {
    final pct = (_progress * 100).toStringAsFixed(0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('PIPELINE PROGRESS', style: TextStyle(
              fontFamily: 'monospace', fontSize: 9,
              letterSpacing: 2, color: Color(0xFF444444),
            )),
            Text('$pct%', style: const TextStyle(
              fontFamily: 'monospace', fontSize: 9,
              letterSpacing: 1, color: Color(0xFFFF6B00),
            )),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 3,
            backgroundColor: const Color(0xFF1E1E1E),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFFF6B00)),
          ),
        ),
      ],
    );
  }

  Widget _buildLogReadout() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F0F),
        border: Border.all(color: const Color(0xFF1E1E1E)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _logLine,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'monospace', fontSize: 9,
          color: Color(0xFF3A3A3A), height: 1.5, letterSpacing: 0.3,
        ),
      ),
    );
  }
}
