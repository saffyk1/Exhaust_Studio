// ─────────────────────────────────────────────────────────────────────────────
// STAGE 2 — Drop-in replacement for the top section of main.dart
// Replace everything from the top of the file down to (and including) the
// kBuiltInPresets list with this block. Everything below kBuiltInPresets in
// your current main.dart (App root, HomeScreen, etc.) stays untouched.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:gal/gal.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'waveform_screen.dart';
import 'dart:async';
import 'stable_audio_service.dart';


// ─────────────────────────────────────────────────────────────────────────────
// Graphic Parametric EQ — band model
// ─────────────────────────────────────────────────────────────────────────────
enum EqBandType { highpass, lowshelf, bell, highshelf, lowpass }

class GraphicEqBand {
  final String id;          // 'HP','L','1','2','3','4','5','H','LP'
  final EqBandType type;
  final bool enabled;
  final bool isLocked;      // true for band '2' — always enabled, can't be turned off
  final double freqHz;
  final double gainDb;      // ignored for highpass/lowpass (they don't have gain)
  final double q;           // width/Q — controls how narrow/wide the curve is

  const GraphicEqBand({
    required this.id,
    required this.type,
    required this.enabled,
    this.isLocked = false,
    required this.freqHz,
    required this.gainDb,
    required this.q,
  });

  GraphicEqBand copyWith({
    bool? enabled,
    double? freqHz,
    double? gainDb,
    double? q,
  }) => GraphicEqBand(
    id: id,
    type: type,
    enabled: isLocked ? true : (enabled ?? this.enabled), // locked band can't be disabled
    isLocked: isLocked,
    freqHz: freqHz ?? this.freqHz,
    gainDb: gainDb ?? this.gainDb,
    q: q ?? this.q,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'enabled': enabled,
    'isLocked': isLocked,
    'freqHz': freqHz,
    'gainDb': gainDb,
    'q': q,
  };

  factory GraphicEqBand.fromJson(Map<String, dynamic> j) => GraphicEqBand(
    id: j['id'] as String,
    type: EqBandType.values.firstWhere((t) => t.name == j['type']),
    enabled: j['enabled'] as bool,
    isLocked: j['isLocked'] as bool? ?? false,
    freqHz: (j['freqHz'] as num).toDouble(),
    gainDb: (j['gainDb'] as num).toDouble(),
    q: (j['q'] as num).toDouble(),
  );

  /// FFmpeg filter string fragment for this single band.
  /// Returns null if disabled (caller should skip it).
  String? get filterFragment {
    if (!enabled) return null;
    switch (type) {
      case EqBandType.highpass:
        return 'highpass=f=${freqHz.round()}:poles=2';
      case EqBandType.lowpass:
        return 'lowpass=f=${freqHz.round()}:poles=2';
      case EqBandType.lowshelf:
        return 'equalizer=f=${freqHz.round()}:width_type=h:width=${(freqHz).round()}:g=${gainDb.toStringAsFixed(1)}';
      case EqBandType.highshelf:
        return 'equalizer=f=${freqHz.round()}:width_type=h:width=${(freqHz * 0.5).round()}:g=${gainDb.toStringAsFixed(1)}';
      case EqBandType.bell:
      // q controls width — convert Q to an approximate Hz width for FFmpeg's width_type=h
        final widthHz = (freqHz / q).clamp(2, 5000);
        return 'equalizer=f=${freqHz.round()}:width_type=h:width=${widthHz.round()}:g=${gainDb.toStringAsFixed(1)}';
    }
  }
}

/// Default 9-band layout matching the Premiere Pro parametric EQ screenshot.
/// Only band '2' starts enabled (locked on); everything else starts disabled
/// (invisible on the graph until the user taps its button).
List<GraphicEqBand> kDefaultGraphicEqBands = [
  const GraphicEqBand(id: 'HP', type: EqBandType.highpass,  enabled: false, freqHz: 40,    gainDb: 0,  q: 0.71),
  const GraphicEqBand(id: 'L',  type: EqBandType.lowshelf,  enabled: false, freqHz: 80,    gainDb: 0,  q: 0.71),
  const GraphicEqBand(id: '1',  type: EqBandType.bell,      enabled: false, freqHz: 200,   gainDb: 0,  q: 1.0),
  const GraphicEqBand(id: '2',  type: EqBandType.bell,      enabled: true,  isLocked: true, freqHz: 800,   gainDb: 0,  q: 1.0),
  const GraphicEqBand(id: '3',  type: EqBandType.bell,      enabled: false, freqHz: 3200,  gainDb: 0,  q: 1.0),
  const GraphicEqBand(id: '4',  type: EqBandType.bell,      enabled: false, freqHz: 6000,  gainDb: 0,  q: 1.0),
  const GraphicEqBand(id: '5',  type: EqBandType.bell,      enabled: false, freqHz: 12800, gainDb: 0,  q: 1.0),
  const GraphicEqBand(id: 'H',  type: EqBandType.highshelf, enabled: false, freqHz: 10000, gainDb: 0,  q: 0.71),
  const GraphicEqBand(id: 'LP', type: EqBandType.lowpass,   enabled: false, freqHz: 18000, gainDb: 0,  q: 0.71),
];

/// Builds the combined FFmpeg filter fragment for all enabled bands,
/// in the fixed order: HP, L, 1, 2, 3, 4, 5, H, LP.
/// Never empty as long as the list contains the locked band '2'.
String buildGraphicEqFilterChain(List<GraphicEqBand> bands) {
  final fragments = bands
      .map((b) => b.filterFragment)
      .whereType<String>()
      .toList();
  return fragments.join(', ');
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter parameter model
// ─────────────────────────────────────────────────────────────────────────────
class FilterParams {
  final int    hpfHz;
  final int    lpfHz;
  final double eq80Gain;
  final double eq200Gain;
  final double eq2500Gain;
  final double eq4000Gain;
  final double eq6000Gain;
  final double eq10000Gain;
  final double compThresh;
  final double compRatio;
  final double volDb;
  final double limDb;

  // ── NEW: dual EQ toggles ──────────────────────────────────────────────────
  final bool sliderEqEnabled;          // controls the 6 equalizer= bell bands above (default ON — matches old behavior)
  final bool graphicEqEnabled;         // controls the 9-point graphic EQ below (default OFF — opt-in)
  final List<GraphicEqBand> graphicEqBands;

  const FilterParams({
    required this.hpfHz,  required this.lpfHz,
    required this.eq80Gain,
    required this.eq200Gain, required this.eq2500Gain,
    required this.eq4000Gain, required this.eq6000Gain,
    required this.eq10000Gain,
    required this.compThresh, required this.compRatio,
    required this.volDb, required this.limDb,
    this.sliderEqEnabled = true,
    this.graphicEqEnabled = false,
    this.graphicEqBands = const [],
  });

  FilterParams copyWith({
    int? hpfHz, int? lpfHz,
    double? eq80Gain,
    double? eq200Gain, double? eq2500Gain,
    double? eq4000Gain, double? eq6000Gain,
    double? eq10000Gain,
    double? compThresh, double? compRatio,
    double? volDb, double? limDb,
    bool? sliderEqEnabled,
    bool? graphicEqEnabled,
    List<GraphicEqBand>? graphicEqBands,
  }) => FilterParams(
    hpfHz: hpfHz ?? this.hpfHz,
    lpfHz: lpfHz ?? this.lpfHz,
    eq80Gain: eq80Gain ?? this.eq80Gain,
    eq200Gain: eq200Gain ?? this.eq200Gain,
    eq2500Gain: eq2500Gain ?? this.eq2500Gain,
    eq4000Gain: eq4000Gain ?? this.eq4000Gain,
    eq6000Gain: eq6000Gain ?? this.eq6000Gain,
    eq10000Gain: eq10000Gain ?? this.eq10000Gain,
    compThresh: compThresh ?? this.compThresh,
    compRatio: compRatio ?? this.compRatio,
    volDb: volDb ?? this.volDb,
    limDb: limDb ?? this.limDb,
    sliderEqEnabled: sliderEqEnabled ?? this.sliderEqEnabled,
    graphicEqEnabled: graphicEqEnabled ?? this.graphicEqEnabled,
    graphicEqBands: graphicEqBands ?? this.graphicEqBands,
  );

  Map<String, dynamic> toJson() => {
    'hpfHz': hpfHz, 'lpfHz': lpfHz,
    'eq80Gain': eq80Gain,
    'eq200Gain': eq200Gain, 'eq2500Gain': eq2500Gain,
    'eq4000Gain': eq4000Gain, 'eq6000Gain': eq6000Gain,
    'eq10000Gain': eq10000Gain,
    'compThresh': compThresh, 'compRatio': compRatio,
    'volDb': volDb, 'limDb': limDb,
    'sliderEqEnabled': sliderEqEnabled,
    'graphicEqEnabled': graphicEqEnabled,
    'graphicEqBands': graphicEqBands.map((b) => b.toJson()).toList(),
  };

  factory FilterParams.fromJson(Map<String, dynamic> j) => FilterParams(
    hpfHz: (j['hpfHz'] as num).toInt(),
    lpfHz: (j['lpfHz'] as num).toInt(),
    eq80Gain: (j['eq80Gain'] as num? ?? 0.0).toDouble(),
    eq200Gain: (j['eq200Gain'] as num? ?? j['eq1Gain'] as num? ?? 0.0).toDouble(),
    eq2500Gain: (j['eq2500Gain'] as num? ?? j['eq2Gain'] as num? ?? 0.0).toDouble(),
    eq4000Gain: (j['eq4000Gain'] as num? ?? 0.0).toDouble(),
    eq6000Gain: (j['eq6000Gain'] as num? ?? 0.0).toDouble(),
    eq10000Gain: (j['eq10000Gain'] as num? ?? 0.0).toDouble(),
    compThresh: (j['compThresh'] as num).toDouble(),
    compRatio: (j['compRatio'] as num).toDouble(),
    volDb: (j['volDb'] as num).toDouble(),
    limDb: (j['limDb'] as num).toDouble(),
    sliderEqEnabled: j['sliderEqEnabled'] as bool? ?? true,
    graphicEqEnabled: j['graphicEqEnabled'] as bool? ?? false,
    graphicEqBands: j['graphicEqBands'] != null
        ? (j['graphicEqBands'] as List)
        .map((b) => GraphicEqBand.fromJson(b as Map<String, dynamic>))
        .toList()
        : List<GraphicEqBand>.from(kDefaultGraphicEqBands),
  );

  /// The 6-band slider EQ fragment (your original always-on bands),
  /// only included when sliderEqEnabled is true.
  String? get _sliderEqFragment {
    if (!sliderEqEnabled) return null;
    return 'equalizer=f=80:width_type=h:width=40:g=${eq80Gain.toStringAsFixed(1)}, '
        'equalizer=f=200:width_type=h:width=50:g=${eq200Gain.toStringAsFixed(1)}, '
        'equalizer=f=2500:width_type=h:width=200:g=${eq2500Gain.toStringAsFixed(1)}, '
        'equalizer=f=4000:width_type=h:width=300:g=${eq4000Gain.toStringAsFixed(1)}, '
        'equalizer=f=6000:width_type=h:width=400:g=${eq6000Gain.toStringAsFixed(1)}, '
        'equalizer=f=10000:width_type=h:width=500:g=${eq10000Gain.toStringAsFixed(1)}';
  }

  /// The 9-point graphic EQ fragment, only included when graphicEqEnabled
  /// is true. Chained AFTER the slider EQ when both are on, per design:
  /// slider EQ output feeds into graphic EQ.
  String? get _graphicEqFragment {
    if (!graphicEqEnabled) return null;
    final bands = graphicEqBands.isNotEmpty ? graphicEqBands : kDefaultGraphicEqBands;
    final chain = buildGraphicEqFilterChain(bands);
    return chain.isNotEmpty ? chain : null;
  }

  /// Combined filter chain. Always-on top-level HPF/LPF stay exactly as
  /// before. EQ segments are conditionally included based on the two
  /// toggles; if both are off, the audio passes through compressor/volume/
  /// limiter only — true passthrough for the EQ stage.
  String get filterChain {
    final segments = <String>[
      'highpass=f=$hpfHz',
      'lowpass=f=$lpfHz',
      if (_sliderEqFragment != null) _sliderEqFragment!,
      if (_graphicEqFragment != null) _graphicEqFragment!,
      'acompressor=threshold=${compThresh.toStringAsFixed(0)}dB:ratio=${compRatio.toStringAsFixed(1)}:attack=5:release=50',
      'volume=volume=${volDb.toStringAsFixed(1)}dB',
      'alimiter=limit=${limDb.toStringAsFixed(1)}dB',
    ];
    return segments.join(', ');
  }
}

const kDefaultParams = FilterParams(
  hpfHz: 120, lpfHz: 6500,
  eq80Gain: 0.0,
  eq200Gain: 6.0, eq2500Gain: 3.0,
  eq4000Gain: 0.0, eq6000Gain: 0.0, eq10000Gain: 0.0,
  compThresh: -12, compRatio: 4.0,
  volDb: 2.0, limDb: -1.0,
  sliderEqEnabled: true,
  graphicEqEnabled: false,
  graphicEqBands: [],
);

// ─────────────────────────────────────────────────────────────────────────────
// Preset model
// ─────────────────────────────────────────────────────────────────────────────
class ExhaustPreset {
  final String name;
  final String desc;
  final FilterParams params;
  final bool isCustom;

  const ExhaustPreset({ required this.name, required this.desc, required this.params, this.isCustom = false });

  Map<String, dynamic> toJson() => { 'name': name, 'desc': desc, 'params': params.toJson() };
  factory ExhaustPreset.fromJson(Map<String, dynamic> j) => ExhaustPreset(
    name: j['name'] as String,
    desc: j['desc'] as String,
    params: FilterParams.fromJson(j['params'] as Map<String, dynamic>),
    isCustom: true,
  );
}

const kBuiltInPresets = [
  ExhaustPreset(name: 'Default',      desc: 'Balanced for most bikes',          params: kDefaultParams),
  ExhaustPreset(name: 'Track Day',    desc: 'Aggressive bark, tight noise',      params: FilterParams(hpfHz: 180, lpfHz: 5000, eq80Gain: 0.0, eq200Gain: 9.0, eq2500Gain: 5.0, eq4000Gain: 2.0, eq6000Gain: 0.0, eq10000Gain: 0.0, compThresh: -10, compRatio: 6.0, volDb: 3.0, limDb: -0.5)),
  ExhaustPreset(name: 'Deep Rumble',  desc: 'Maximum bass, full exhaust tone',   params: FilterParams(hpfHz: 70,  lpfHz: 6000, eq80Gain: 6.0, eq200Gain: 12.0, eq2500Gain: 2.0, eq4000Gain: 0.0, eq6000Gain: 0.0, eq10000Gain: 0.0, compThresh: -14, compRatio: 5.0, volDb: 4.0, limDb: -0.5)),
  ExhaustPreset(name: 'Street Cruise',desc: 'Everyday riding, smooth & natural', params: FilterParams(hpfHz: 100, lpfHz: 7500, eq80Gain: 0.0, eq200Gain: 5.0, eq2500Gain: 3.0, eq4000Gain: 1.0, eq6000Gain: 0.0, eq10000Gain: 0.0, compThresh: -12, compRatio: 3.5, volDb: 2.0, limDb: -1.5)),
  ExhaustPreset(name: 'Wet Road',     desc: 'Gentle cleanup, natural sound',     params: FilterParams(hpfHz: 80,  lpfHz: 8500, eq80Gain: 0.0, eq200Gain: 3.0, eq2500Gain: 1.5, eq4000Gain: 0.0, eq6000Gain: 0.0, eq10000Gain: 0.0, compThresh: -18, compRatio: 2.5, volDb: 1.0, limDb: -2.0)),
  ExhaustPreset(name: 'Race Mode',    desc: 'Maximum presence, competition',     params: FilterParams(hpfHz: 200, lpfHz: 4500, eq80Gain: 0.0, eq200Gain: 10.0, eq2500Gain: 6.0, eq4000Gain: 4.0, eq6000Gain: 2.0, eq10000Gain: 0.0, compThresh: -8, compRatio: 8.0, volDb: 4.0, limDb: -0.5)),
];

// ─────────────────────────────────────────────────────────────────────────────
// App root
// ─────────────────────────────────────────────────────────────────────────────
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent, statusBarIconBrightness: Brightness.light,
  ));
  runApp(const ExhaustStudioApp());
}

class ExhaustStudioApp extends StatelessWidget {
  const ExhaustStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ExhaustStudio 650',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const HomeScreen(),
    );
  }

  ThemeData _buildTheme() => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF141414),
    colorScheme: ColorScheme.dark(
      primary: const Color(0xFFFF6B00),
      secondary: const Color(0xFFFFAA00),
      surface: const Color(0xFF1E1E1E),
      onSurface: const Color(0xFFE8E8E8),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0D0D0D),
      foregroundColor: Color(0xFFE8E8E8),
      elevation: 0, centerTitle: false,
      titleTextStyle: TextStyle(fontFamily: 'monospace', fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 1.4, color: Color(0xFFFF6B00)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.black,
      minimumSize: const Size.fromHeight(56),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
      textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 1.6),
    )),
    sliderTheme: SliderThemeData(
      activeTrackColor: const Color(0xFFFF6B00), inactiveTrackColor: const Color(0xFF3A3A3A),
      thumbColor: const Color(0xFFFFAA00), overlayColor: const Color(0x33FF6B00),
      trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Home Screen
// ─────────────────────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum TuningMode { presets, manual }

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // ── Video ──────────────────────────────────────────────────────────────────
  File? _videoFile;
  VideoPlayerController? _videoController;
  bool _isLoading = false;

  // ── Enhanced video (for ORIGINAL/ENHANCED toggle) ──────────────────────────
  File? _enhancedFile;
  VideoPlayerController? _enhancedController;
  bool _showingEnhanced = false;

  // ── Preview position slider ────────────────────────────────────────────────
  Duration _previewStartPosition = Duration.zero;

  // ── Trim slider ────────────────────────────────────────────────────────────
  Duration _trimStart = Duration.zero;
  Duration _trimEnd = Duration.zero;
  bool _isTrimmed = false;

  // ── Live preview debounce ──────────────────────────────────────────────────
  Timer? _debounceTimer;
  bool _isPreviewProcessing = false;

  // ── Tuning ─────────────────────────────────────────────────────────────────
  TuningMode _tuningMode  = TuningMode.presets;
  FilterParams _params    = kDefaultParams;
  FilterParams _manualParams = kDefaultParams;
  String _selectedPreset  = 'Default';
  String _selectedGraphicBandId = '2'; // which graphic EQ point is currently selected for the width control
  File? _spectrogramFile;
  bool _isGeneratingSpectrogram = false;

  // ── Custom presets ─────────────────────────────────────────────────────────
  List<ExhaustPreset> _customPresets = [];
  static const _prefsKey = 'exhaustStudioPresets';

  // ── Save preset dialog ─────────────────────────────────────────────────────
  bool _showSaveInput = false;
  final _saveNameCtrl = TextEditingController();

  // ── SA3 / Stable Audio 3 ──────────────────────────────────────────────────
  static const _sa3UrlPrefKey     = 'sa3ColabUrl';
  static const _kDefaultSa3Prompt =
      'Pure Harley Davidson motorcycle engine sound, deep exhaust notes';
  static const _kDefaultNegSa3Prompt =
      'hiss, static, crackle, digital distortion, music, background hum, wind noise';

  final _sa3UrlCtrl = TextEditingController();

  final _sa3LocalUrlCtrl = TextEditingController();

  final _sa3HfUrlCtrl = TextEditingController();

  bool _useLocalBackend = true;
  Sa3Params _sa3Params = const Sa3Params(
    prompt: _kDefaultSa3Prompt,
    negativePrompt: _kDefaultNegSa3Prompt,
    seed: -1,
    denoise: 0.4,
    cfg: 1.0,
    steps: 8,
  );
  bool _sa3Loading     = false;
  String _sa3Status    = '';
  File?  _sa3OutputFile;
  bool   _sa3PanelOpen = false;
  File? _sa3VideoFile;
  VideoPlayerController? _sa3VideoController;
  StableAudioService? _sa3Service;
  final TextEditingController _promptController =
  TextEditingController();

  final TextEditingController _negativePromptController =
  TextEditingController();

  // ── Animations generateAudio ─────────────────────────────────────────────────────────────
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(
      begin: 0.7,
      end: 1.0,
    ).animate(
      CurvedAnimation(
        parent: _pulseController,
        curve: Curves.easeInOut,
      ),
    );

    // Initialize prompt controllers
    _promptController.text = _sa3Params.prompt;
    _negativePromptController.text = _sa3Params.negativePrompt;

    _loadCustomPresets();
    _loadSa3Url();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _videoController?.dispose();
    _enhancedController?.dispose();
    _pulseController.dispose();
    _saveNameCtrl.dispose();
    _sa3UrlCtrl.dispose();
    _promptController.dispose();
    _negativePromptController.dispose();
    super.dispose();
  }

  // ── Persist custom presets ─────────────────────────────────────────────────
  Future<void> _loadCustomPresets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List).map((e) => ExhaustPreset.fromJson(e as Map<String, dynamic>)).toList();
      if (mounted) setState(() => _customPresets = list);
    } catch (_) {}
  }

  Future<void> _saveCustomPresets() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(_customPresets.map((p) => p.toJson()).toList()));
  }

  // ── SA3 URL persistence ────────────────────────────────────────────────────
  Future<void> _loadSa3Url() async {
    final prefs = await SharedPreferences.getInstance();

    _sa3LocalUrlCtrl.text =
        prefs.getString('sa3_local_url') ?? '';

    _sa3HfUrlCtrl.text =
        prefs.getString('sa3_hf_url') ?? '';

    _useLocalBackend =
        prefs.getBool('sa3_use_local') ?? true;

    if (mounted) setState(() {});
  }

  Future<void> _saveSa3Url(String _) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'sa3_local_url',
      _sa3LocalUrlCtrl.text.trim(),
    );

    await prefs.setString(
      'sa3_hf_url',
      _sa3HfUrlCtrl.text.trim(),
    );

    await prefs.setBool(
      'sa3_use_local',
      _useLocalBackend,
    );
  }

  // ── Mode switching ─────────────────────────────────────────────────────────
  void _switchToManual() => setState(() {
    _tuningMode     = TuningMode.manual;
    _manualParams   = _params;
    _selectedPreset = '';
  });

  void _switchToPresets() {
    final all = [...kBuiltInPresets, ..._customPresets];
    final hit = all.firstWhere((p) => p.name == _selectedPreset, orElse: () => kBuiltInPresets[0]);
    setState(() {
      _tuningMode     = TuningMode.presets;
      _selectedPreset = hit.name;
      _params         = hit.params;
    });
  }

  void _applyPreset(ExhaustPreset preset) {
    setState(() {
      _selectedPreset = preset.name;
      _params         = preset.params;
      _manualParams   = preset.params;
    });
    _triggerLivePreview();
  }

  void _setManualParam(FilterParams p) {
    setState(() { _manualParams = p; _params = p; });
    _triggerLivePreview();
  }

  // ── Graphic EQ helpers ───────────────────────────────────────────────────
  List<GraphicEqBand> get _graphicBands =>
      _manualParams.graphicEqBands.isNotEmpty ? _manualParams.graphicEqBands : kDefaultGraphicEqBands;

  void _updateGraphicBand(String id, GraphicEqBand Function(GraphicEqBand) update) {
    final bands = _graphicBands.map((b) => b.id == id ? update(b) : b).toList();
    _setManualParam(_manualParams.copyWith(graphicEqBands: bands));
  }

  void _toggleGraphicBand(String id) {
    final band = _graphicBands.firstWhere((b) => b.id == id);
    if (band.isLocked) return; // band '2' can't be disabled
    setState(() { _selectedGraphicBandId = id; });
    _updateGraphicBand(id, (b) => b.copyWith(enabled: !b.enabled));
  }

  // ── Save custom preset ─────────────────────────────────────────────────────
  Future<void> _doSavePreset() async {
    final name = _saveNameCtrl.text.trim();
    if (name.isEmpty) return;
    final allNames = [...kBuiltInPresets, ..._customPresets].map((p) => p.name).toList();
    if (allNames.contains(name)) {
      _showStatus('A preset named "$name" already exists.', isError: true); return;
    }
    final preset = ExhaustPreset(name: name, desc: 'Custom preset', params: _params, isCustom: true);
    setState(() {
      _customPresets.add(preset);
      _selectedPreset  = name;
      _tuningMode      = TuningMode.presets;
      _showSaveInput   = false;
    });
    _saveNameCtrl.clear();
    await _saveCustomPresets();
  }

  Future<void> _deleteCustomPreset(ExhaustPreset preset) async {
    setState(() {
      _customPresets.removeWhere((p) => p.name == preset.name);
      if (_selectedPreset == preset.name) {
        _selectedPreset = 'Default';
        _params = kDefaultParams;
      }
    });
    await _saveCustomPresets();
  }

  // ── Permissions ────────────────────────────────────────────────────────────
  Future<bool> _ensurePermissions() async {
    PermissionStatus status;
    if (Platform.isAndroid) {
      status = await Permission.videos.request();
      if (!status.isGranted) status = await Permission.storage.request();
    } else {
      status = await Permission.photos.request();
    }
    return status.isGranted;
  }

  // ── Video picking ──────────────────────────────────────────────────────────
  Future<void> _pickVideo() async {
    if (_isLoading) return;
    final granted = await _ensurePermissions();
    if (!granted) { _showStatus('Storage permission denied.', isError: true); return; }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final sourcePath = result.files.single.path;
    if (sourcePath == null) { _showStatus('Could not read file path.', isError: true); return; }

    final cacheDir = await getTemporaryDirectory();
    final tempFile = File('${cacheDir.path}/input_${DateTime.now().millisecondsSinceEpoch}.mp4');
    await File(sourcePath).copy(tempFile.path);

    await _enhancedController?.dispose();
    setState(() {
      _enhancedFile = null;
      _enhancedController = null;
      _showingEnhanced = false;
    });

    await _initVideoController(tempFile);
    setState(() => _videoFile = tempFile);
  }

  Future<void> _initVideoController(File file) async {
    await _videoController?.dispose();
    final ctrl = VideoPlayerController.file(file);
    await ctrl.initialize();
    ctrl.setLooping(true);
    ctrl.addListener(() { if (mounted) setState(() {}); });
    setState(() => _videoController = ctrl);
    _trimStart = Duration.zero;
    _trimEnd = ctrl.value.duration;
    _isTrimmed = false;
    _generateSpectrogramFor(file);
  }

  // ── Spectrogram (frequency-over-time map of the ORIGINAL audio) ─────────────
  // Lets you see WHEN in the clip a bad frequency happens, so you know where to
  // aim the graphic EQ. Generated once per loaded video via FFmpeg's showspectrumpic.
  Future<void> _generateSpectrogramFor(File video) async {
    setState(() { _isGeneratingSpectrogram = true; _spectrogramFile = null; });
    try {
      final cacheDir = await getTemporaryDirectory();
      final outPath = p.join(cacheDir.path, 'spectrogram_${DateTime.now().millisecondsSinceEpoch}.png');
      final session = await FFmpegKit.executeWithArguments([
        '-y', '-i', video.path,
        '-lavfi', 'showspectrumpic=s=1024x300:legend=0:scale=log:fscale=log:start=20:stop=20000:orientation=vertical',
        outPath,
      ]);
      final rc = await session.getReturnCode();
      if (ReturnCode.isSuccess(rc) && File(outPath).existsSync()) {
        if (mounted) setState(() { _spectrogramFile = File(outPath); _isGeneratingSpectrogram = false; });
      } else {
        if (mounted) setState(() => _isGeneratingSpectrogram = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isGeneratingSpectrogram = false);
    }
  }

  // ── Toggle ORIGINAL / ENHANCED ────────────────────────────────────────────
  Future<void> _switchAudio(bool showEnhanced) async {
    if (_videoController == null) return;
    final wasPlaying = _videoController!.value.isPlaying || (_enhancedController?.value.isPlaying ?? false);
    final position = _videoController!.value.position;

    await _videoController!.pause();
    await _enhancedController?.pause();

    setState(() => _showingEnhanced = showEnhanced);

    if (showEnhanced && _enhancedController != null) {
      await _enhancedController!.seekTo(position);
      if (wasPlaying) _enhancedController!.play();
    } else {
      await _videoController!.seekTo(position);
      if (wasPlaying) _videoController!.play();
    }
  }

  // ── FFmpeg processing ──────────────────────────────────────────────────────
  Future<void> _processVideo() async {
    if (_videoFile == null || _isLoading) return;
    setState(() { _isLoading = true; _isPreviewProcessing = true; _previewStartPosition = Duration.zero; });

    final cacheDir    = await getTemporaryDirectory();
    final timestamp   = DateTime.now().millisecondsSinceEpoch;
    final tempOutput  = p.join(cacheDir.path, 'exhaust_studio_$timestamp.mp4');
    final filterChain = _params.filterChain;

    final session = await FFmpegKit.executeWithArguments([
      '-y', '-i', _videoFile!.path,
      '-c:v', 'copy',
      '-af', filterChain,
      tempOutput,
    ]);

    final rc = await session.getReturnCode();
    if (!mounted) return;

    if (!ReturnCode.isSuccess(rc)) {
      final logs = await session.getAllLogsAsString();
      setState(() { _isLoading = false; _isPreviewProcessing = false; });
      _showStatus('FFmpeg error: $logs', isError: true);
      return;
    }

    final enhFile = File(tempOutput);
    final ctrl = VideoPlayerController.file(enhFile);
    await ctrl.initialize();
    ctrl.setLooping(true);
    ctrl.addListener(() { if (mounted) setState(() {}); });

    final pos = _videoController?.value.position ?? Duration.zero;
    await ctrl.seekTo(pos);

    await _enhancedController?.dispose();
    if (mounted) {
      setState(() {
        _enhancedFile        = enhFile;
        _enhancedController  = ctrl;
        _showingEnhanced     = true;
        _isLoading           = false;
        _isPreviewProcessing = false;
      });
    }
  }

  // ── Live preview (debounced re-process on setting change) ─────────────────
  Future<void> _triggerLivePreview() async {
    if (_videoFile == null || _enhancedFile == null) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 800), () async {
      if (!mounted || _isPreviewProcessing) return;
      setState(() => _isPreviewProcessing = true);

      final cacheDir = await getTemporaryDirectory();
      final tempOutput = '${cacheDir.path}/live_preview_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final filterChain = _params.filterChain;
      final startSecs = _previewStartPosition.inSeconds.toString();

      // Duration: 15 seconds or whatever remains from start position
      final totalSecs = _videoController?.value.duration.inSeconds ?? 0;
      final remaining = (totalSecs - _previewStartPosition.inSeconds).clamp(1, 15);

      await FFmpegKit.executeWithArguments([
        '-y',
        '-ss', startSecs,
        '-t', remaining.toString(),
        '-i', _videoFile!.path,
        '-c:v', 'copy',
        '-af', filterChain,
        tempOutput,
      ]);

      if (!mounted) return;

      final newFile = File(tempOutput);
      if (!newFile.existsSync()) {
        setState(() => _isPreviewProcessing = false);
        return;
      }

      final ctrl = VideoPlayerController.file(newFile);
      await ctrl.initialize();
      ctrl.setLooping(true);
      ctrl.addListener(() { if (mounted) setState(() {}); });

      await ctrl.seekTo(Duration.zero);
      final wasPlaying = _enhancedController?.value.isPlaying ?? false;
      if (wasPlaying) ctrl.play();

      await _enhancedController?.dispose();
      try { if (_enhancedFile!.path.contains('live_preview')) _enhancedFile!.deleteSync(); } catch (_) {}

      if (mounted) {
        setState(() {
          _enhancedFile        = newFile;
          _enhancedController  = ctrl;
          _showingEnhanced     = true;
          _isPreviewProcessing = false;
        });
      }
    });
  }

  Future<String> _saveToGallery(String tempPath, int timestamp) async {
    final hasAccess = await Gal.hasAccess(toAlbum: true);
    if (!hasAccess) {
      final granted = await Gal.requestAccess(toAlbum: true);
      if (!granted) throw Exception('Gallery access denied.');
    }
    await Gal.putVideo(tempPath, album: 'ExhaustStudio');
    return 'Gallery › ExhaustStudio › ExhaustStudio_$timestamp.mp4';
  }

  // ── UI helpers ─────────────────────────────────────────────────────────────
  void _showStatus(String msg, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontFamily: 'monospace')),
      backgroundColor: isError ? Colors.red[800] : const Color(0xFF2A2A2A),
      behavior: SnackBarBehavior.floating, margin: const EdgeInsets.all(16),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
    ));
  }

  void _showSuccessSheet(String path) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: const [
            Icon(Icons.check_circle, color: Color(0xFF00E676), size: 22),
            SizedBox(width: 10),
            Text('AUDIO MASTERED', style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800, fontSize: 14, letterSpacing: 2, color: Color(0xFF00E676))),
          ]),
          const SizedBox(height: 14),
          const Text('Saved to Gallery under "ExhaustStudio".', style: TextStyle(color: Color(0xFFB0B0B0), height: 1.5)),
          const SizedBox(height: 8),
          Text(p.basename(path), style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFF606060))),
          const SizedBox(height: 20),
          ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('DONE')),
        ]),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Icon(Icons.graphic_eq, color: Color(0xFFFF6B00), size: 20),
          const SizedBox(width: 10),
          const Text('EXHAUST STUDIO'),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(border: Border.all(color: const Color(0xFFFF6B00)), borderRadius: BorderRadius.circular(2)),
            child: const Text('650', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1, color: Color(0xFFFF6B00))),
          ),
        ]),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _buildVideoSection(),
          const SizedBox(height: 28),
          _buildDividerLabel('TUNING PROFILE'),
          const SizedBox(height: 14),
          _buildModeSwitcher(),
          const SizedBox(height: 16),
          if (_tuningMode == TuningMode.presets) _buildPresetsPanel(),
          if (_tuningMode == TuningMode.manual)  _buildManualPanel(),
          const SizedBox(height: 28),
          _buildDividerLabel('PIPELINE'),
          const SizedBox(height: 12),
          _buildPipelineReadout(),
          const SizedBox(height: 28),
          _buildEnhanceButton(),
          const SizedBox(height: 28),
          _buildDividerLabel('AI REGENERATE · SA3'),
          const SizedBox(height: 14),
          _buildSa3Panel(),
        ]),
      ),
    );
  }

  // ── Video section ─────────────────────────────────────────────────────────
  Widget _buildVideoSection() {
    final hasVideo = _videoController?.value.isInitialized ?? false;
    final hasEnhanced = _enhancedController?.value.isInitialized ?? false;

    // Which controller is currently active
    final activeCtrl = (_showingEnhanced && hasEnhanced) ? _enhancedController! : (_videoController);

    return Column(children: [
      GestureDetector(
        onTap: hasVideo ? null : _pickVideo,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              border: Border.all(color: hasVideo ? const Color(0xFF333333) : const Color(0xFF2E2E2E), width: 1.5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: hasVideo ? _buildVideoPlayer(activeCtrl!, hasEnhanced) : _buildEmptyPlaceholder(),
          ),
        ),
      ),

      // Trim — shown as soon as video is loaded
      if (hasVideo) ...[
        const SizedBox(height: 8),
        _buildTrimSlider(),
      ],

      // ORIGINAL / ENHANCED toggle — only shown after processing
      if (hasEnhanced) ...[
        const SizedBox(height: 8),
        _buildAudioToggle(),
      ],
    ]);
  }

  Widget _buildAudioToggle() {
    final duration = _videoController?.value.duration ?? Duration.zero;
    final totalSecs = duration.inSeconds.toDouble();
    final sliderVal = _previewStartPosition.inSeconds.toDouble().clamp(0.0, totalSecs > 0 ? totalSecs : 1.0);

    return Column(children: [
      Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          border: Border.all(color: const Color(0xFF2A2A2A)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          _audioTab('ORIGINAL', !_showingEnhanced, () => _switchAudio(false)),
          _audioTab('ENHANCED ▲', _showingEnhanced, () => _switchAudio(true)),
        ]),
      ),
      const SizedBox(height: 10),
      // Preview position slider
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          border: Border.all(color: const Color(0xFF2A2A2A)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('PREVIEW FROM', style: TextStyle(fontFamily: 'monospace', fontSize: 9, letterSpacing: 1.4, color: Color(0xFF888888))),
            Text(_fmt(_previewStartPosition), style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFFF6B00), fontWeight: FontWeight.w700)),
          ]),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7)),
            child: Slider(
              value: sliderVal,
              min: 0,
              max: totalSecs > 0 ? totalSecs : 1.0,
              onChanged: totalSecs > 0 ? (v) {
                setState(() => _previewStartPosition = Duration(seconds: v.round()));
              } : null,
              onChangeEnd: totalSecs > 0 ? (v) {
                setState(() => _previewStartPosition = Duration(seconds: v.round()));
                _triggerLivePreview();
              } : null,
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('0:00', style: TextStyle(fontSize: 9, color: Color(0xFF444444))),
            Text(_fmt(duration), style: const TextStyle(fontSize: 9, color: Color(0xFF444444))),
          ]),
        ]),
      ),
      if (_isPreviewProcessing) ...[
        const SizedBox(height: 6),
        const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFFFF6B00))),
          SizedBox(width: 8),
          Text('updating preview…', style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF555555))),
        ]),
      ],
    ]);
  }

  Widget _buildTrimSlider() {
    final duration = _videoController?.value.duration ?? Duration.zero;
    final totalSecs = duration.inSeconds.toDouble();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        border: Border.all(color: const Color(0xFF2A3A2A)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('TRIM  { IN — OUT }', style: TextStyle(
              fontFamily: 'monospace', fontSize: 9, letterSpacing: 1.4, color: Color(0xFF66AA66))),
          Row(children: [
            Text('{ ${_fmt(_trimStart)}', style: const TextStyle(
                fontFamily: 'monospace', fontSize: 11, color: Color(0xFF66CC66), fontWeight: FontWeight.w700)),
            const Text('  —  ', style: TextStyle(color: Color(0xFF444444), fontSize: 11)),
            Text('${_fmt(_trimEnd)} }', style: const TextStyle(
                fontFamily: 'monospace', fontSize: 11, color: Color(0xFF66CC66), fontWeight: FontWeight.w700)),
          ]),
        ]),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2,
            activeTrackColor: const Color(0xFF66AA66),
            inactiveTrackColor: const Color(0xFF2A2A2A),
            thumbColor: const Color(0xFF88CC88),
            overlayColor: const Color(0x2266AA66),
            rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: RangeSlider(
            values: RangeValues(
              _trimStart.inSeconds.toDouble().clamp(0.0, totalSecs > 0 ? totalSecs : 1.0),
              _trimEnd.inSeconds.toDouble().clamp(0.0, totalSecs > 0 ? totalSecs : 1.0),
            ),
            min: 0,
            max: totalSecs > 0 ? totalSecs : 1.0,
            onChanged: totalSecs > 0 ? (v) => setState(() {
              _trimStart = Duration(seconds: v.start.round());
              _trimEnd   = Duration(seconds: v.end.round());
              _isTrimmed = true;
            }) : null,
          ),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('0:00', style: TextStyle(fontSize: 9, color: Color(0xFF444444))),
          Text(_fmt(duration), style: const TextStyle(fontSize: 9, color: Color(0xFF444444))),
        ]),
        if (_isTrimmed) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: _applyTrim,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A3A1A),
                    border: Border.all(color: const Color(0xFF66AA66)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  alignment: Alignment.center,
                  child: const Text('{ LOCK TRIM }', style: TextStyle(
                    fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.w700,
                    letterSpacing: 1.4, color: Color(0xFF66CC66),
                  )),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => setState(() {
                _trimStart = Duration.zero;
                _trimEnd   = _videoController?.value.duration ?? Duration.zero;
                _isTrimmed = false;
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFF333333)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('RESET', style: TextStyle(
                    fontFamily: 'monospace', fontSize: 11, color: Color(0xFF555555))),
              ),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _audioTab(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? const Color(0xFFFF6B00) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(
            fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.w700,
            letterSpacing: 1.2, color: active ? Colors.black : const Color(0xFF888888),
          )),
        ),
      ),
    );
  }

  Widget _buildEmptyPlaceholder() => Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    Container(width: 60, height: 60,
      decoration: BoxDecoration(border: Border.all(color: const Color(0xFF333333), width: 1.5), shape: BoxShape.circle),
      child: const Icon(Icons.add, color: Color(0xFF555555), size: 28)),
    const SizedBox(height: 14),
    const Text('Upload Ride Video', style: TextStyle(color: Color(0xFF555555), fontFamily: 'monospace', fontSize: 13, letterSpacing: 1.2)),
    const SizedBox(height: 6),
    const Text('tap to select from gallery', style: TextStyle(color: Color(0xFF383838), fontSize: 11)),
  ]);

  Widget _buildVideoPlayer(
      VideoPlayerController ctrl,
      bool hasEnhanced,
      ) =>
      ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Stack(
          alignment: Alignment.center,
          children: [

            VideoPlayer(ctrl),

            GestureDetector(
              onTap: () {
                setState(() {
                  ctrl.value.isPlaying
                      ? ctrl.pause()
                      : ctrl.play();
                });
              },
              child: AnimatedOpacity(
                opacity: ctrl.value.isPlaying ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            ),

            Positioned(
              top: 8,
              right: 8,
              child: GestureDetector(
                onTap: _pickVideo,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(
                      color: const Color(0xFF333333),
                    ),
                  ),
                  child: const Text(
                    'REPLACE',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: Color(0xFFAAAAAA),
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ),
            ),

            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SizedBox(
                height: 20,
                child: VideoProgressIndicator(
                  ctrl,
                  allowScrubbing: true,
                  colors: VideoProgressColors(
                    playedColor: const Color(0xFFFF6B00),
                    bufferedColor: Colors.white24,
                    backgroundColor: Colors.black38,
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  // ── Mode switcher ─────────────────────────────────────────────────────────
  Widget _buildModeSwitcher() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        _modeTab('PRESETS',       TuningMode.presets, _switchToPresets),
        _modeTab('MANUAL TUNING', TuningMode.manual,  _switchToManual),
      ]),
    );
  }

  Widget _modeTab(String label, TuningMode mode, VoidCallback onTap) {
    final active = _tuningMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? const Color(0xFFFF6B00) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(
            fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.w700,
            letterSpacing: 1.4, color: active ? Colors.black : const Color(0xFF888888),
          )),
        ),
      ),
    );
  }

  // ── Presets panel ─────────────────────────────────────────────────────────
  Widget _buildPresetsPanel() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildGroupLabel('BUILT-IN'),
      const SizedBox(height: 10),
      GridView.count(
        crossAxisCount: 2, shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 1.6,
        children: kBuiltInPresets.map((preset) => _buildPresetCard(preset)).toList(),
      ),
      if (_customPresets.isNotEmpty) ...[
        const SizedBox(height: 20),
        _buildGroupLabel('MY PRESETS'),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2, shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 1.6,
          children: _customPresets.map((preset) => _buildPresetCard(preset, canDelete: true)).toList(),
        ),
      ],
      const SizedBox(height: 16),
      if (!_showSaveInput)
        GestureDetector(
          onTap: () => setState(() => _showSaveInput = true),
          child: Container(
            width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF2A2A2A), style: BorderStyle.solid),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: const Text('+ SAVE CURRENT SETTINGS AS PRESET', style: TextStyle(
              fontFamily: 'monospace', fontSize: 10, letterSpacing: 1.4, color: Color(0xFF555555),
            )),
          ),
        )
      else
        Row(children: [
          Expanded(
            child: TextField(
              controller: _saveNameCtrl, autofocus: true,
              onSubmitted: (_) => _doSavePreset(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Color(0xFFE8E8E8)),
              decoration: InputDecoration(
                hintText: 'Preset name…',
                hintStyle: const TextStyle(color: Color(0xFF555555)),
                filled: true, fillColor: const Color(0xFF1A1A1A),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFFFF6B00))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFFFF6B00))),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _doSavePreset,
            style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 16)),
            child: const Text('SAVE'),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close, color: Color(0xFF555555)),
            onPressed: () => setState(() { _showSaveInput = false; _saveNameCtrl.clear(); }),
          ),
        ]),
    ]);
  }

  Widget _buildPresetCard(ExhaustPreset preset, { bool canDelete = false }) {
    final isSelected = _selectedPreset == preset.name;
    return GestureDetector(
      onTap: () => _applyPreset(preset),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          border: Border.all(color: isSelected ? const Color(0xFFFF6B00) : const Color(0xFF2A2A2A), width: isSelected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Stack(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(preset.name, style: TextStyle(
              fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.w700,
              letterSpacing: 1.0, color: isSelected ? const Color(0xFFFF6B00) : const Color(0xFFCCCCCC),
            )),
            const SizedBox(height: 4),
            Expanded(
              child: Text(preset.desc, style: const TextStyle(fontSize: 10, color: Color(0xFF555555), height: 1.3),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            Text(
              '${preset.params.hpfHz}Hz · ${preset.params.eq200Gain >= 0 ? '+' : ''}${preset.params.eq200Gain.toStringAsFixed(1)}dB · ${preset.params.compRatio.toStringAsFixed(1)}:1',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 9, color: Color(0xFF444444)),
            ),
          ]),
          if (canDelete)
            Positioned(
              top: -4, right: -4,
              child: GestureDetector(
                onTap: () => _deleteCustomPreset(preset),
                child: Container(
                  width: 22, height: 22,
                  decoration: const BoxDecoration(color: Color(0xFF2A2A2A), shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: const Text('×', style: TextStyle(color: Color(0xFF888888), fontSize: 14, height: 1)),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  // ── Manual panel ──────────────────────────────────────────────────────────
  Widget _buildManualPanel() {
    return Column(children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Row(children: [
          Icon(Icons.info_outline, color: Color(0xFF555555), size: 14),
          SizedBox(width: 6),
          Text('Starts from defaults — edit freely', style: TextStyle(fontSize: 10, color: Color(0xFF555555), letterSpacing: 0.5)),
        ]),
      ),
      _buildParamSlider('HPF FREQUENCY',  '${_manualParams.hpfHz} Hz',   _manualParams.hpfHz.toDouble(), 60, 300, 1, (v) => _setManualParam(_manualParams.copyWith(hpfHz: v.round()))),
      _buildParamSlider('LPF FREQUENCY',  '${_manualParams.lpfHz} Hz',   _manualParams.lpfHz.toDouble(), 1000, 20000, 100, (v) => _setManualParam(_manualParams.copyWith(lpfHz: v.round()))),

      // ── Slider EQ toggle + bands ─────────────────────────────────────────
      _buildEqToggleRow(
        label: 'SLIDER EQ',
        value: _manualParams.sliderEqEnabled,
        onChanged: (v) => _setManualParam(_manualParams.copyWith(sliderEqEnabled: v)),
      ),
      Opacity(
        opacity: _manualParams.sliderEqEnabled ? 1.0 : 0.4,
        child: IgnorePointer(
          ignoring: !_manualParams.sliderEqEnabled,
          child: Column(children: [
            _buildParamSlider('EQ 80Hz GAIN',   '${_manualParams.eq80Gain >= 0 ? "+" : ""}${_manualParams.eq80Gain.toStringAsFixed(1)} dB', _manualParams.eq80Gain, -12, 12, null, (v) => _setManualParam(_manualParams.copyWith(eq80Gain: (v * 2).round() / 2))),
            _buildParamSlider('EQ 200Hz GAIN',  '${_manualParams.eq200Gain >= 0 ? "+" : ""}${_manualParams.eq200Gain.toStringAsFixed(1)} dB', _manualParams.eq200Gain, -12, 12, null, (v) => _setManualParam(_manualParams.copyWith(eq200Gain: (v * 2).round() / 2))),
            _buildParamSlider('EQ 2500Hz GAIN', '${_manualParams.eq2500Gain >= 0 ? "+" : ""}${_manualParams.eq2500Gain.toStringAsFixed(1)} dB', _manualParams.eq2500Gain, -12, 12, null, (v) => _setManualParam(_manualParams.copyWith(eq2500Gain: (v * 2).round() / 2))),
            _buildParamSlider('EQ 4000Hz GAIN', '${_manualParams.eq4000Gain >= 0 ? "+" : ""}${_manualParams.eq4000Gain.toStringAsFixed(1)} dB', _manualParams.eq4000Gain, -12, 12, null, (v) => _setManualParam(_manualParams.copyWith(eq4000Gain: (v * 2).round() / 2))),
            _buildParamSlider('EQ 6000Hz GAIN', '${_manualParams.eq6000Gain >= 0 ? "+" : ""}${_manualParams.eq6000Gain.toStringAsFixed(1)} dB', _manualParams.eq6000Gain, -12, 12, null, (v) => _setManualParam(_manualParams.copyWith(eq6000Gain: (v * 2).round() / 2))),
            _buildParamSlider('EQ 10kHz GAIN',  '${_manualParams.eq10000Gain >= 0 ? "+" : ""}${_manualParams.eq10000Gain.toStringAsFixed(1)} dB', _manualParams.eq10000Gain, -12, 12, null, (v) => _setManualParam(_manualParams.copyWith(eq10000Gain: (v * 2).round() / 2))),
          ]),
        ),
      ),

      const SizedBox(height: 8),

      // ── Graphic parametric EQ toggle + graph ─────────────────────────────
      _buildEqToggleRow(
        label: 'GRAPHIC EQ',
        value: _manualParams.graphicEqEnabled,
        onChanged: (v) => _setManualParam(_manualParams.copyWith(graphicEqEnabled: v)),
      ),
      Opacity(
        opacity: _manualParams.graphicEqEnabled ? 1.0 : 0.4,
        child: IgnorePointer(
          ignoring: !_manualParams.graphicEqEnabled,
          child: _buildGraphicEqSection(),
        ),
      ),

      const SizedBox(height: 8),
      _buildParamSlider('COMP THRESHOLD', '${_manualParams.compThresh.toStringAsFixed(0)} dB', _manualParams.compThresh, -40, 0, null, (v) => _setManualParam(_manualParams.copyWith(compThresh: v.roundToDouble()))),
      _buildParamSlider('COMP RATIO',     '${_manualParams.compRatio.toStringAsFixed(1)} : 1', _manualParams.compRatio, 1, 20, null, (v) => _setManualParam(_manualParams.copyWith(compRatio: (v * 2).round() / 2))),
      _buildParamSlider('VOLUME BOOST',   '${_manualParams.volDb >= 0 ? "+" : ""}${_manualParams.volDb.toStringAsFixed(1)} dB', _manualParams.volDb, -12, 12, null, (v) => _setManualParam(_manualParams.copyWith(volDb: (v * 2).round() / 2))),
      _buildParamSlider('LIMITER CEILING','${_manualParams.limDb.toStringAsFixed(1)} dBFS', _manualParams.limDb, -12, 0, null, (v) => _setManualParam(_manualParams.copyWith(limDb: (v * 10).round() / 10))),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => setState(() { _manualParams = kDefaultParams; _params = kDefaultParams; }),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF2A2A2A)), foregroundColor: const Color(0xFF555555), shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4)))),
            child: const Text('RESET', style: TextStyle(fontFamily: 'monospace', fontSize: 11, letterSpacing: 1.5)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton(
            onPressed: () => setState(() { _tuningMode = TuningMode.presets; _showSaveInput = true; }),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF2A2A2A), style: BorderStyle.solid), foregroundColor: const Color(0xFF555555), shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4)))),
            child: const Text('+ SAVE AS PRESET', style: TextStyle(fontFamily: 'monospace', fontSize: 11, letterSpacing: 1.2)),
          ),
        ),
      ]),
    ]);
  }

  Widget _buildParamSlider(String label, String valueStr, double value, double min, double max, double? step, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(fontFamily: 'monospace', fontSize: 10, letterSpacing: 1.2, color: Color(0xFF888888))),
          Text(valueStr, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFFF6B00), fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(trackHeight: 2, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7)),
          child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(min % 1 == 0 ? min.toInt().toString() : min.toStringAsFixed(1), style: const TextStyle(fontSize: 9, color: Color(0xFF444444))),
            Text(max % 1 == 0 ? max.toInt().toString() : max.toStringAsFixed(1), style: const TextStyle(fontSize: 9, color: Color(0xFF444444))),
          ]),
        ),
      ]),
    );
  }

  // ── EQ master toggle row (used for both Slider EQ and Graphic EQ) ───────────
  Widget _buildEqToggleRow({required String label, required bool value, required ValueChanged<bool> onChanged}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, letterSpacing: 1.5, color: Color(0xFFE0E0E0), fontWeight: FontWeight.w700)),
        Switch(
          value: value,
          onChanged: onChanged,
          activeColor: const Color(0xFFFF6B00),
        ),
      ]),
    );
  }

  // ── Spectrogram strip: shows WHEN a bad frequency happens in the original clip ─
  Widget _buildSpectrogramStrip() {
    if (_isGeneratingSpectrogram) {
      return Container(
        height: 90,
        margin: const EdgeInsets.only(bottom: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: const Color(0xFF0F0F0F), border: Border.all(color: const Color(0xFF2A2A2A)), borderRadius: BorderRadius.circular(6)),
        child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF6B00))),
          SizedBox(width: 10),
          Text('Analyzing audio…', style: TextStyle(fontSize: 10, color: Color(0xFF888888))),
        ]),
      );
    }
    if (_spectrogramFile == null) return const SizedBox.shrink();

    final activeCtrl = (_showingEnhanced && _enhancedController != null) ? _enhancedController! : _videoController;
    final duration = activeCtrl?.value.duration ?? Duration.zero;
    final position = activeCtrl?.value.position ?? Duration.zero;
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('AUDIO SPECTROGRAM (original) — find where the bad frequency happens', style: TextStyle(fontFamily: 'monospace', fontSize: 9, letterSpacing: 0.6, color: Color(0xFF888888))),
        const SizedBox(height: 6),
        AspectRatio(
          aspectRatio: 1024 / 300,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(fit: StackFit.expand, children: [
              Image.file(_spectrogramFile!, fit: BoxFit.fill),
              CustomPaint(painter: _SpectrogramOverlayPainter(progress: progress, duration: duration)),
            ]),
          ),
        ),
      ]),
    );
  }


  // ── Graphic parametric EQ section: band buttons + draggable graph ───────────
  Widget _buildGraphicEqSection() {
    final bands = _graphicBands;
    final selected = bands.firstWhere((b) => b.id == _selectedGraphicBandId, orElse: () => bands.firstWhere((b) => b.id == '2'));

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildSpectrogramStrip(),
        // band enable buttons
        Wrap(spacing: 6, runSpacing: 6, children: bands.map((b) {
          final isSelected = b.id == _selectedGraphicBandId;
          return GestureDetector(
            onTap: () {
              setState(() { _selectedGraphicBandId = b.id; });
              if (!b.enabled && !b.isLocked) _toggleGraphicBand(b.id);
            },
            onLongPress: b.isLocked ? null : () => _toggleGraphicBand(b.id),
            child: Container(
              width: 34, height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: b.enabled ? const Color(0xFFFF6B00).withOpacity(isSelected ? 1.0 : 0.55) : const Color(0xFF1E1E1E),
                border: Border.all(color: isSelected ? const Color(0xFFFF6B00) : const Color(0xFF2E2E2E)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(b.id, style: TextStyle(fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.w700, color: b.enabled ? Colors.black : const Color(0xFF888888))),
            ),
          );
        }).toList()),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Tap to select · long-press to enable/disable · drag point to shape', style: TextStyle(fontSize: 9, color: Color(0xFF555555))),
            Text(
              selected.type == EqBandType.highpass || selected.type == EqBandType.lowpass
                  ? '${selected.id}: ${selected.freqHz.round()} Hz'
                  : '${selected.id}: ${selected.freqHz.round()} Hz · ${selected.gainDb >= 0 ? "+" : ""}${selected.gainDb.toStringAsFixed(1)} dB',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFFFF6B00)),
            ),
          ]),
        ),
        // graph
        AspectRatio(
          aspectRatio: 16 / 9,
          child: LayoutBuilder(builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            return GestureDetector(
              onPanStart: (d) => _handleGraphDrag(d.localPosition, size),
              onPanUpdate: (d) => _handleGraphDrag(d.localPosition, size),
              child: CustomPaint(
                size: size,
                painter: _GraphicEqPainter(bands: bands, selectedId: _selectedGraphicBandId),
              ),
            );
          }),
        ),
        const SizedBox(height: 10),
        // width / Q control for the selected band (only meaningful for bell/shelf bands)
        if (selected.type != EqBandType.highpass && selected.type != EqBandType.lowpass)
          _buildParamSlider(
            'BAND ${selected.id} WIDTH (Q)',
            selected.q.toStringAsFixed(2),
            selected.q, 0.1, 40.0, null,
            (v) => _updateGraphicBand(selected.id, (b) => b.copyWith(q: v)),
          ),
      ]),
    );
  }

  // Converts a drag/tap position on the graph into frequency (log-scale) + gain,
  // and updates the currently selected band.
  static const double _graphMinFreq = 20;
  static const double _graphMaxFreq = 20000;
  static const double _graphMaxGainDb = 12;

  void _handleGraphDrag(Offset localPos, Size size) {
    final bands = _graphicBands;
    final band = bands.firstWhere((b) => b.id == _selectedGraphicBandId, orElse: () => bands.firstWhere((b) => b.id == '2'));
    if (!band.enabled) return;

    final dx = (localPos.dx / size.width).clamp(0.0, 1.0);
    final logMin = math.log(_graphMinFreq);
    final logMax = math.log(_graphMaxFreq);
    final freq = math.exp(logMin + dx * (logMax - logMin)).clamp(_graphMinFreq, _graphMaxFreq);

    double? gain;
    if (band.type != EqBandType.highpass && band.type != EqBandType.lowpass) {
      final dy = (localPos.dy / size.height).clamp(0.0, 1.0);
      gain = (_graphMaxGainDb - dy * 2 * _graphMaxGainDb).clamp(-_graphMaxGainDb, _graphMaxGainDb);
    }

    _updateGraphicBand(band.id, (b) => b.copyWith(freqHz: freq, gainDb: gain ?? b.gainDb));
  }



  // ── Pipeline readout ──────────────────────────────────────────────────────
  Widget _buildPipelineReadout() {
    final stages = [
      ('HPF',   '${_params.hpfHz}Hz cut',          'Removes wind buffet & chassis rumble'),
      ('LPF',   '${_params.lpfHz}Hz cut',          'Strips tyre hiss & valve tick'),
      ('EQ80',  '${_params.eq80Gain >= 0 ? '+' : ''}${_params.eq80Gain.toStringAsFixed(1)}dB@80Hz',     'Sub-bass body'),
      ('EQ200', '${_params.eq200Gain >= 0 ? '+' : ''}${_params.eq200Gain.toStringAsFixed(1)}dB@200Hz',   'Mid-bass harmonic body'),
      ('EQ2.5k','${_params.eq2500Gain >= 0 ? '+' : ''}${_params.eq2500Gain.toStringAsFixed(1)}dB@2500Hz','Engine bark & firing snap'),
      ('EQ4k',  '${_params.eq4000Gain >= 0 ? '+' : ''}${_params.eq4000Gain.toStringAsFixed(1)}dB@4000Hz','Upper mid presence'),
      ('EQ6k',  '${_params.eq6000Gain >= 0 ? '+' : ''}${_params.eq6000Gain.toStringAsFixed(1)}dB@6000Hz','Attack & bite'),
      ('EQ10k', '${_params.eq10000Gain >= 0 ? '+' : ''}${_params.eq10000Gain.toStringAsFixed(1)}dB@10kHz','Air & sparkle'),
      ('COMP',  '${_params.compThresh.toStringAsFixed(0)}dB / ${_params.compRatio.toStringAsFixed(1)}:1', 'Broadcast-density compression'),
      ('VOL',   '${_params.volDb >= 0 ? '+' : ''}${_params.volDb.toStringAsFixed(1)}dB', 'Output level trim'),
      ('LIM',   '${_params.limDb.toStringAsFixed(1)}dBFS ceiling', 'Hard limiter — zero clip'),
    ];
    return Column(children: stages.asMap().entries.map((entry) {
      final i = entry.key; final s = entry.value;
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 44, child: Column(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            decoration: BoxDecoration(color: const Color(0xFF1E1E1E), border: Border.all(color: const Color(0xFF2E2E2E)), borderRadius: BorderRadius.circular(2)),
            child: Text(s.$1, style: const TextStyle(fontFamily: 'monospace', fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFFFF6B00), letterSpacing: 0.5), textAlign: TextAlign.center)),
          if (i < stages.length - 1) Container(width: 1, height: 20, color: const Color(0xFF2A2A2A)),
        ])),
        const SizedBox(width: 12),
        Expanded(child: Padding(padding: const EdgeInsets.only(top: 2, bottom: 18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.$2, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFE0E0E0), letterSpacing: 0.3)),
          const SizedBox(height: 2),
          Text(s.$3, style: const TextStyle(fontSize: 11, color: Color(0xFF555555), height: 1.3)),
        ]))),
      ]);
    }).toList());
  }

  // ── Enhance / Save button ────────────────────────────────────────────────
  Widget _buildEnhanceButton() {
    final hasEnhanced = _enhancedFile != null;
    final canProcess  = _videoFile != null && !_isLoading;

    if (hasEnhanced) {
      // Show two buttons: re-enhance or save to gallery
      return Column(children: [
        ElevatedButton.icon(
          onPressed: canProcess ? _saveEnhancedToGallery : null,
          icon: const Icon(Icons.save_alt, size: 20),
          label: const Text('SAVE ENHANCED TO GALLERY'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: canProcess ? _processVideo : null,
          icon: const Icon(Icons.bolt, size: 18, color: Color(0xFFFF6B00)),
          label: const Text('RE-ENHANCE WITH NEW SETTINGS', style: TextStyle(color: Color(0xFFFF6B00))),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            side: const BorderSide(color: Color(0xFFFF6B00)),
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
            textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 1.4),
          ),
        ),
      ]);
    }

    return AnimatedOpacity(
      opacity: canProcess ? 1.0 : 0.35, duration: const Duration(milliseconds: 200),
      child: ElevatedButton.icon(
        onPressed: canProcess ? _processVideo : null,
        icon: const Icon(Icons.bolt, size: 20),
        label: const Text('ENHANCE AUDIO'),
      ),
    );
  }

  Future<void> _saveEnhancedToGallery() async {
    if (_enhancedFile == null) return;
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final saved = await _saveToGallery(_enhancedFile!.path, timestamp);
      _showSuccessSheet(saved);
    } catch (e) {
      _showStatus('Gallery save failed: $e', isError: true);
    }
  }

  Future<void> _applyTrim() async {
    if (_videoFile == null) return;
    if (!_isTrimmed) return;

    setState(() => _isLoading = true);

    final cacheDir = await getTemporaryDirectory();
    final trimmedPath = '${cacheDir.path}/trimmed_${DateTime.now().millisecondsSinceEpoch}.mp4';

    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-ss', _trimStart.inSeconds.toString(),
      '-to', _trimEnd.inSeconds.toString(),
      '-i', _videoFile!.path,
      '-c', 'copy',
      trimmedPath,
    ]);

    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      setState(() => _isLoading = false);
      _showStatus('Trim failed.', isError: true);
      return;
    }

    // Clear enhanced — trim changes the source so enhanced is now invalid
    await _enhancedController?.dispose();

    final trimmedFile = File(trimmedPath);
    await _initVideoController(trimmedFile);

    setState(() {
      _videoFile        = trimmedFile;
      _enhancedFile     = null;
      _enhancedController = null;
      _showingEnhanced  = false;
      _isTrimmed        = false;
      _isLoading        = false;
    });

    _showStatus('Trim applied — ${_trimEnd.inSeconds - _trimStart.inSeconds}s clip locked in.', isError: false);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Divider label ─────────────────────────────────────────────────────────
  Widget _buildDividerLabel(String label) => Row(children: [
    Text(label, style: const TextStyle(fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 2.5, color: Color(0xFF444444))),
    const SizedBox(width: 10),
    Expanded(child: Container(height: 1, color: const Color(0xFF222222))),
  ]);

  Widget _buildGroupLabel(String label) => Text(label, style: const TextStyle(fontFamily: 'monospace', fontSize: 9, letterSpacing: 1.8, color: Color(0xFF555555)));

  // ─────────────────────────────────────────────────────────────────────────
  // SA3 Panel
  // ─────────────────────────────────────────────────────────────────────────
  Future<File?> _mergeSa3AudioWithVideo(
      File sourceVideo,
      File generatedAudio,
      ) async {

    final cacheDir = await getTemporaryDirectory();

    final outPath =
        '${cacheDir.path}/sa3_video_${DateTime.now().millisecondsSinceEpoch}.mp4';

    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-i', sourceVideo.path,
      '-i', generatedAudio.path,
      '-map', '0:v:0',
      '-map', '1:a:0',
      '-c:v', 'copy',
      '-c:a', 'aac',
      '-shortest',
      outPath,
    ]);

    final rc = await session.getReturnCode();

    if (!ReturnCode.isSuccess(rc)) {
      return null;
    }

    return File(outPath);
  }

  /// Grab the audio track from the enhanced/original file and send to SA3.
  Future<void> _runSa3() async {
    final sourceFile = _enhancedFile ?? _videoFile;
    if (sourceFile == null) {
      _showStatus('Enhance a video first, then run SA3.', isError: true);
      return;
    }
    final rawUrl = _useLocalBackend
        ? _sa3LocalUrlCtrl.text.trim()
        : _sa3HfUrlCtrl.text.trim();
    if (rawUrl.isEmpty) {
      _showStatus('Paste your Colab ngrok URL first.', isError: true);
      return;
    }
    final baseUrl = rawUrl.endsWith('/') ? rawUrl.substring(0, rawUrl.length - 1) : rawUrl;
    await _saveSa3Url(baseUrl); // persist for next session

    setState(() { _sa3Loading = true; _sa3Status = 'Starting…'; _sa3OutputFile = null; });

    // Extract audio to WAV first (FFmpeg handles mp4 → wav)
    final cacheDir  = await getTemporaryDirectory();
    final wavPath   = '${cacheDir.path}/sa3_input_${DateTime.now().millisecondsSinceEpoch}.wav';

    final ffSess = await FFmpegKit.executeWithArguments([
      '-y', '-i', sourceFile.path,
      '-vn', '-ar', '44100', '-ac', '2',
      wavPath,
    ]);
    if (!ReturnCode.isSuccess(await ffSess.getReturnCode())) {
      setState(() { _sa3Loading = false; _sa3Status = 'Audio extraction failed.'; });
      return;
    }

    _sa3Service = StableAudioService(baseUrl);
    final result = await _sa3Service!.process(
      audioPath:  wavPath,
      params:     _sa3Params,
      outputDir:  cacheDir.path,
      onStatus:   (s) { if (mounted) setState(() => _sa3Status = s); },
    );

    if (!mounted) return;

    if (result.success) {

      final audioFile = File(result.outputPath!);

      final sourceVideo =
          _enhancedFile ?? _videoFile;

      if (sourceVideo == null) {
        setState(() {
          _sa3Loading = false;
          _sa3Status =
          'Audio generated but source video missing.';
        });
        return;
      }

      final mergedVideo =
      await _mergeSa3AudioWithVideo(
        sourceVideo,
        audioFile,
      );

      if (mergedVideo == null) {
        setState(() {
          _sa3Loading = false;
          _sa3Status =
          'Audio generated but video merge failed.';
        });
        return;
      }

      _sa3VideoController?.dispose();

      final controller =
      VideoPlayerController.file(mergedVideo);

      await controller.initialize();

      setState(() {
        _sa3Loading = false;

        _sa3OutputFile = audioFile;

        _sa3VideoFile = mergedVideo;

        _sa3VideoController = controller;

        _sa3Status =
        'Done! Preview ready.';
      });
    } else {
      setState(() {
        _sa3Loading = false;
        _sa3Status  = result.error ?? 'Unknown error';
      });
      _showStatus(result.error ?? 'SA3 failed', isError: true);
    }

    // Clean up temp WAV
    try { File(wavPath).deleteSync(); } catch (_) {}
  }

  Future<void> _saveSa3Output() async {

    if (_sa3VideoFile == null) return;

    try {

      final hasAccess =
      await Gal.hasAccess(toAlbum: true);

      if (!hasAccess) {

        final granted =
        await Gal.requestAccess(toAlbum: true);

        if (!granted) {
          throw Exception('Gallery access denied.');
        }
      }

      await Gal.putVideo(
        _sa3VideoFile!.path,
        album: 'ExhaustStudio SA3',
      );

      _showStatus(
        'SA3 video saved to Gallery',
        isError: false,
      );

    } catch (e) {

      _showStatus(
        'Save failed: $e',
        isError: true,
      );
    }
  }
  Widget _buildLoraToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          border: Border.all(
            color: value ? const Color(0xFFFF6B00) : const Color(0xFF2A2A2A),
            width: value ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: value ? const Color(0xFFFF6B00) : Colors.transparent,
              border: Border.all(
                color: value ? const Color(0xFFFF6B00) : const Color(0xFF555555),
              ),
              borderRadius: BorderRadius.circular(3),
            ),
            child: value
                ? const Icon(Icons.check, size: 12, color: Colors.black)
                : null,
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: value
                  ? const Color(0xFFFF6B00)
                  : const Color(0xFF888888),
            ),
          ),
        ]),
      ),
    );
  }
  Widget _buildSa3Panel() {
    // Schedulers matching Cell 9: karras / normal / exponential
    // const schedulers = ['karras', 'normal', 'exponential']; //

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ── Collapsible header ───────────────────────────────────────────────
      GestureDetector(
        onTap: () => setState(() => _sa3PanelOpen = !_sa3PanelOpen),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            border: Border.all(color: const Color(0xFF2A2A2A)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(children: [
            const Icon(Icons.auto_awesome, color: Color(0xFFFF6B00), size: 15),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('STABLE AUDIO 3 · AI REGENERATE',
                style: TextStyle(fontFamily: 'monospace', fontSize: 11, fontWeight: FontWeight.w700,
                    letterSpacing: 1.2, color: Color(0xFFCCCCCC))),
            ),
            Icon(_sa3PanelOpen ? Icons.expand_less : Icons.expand_more,
                color: const Color(0xFF555555), size: 18),
          ]),
        ),
      ),

      if (_sa3PanelOpen) ...[
        const SizedBox(height: 16),

        // ── Cloudflare URL ────────────────────────────────────────────────
        _buildGroupLabel('LOCAL COMFYUI URL'),
        const SizedBox(height: 6),

        TextField(
          controller: _sa3LocalUrlCtrl,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: Color(0xFFE8E8E8),
          ),
          decoration: InputDecoration(
            hintText: 'http://100.x.x.x:8188',
            filled: true,
            fillColor: const Color(0xFF1A1A1A),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            suffixIcon: IconButton(
              icon: const Icon(Icons.close, size: 16),
              onPressed: () async {
                _sa3LocalUrlCtrl.clear();
                await _saveSa3Url('');
                setState(() {});
              },
            ),
          ),
          onChanged: (_) async {
            await _saveSa3Url('');
            setState(() {});
          },
        ),

        const SizedBox(height: 8),

        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton(
            onPressed: () async {
              final clip =
              await Clipboard.getData(Clipboard.kTextPlain);

              if (clip?.text != null) {
                _sa3LocalUrlCtrl.text = clip!.text!.trim();

                await _saveSa3Url('');

                setState(() {});
              }
            },
            child: const Text('PASTE'),
          ),
        ),

        const SizedBox(height: 20),

        _buildGroupLabel('HUGGING FACE URL'),
        const SizedBox(height: 6),

        TextField(
          controller: _sa3HfUrlCtrl,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: Color(0xFFE8E8E8),
          ),
          decoration: InputDecoration(
            hintText: 'https://your-space.hf.space',
            filled: true,
            fillColor: const Color(0xFF1A1A1A),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
            ),
            suffixIcon: IconButton(
              icon: const Icon(Icons.close, size: 16),
              onPressed: () async {
                _sa3HfUrlCtrl.clear();

                await _saveSa3Url('');

                setState(() {});
              },
            ),
          ),
          onChanged: (_) async {
            await _saveSa3Url('');

            setState(() {});
          },
        ),

        const SizedBox(height: 8),

        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton(
            onPressed: () async {
              final clip =
              await Clipboard.getData(Clipboard.kTextPlain);

              if (clip?.text != null) {
                _sa3HfUrlCtrl.text = clip!.text!.trim();

                await _saveSa3Url('');

                setState(() {});
              }
            },
            child: const Text('PASTE'),
          ),
        ),

        const SizedBox(height: 20),

        _buildGroupLabel('AI BACKEND'),
        const SizedBox(height: 8),

        RadioListTile<bool>(
          value: true,
          groupValue: _useLocalBackend,
          activeColor: const Color(0xFFFF6B00),
          title: const Text(
            'LOCAL PC (TAILSCALE)',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: Color(0xFFE8E8E8),
            ),
          ),
          onChanged: (v) async {
            setState(() => _useLocalBackend = true);
            await _saveSa3Url('');
          },
        ),

        RadioListTile<bool>(
          value: false,
          groupValue: _useLocalBackend,
          activeColor: const Color(0xFFFF6B00),
          title: const Text(
            'HUGGING FACE',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: Color(0xFFE8E8E8),
            ),
          ),
          onChanged: (v) async {
            setState(() => _useLocalBackend = false);
            await _saveSa3Url('');
          },
        ),

        const SizedBox(height: 12),

        // ── Prompt ────────────────────────────────────────────────────────
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _buildGroupLabel('PROMPT'),
          if (_sa3Params.prompt != _kDefaultSa3Prompt)
            GestureDetector(
              onTap: () {
                _promptController.text = _kDefaultSa3Prompt;
                _negativePromptController.text = _kDefaultNegSa3Prompt;

                setState(() {
                  _sa3Params = const Sa3Params(
                    prompt: _kDefaultSa3Prompt,
                    negativePrompt: _kDefaultNegSa3Prompt,
                    seed: -1,
                    denoise: 0.4,
                    cfg: 1.0,
                    steps: 8,
                  );
                });
              },
              child: const Text('RESET TO DEFAULT',
                style: TextStyle(fontFamily: 'monospace', fontSize: 8,
                    letterSpacing: 1.1, color: Color(0xFFFF6B00))),
            ),
        ]),
        const SizedBox(height: 6),
        TextField(
          controller: _promptController,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFE8E8E8)),
          maxLines: 4,
          onChanged: (v) => setState(() => _sa3Params = _sa3Params.copyWith(prompt: v)),
          decoration: InputDecoration(
            hintText: 'Describe the sound to generate…',
            hintStyle: const TextStyle(color: Color(0xFF444444), fontSize: 11),
            filled: true, fillColor: const Color(0xFF1A1A1A),
            contentPadding: const EdgeInsets.all(12),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: Color(0xFFFF6B00))),
          ),
        ),
        const SizedBox(height: 20),

        // Negative prompt //

        _buildGroupLabel('NEGATIVE PROMPT'),
        const SizedBox(height: 6),
        TextField(
          controller: _negativePromptController,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: Color(0xFFE8E8E8),
          ),
          maxLines: 4,
          onChanged: (v) => setState(
                () => _sa3Params = _sa3Params.copyWith(
              negativePrompt: v,
            ),
          ),
          decoration: InputDecoration(
            hintText: 'Describe sounds to avoid…',
            hintStyle: const TextStyle(
              color: Color(0xFF444444),
              fontSize: 11,
            ),
            filled: true,
            fillColor: const Color(0xFF1A1A1A),
            contentPadding: const EdgeInsets.all(12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(
                color: Color(0xFF2A2A2A),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: const BorderSide(
                color: Color(0xFFFF6B00),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),

        // CFG //

        _buildGroupLabel('CFG SCALE'),
        const SizedBox(height: 6),

        Row(
          children: [
            Expanded(
              child: Slider(
                value: _sa3Params.cfg,
                min: 0.5,
                max: 8.0,
                divisions: 75,
                label: _sa3Params.cfg.toStringAsFixed(1),
                onChanged: (v) {
                  setState(() {
                    _sa3Params = _sa3Params.copyWith(cfg: v);
                  });
                },
              ),
            ),
            SizedBox(
              width: 45,
              child: Text(
                _sa3Params.cfg.toStringAsFixed(1),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // Steps //

        _buildGroupLabel('STEPS'),
        const SizedBox(height: 6),

        Row(
          children: [
            Expanded(
              child: Slider(
                value: _sa3Params.steps.toDouble(),
                min: 4,
                max: 20,
                divisions: 16,
                label: _sa3Params.steps.toString(),
                onChanged: (v) {
                  setState(() {
                    _sa3Params =
                        _sa3Params.copyWith(
                            steps: v.round());
                  });
                },
              ),
            ),
            SizedBox(
              width: 45,
              child: Text(
                _sa3Params.steps.toString(),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),

        const SizedBox(height: 20),

        // ── LoRA Selection ─────────────────────────────────────────────
        _buildDividerLabel('LORA'),
        const SizedBox(height: 10),
        _buildLoraToggle('HARLEY DAVIDSON', _sa3Params.useHarleyLora,
                (v) => setState(() => _sa3Params = _sa3Params.copyWith(useHarleyLora: v))),
        if (_sa3Params.useHarleyLora)
          _buildParamSlider('HARLEY STRENGTH',
              _sa3Params.harleyLoraStrength.toStringAsFixed(2),
              _sa3Params.harleyLoraStrength, 0.0, 2.0, null,
                  (v) => setState(() => _sa3Params = _sa3Params.copyWith(
                  harleyLoraStrength: (v * 20).round() / 20))),
        const SizedBox(height: 8),
        _buildLoraToggle('SUPER METEOR', _sa3Params.useMeteorLora,
                (v) => setState(() => _sa3Params = _sa3Params.copyWith(useMeteorLora: v))),
        if (_sa3Params.useMeteorLora)
          _buildParamSlider('METEOR STRENGTH',
              _sa3Params.meteorLoraStrength.toStringAsFixed(2),
              _sa3Params.meteorLoraStrength, 0.0, 2.0, null,
                  (v) => setState(() => _sa3Params = _sa3Params.copyWith(
                  meteorLoraStrength: (v * 20).round() / 20))),
        const SizedBox(height: 8),
        _buildLoraToggle('SUPER METEOR 2', _sa3Params.useMeteorLora2,
                (v) => setState(() => _sa3Params = _sa3Params.copyWith(useMeteorLora2: v))),
        if (_sa3Params.useMeteorLora2)
          _buildParamSlider('METEOR 2 STRENGTH',
              _sa3Params.meteorLora2Strength.toStringAsFixed(2),
              _sa3Params.meteorLora2Strength, 0.0, 2.0, null,
                  (v) => setState(() => _sa3Params = _sa3Params.copyWith(
                  meteorLora2Strength: (v * 20).round() / 20))),

                        // ── Denoise ───────────────────────────────────────────────────────
        _buildParamSlider(
          'DENOISE',
          _sa3Params.denoise.toStringAsFixed(2),
          _sa3Params.denoise, 0.0, 1.0, null,
          (v) => setState(() => _sa3Params = _sa3Params.copyWith(
              denoise: (v * 100).round() / 100)),
        ),

        // ── Add noise ───────────────────────────────────────────────────────

        _buildLoraToggle('ADD NOISE', _sa3Params.addNoise,
                (v) => setState(() => _sa3Params = _sa3Params.copyWith(addNoise: v))),

        // ── Seed ─────────────────────────────────────────────────────────
        _buildGroupLabel('SEED  (−1 = random)'),
        const SizedBox(height: 6),
        TextField(
          keyboardType: TextInputType.number,
          controller: TextEditingController(text: _sa3Params.seed.toString()),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFE8E8E8)),
          onChanged: (v) {
            final n = int.tryParse(v);
            if (n != null) setState(() => _sa3Params = _sa3Params.copyWith(seed: n));
          },
          decoration: InputDecoration(
            hintText: '-1',
            hintStyle: const TextStyle(color: Color(0xFF444444)),
            filled: true, fillColor: const Color(0xFF1A1A1A),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: Color(0xFF2A2A2A))),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: Color(0xFFFF6B00))),
          ),
        ),
        const SizedBox(height: 20),



        // ── Status ────────────────────────────────────────────────────────
        if (_sa3Status.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              border: Border.all(color: const Color(0xFF2A2A2A)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(children: [
              if (_sa3Loading) ...[
                const SizedBox(width: 12, height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: Color(0xFFFF6B00))),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(_sa3Status,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10,
                      color: Color(0xFFAAAAAA), height: 1.4)),
              ),
            ]),
          ),

        // ── Run button ────────────────────────────────────────────────────
        AnimatedOpacity(
          opacity: 1.0,
          duration: const Duration(milliseconds: 200),
          child: ElevatedButton.icon(
            onPressed: () async {
              if (_sa3Loading) {
                await _sa3Service?.interrupt();

                if (mounted) {
                  setState(() {
                    _sa3Status = 'Interrupt requested...';
                  });
                }
              } else {
                _runSa3();
              }
            },
            icon: Icon(
              _sa3Loading ? Icons.stop : Icons.auto_awesome,
              size: 18,
            ),
            label: Text(
              _sa3Loading
                  ? 'TERMINATE PROCESS'
                  : 'SEND TO SA3 & REGENERATE',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor:
              _sa3Loading ? Colors.red : null,
            ),
          ),
        ),

        if (_sa3VideoController != null) ...[
          const SizedBox(height: 12),

          AspectRatio(
            aspectRatio:
            _sa3VideoController!.value.aspectRatio,
            child: _buildVideoPlayer(
              _sa3VideoController!,
              false,
            ),
          ),

          const SizedBox(height: 12),
        ],
        // ── Save result ───────────────────────────────────────────────────
        if (_sa3OutputFile != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _saveSa3Output,
            icon: const Icon(Icons.save_alt, size: 18, color: Color(0xFF00E676)),
            label: const Text('SAVE SA3 OUTPUT TO GALLERY',
              style: TextStyle(color: Color(0xFF00E676))),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              side: const BorderSide(color: Color(0xFF00E676)),
              shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(4))),
              textStyle: const TextStyle(
                  fontFamily: 'monospace', fontSize: 13,
                  fontWeight: FontWeight.w700, letterSpacing: 1.2),
            ),
          ),
        ],
        const SizedBox(height: 8),
      ],
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Graphic parametric EQ — custom painter (grid + response curve + draggable points)
// ─────────────────────────────────────────────────────────────────────────────
class _GraphicEqPainter extends CustomPainter {
  final List<GraphicEqBand> bands;
  final String selectedId;

  _GraphicEqPainter({required this.bands, required this.selectedId});

  static const double _minFreq = 20;
  static const double _maxFreq = 20000;
  static const double _maxGainDb = 12;

  double _xForFreq(double freq, double width) {
    final logMin = math.log(_minFreq);
    final logMax = math.log(_maxFreq);
    final t = (math.log(freq.clamp(_minFreq, _maxFreq)) - logMin) / (logMax - logMin);
    return t * width;
  }

  double _yForGain(double gainDb, double height) {
    final t = (gainDb.clamp(-_maxGainDb, _maxGainDb) + _maxGainDb) / (2 * _maxGainDb);
    return height - t * height;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF0F0F0F);
    canvas.drawRect(Offset.zero & size, bg);

    final gridPaint = Paint()
      ..color = const Color(0xFF222222)
      ..strokeWidth = 1;

    const freqMarkers = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000];
    for (final f in freqMarkers) {
      final x = _xForFreq(f.toDouble(), size.width);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (final g in [-12, -6, 0, 6, 12]) {
      final y = _yForGain(g.toDouble(), size.height);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), g == 0 ? (Paint()..color = const Color(0xFF3A3A3A)..strokeWidth = 1.2) : gridPaint);
    }

    // frequency axis labels (bottom edge)
    const labelStyle = TextStyle(fontFamily: 'monospace', fontSize: 8, color: Color(0xFF666666));
    for (final f in freqMarkers) {
      final x = _xForFreq(f.toDouble(), size.width);
      final label = f >= 1000 ? '${(f / 1000).toStringAsFixed(f % 1000 == 0 ? 0 : 1)}k' : '$f';
      final tp = TextPainter(text: TextSpan(text: label, style: labelStyle), textDirection: TextDirection.ltr)..layout();
      // keep labels inside the canvas at the edges
      double tx = x - tp.width / 2;
      if (tx < 0) tx = 0;
      if (tx + tp.width > size.width) tx = size.width - tp.width;
      tp.paint(canvas, Offset(tx, size.height - tp.height - 1));
    }

    // dB axis labels (left edge)
    for (final g in [-12, -6, 0, 6, 12]) {
      final y = _yForGain(g.toDouble(), size.height);
      final label = g > 0 ? '+${g}dB' : '${g}dB';
      final tp = TextPainter(text: TextSpan(text: label, style: labelStyle), textDirection: TextDirection.ltr)..layout();
      double ty = y - tp.height / 2;
      if (ty < 0) ty = 0;
      if (ty + tp.height > size.height) ty = size.height - tp.height;
      tp.paint(canvas, Offset(2, ty));
    }

    final curvePath = Path();
    const steps = 120;
    for (int i = 0; i <= steps; i++) {
      final t = i / steps;
      final logMin = math.log(_minFreq);
      final logMax = math.log(_maxFreq);
      final freq = math.exp(logMin + t * (logMax - logMin));
      double gainSum = 0;
      for (final b in bands) {
        if (!b.enabled) continue;
        gainSum += _approxBandGainAt(b, freq);
      }
      final x = t * size.width;
      final y = _yForGain(gainSum, size.height);
      if (i == 0) {
        curvePath.moveTo(x, y);
      } else {
        curvePath.lineTo(x, y);
      }
    }
    canvas.drawPath(
      curvePath,
      Paint()
        ..color = const Color(0xFFFF6B00)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    for (final b in bands) {
      if (!b.enabled) continue;
      final x = _xForFreq(b.freqHz, size.width);
      final y = (b.type == EqBandType.highpass || b.type == EqBandType.lowpass)
          ? size.height - 10
          : _yForGain(b.gainDb, size.height);
      final isSelected = b.id == selectedId;

      final pointPaint = Paint()..color = isSelected ? const Color(0xFFFF6B00) : const Color(0xFFE0E0E0);
      canvas.drawCircle(Offset(x, y), isSelected ? 8 : 6, pointPaint);
      canvas.drawCircle(Offset(x, y), isSelected ? 8 : 6, Paint()..color = Colors.black..style = PaintingStyle.stroke..strokeWidth = 1.5);

      final textPainter = TextPainter(
        text: TextSpan(text: b.id, style: const TextStyle(fontFamily: 'monospace', fontSize: 9, fontWeight: FontWeight.w700, color: Colors.black)),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(x - textPainter.width / 2, y - textPainter.height / 2));
    }
  }

  /// Rough single-band gain contribution at a given frequency, for curve drawing only
  /// (not an accurate biquad response — just enough to visualize shape/width).
  double _approxBandGainAt(GraphicEqBand b, double freq) {
    switch (b.type) {
      case EqBandType.bell:
        final octaves = (math.log(freq) - math.log(b.freqHz)) / math.log(2);
        final width = (1 / b.q).clamp(0.01, 6.0);
        final bump = math.exp(-(octaves * octaves) / (2 * width * width));
        return b.gainDb * bump;
      case EqBandType.lowshelf:
        if (freq <= b.freqHz) return b.gainDb;
        final octaves = (math.log(freq) - math.log(b.freqHz)) / math.log(2);
        return b.gainDb * math.exp(-octaves.abs() / 1.5);
      case EqBandType.highshelf:
        if (freq >= b.freqHz) return b.gainDb;
        final octaves = (math.log(b.freqHz) - math.log(freq)) / math.log(2);
        return b.gainDb * math.exp(-octaves.abs() / 1.5);
      case EqBandType.highpass:
      case EqBandType.lowpass:
        return 0;
    }
  }

  @override
  bool shouldRepaint(covariant _GraphicEqPainter oldDelegate) {
    return oldDelegate.bands != bands || oldDelegate.selectedId != selectedId;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Spectrogram overlay — frequency axis labels, time axis labels, and a moving
// playhead line on top of the FFmpeg-rendered showspectrumpic PNG.
// ─────────────────────────────────────────────────────────────────────────────
class _SpectrogramOverlayPainter extends CustomPainter {
  final double progress; // 0..1, current playback position within the clip
  final Duration duration;

  _SpectrogramOverlayPainter({required this.progress, required this.duration});

  static const double _minFreq = 20;
  static const double _maxFreq = 20000;

  // showspectrumpic with orientation=vertical draws low frequency at the
  // BOTTOM and high frequency at the TOP, time left-to-right.
  double _yForFreq(double freq, double height) {
    final logMin = math.log(_minFreq);
    final logMax = math.log(_maxFreq);
    final t = (math.log(freq.clamp(_minFreq, _maxFreq)) - logMin) / (logMax - logMin);
    return height - t * height;
  }

  @override
  void paint(Canvas canvas, Size size) {
    const labelStyle = TextStyle(fontFamily: 'monospace', fontSize: 8, color: Color(0xFFCCCCCC));
    const freqMarkers = [50, 200, 1000, 5000, 20000];

    for (final f in freqMarkers) {
      final y = _yForFreq(f.toDouble(), size.height);
      canvas.drawLine(
        Offset(0, y), Offset(size.width, y),
        Paint()..color = Colors.white.withOpacity(0.08)..strokeWidth = 1,
      );
      final label = f >= 1000 ? '${(f / 1000).toStringAsFixed(0)}k' : '$f';
      final tp = TextPainter(text: TextSpan(text: label, style: labelStyle), textDirection: TextDirection.ltr)..layout();
      double ty = y - tp.height / 2;
      ty = ty.clamp(0.0, size.height - tp.height);
      // small dark backing so the label is readable over bright spectrogram pixels
      canvas.drawRect(Rect.fromLTWH(1, ty, tp.width + 3, tp.height), Paint()..color = Colors.black.withOpacity(0.55));
      tp.paint(canvas, Offset(2, ty));
    }

    // time axis labels (start / mid / end)
    final totalSec = duration.inMilliseconds / 1000.0;
    String fmt(double sec) {
      final m = (sec ~/ 60).toString();
      final s = (sec % 60).toInt().toString().padLeft(2, '0');
      return '$m:$s';
    }
    for (final t in [0.0, 0.5, 1.0]) {
      final x = t * size.width;
      final tp = TextPainter(text: TextSpan(text: fmt(totalSec * t), style: labelStyle), textDirection: TextDirection.ltr)..layout();
      double tx = x - tp.width / 2;
      tx = tx.clamp(0.0, size.width - tp.width);
      canvas.drawRect(Rect.fromLTWH(tx - 1, size.height - tp.height - 1, tp.width + 2, tp.height), Paint()..color = Colors.black.withOpacity(0.55));
      tp.paint(canvas, Offset(tx, size.height - tp.height - 1));
    }

    // playhead
    final px = progress * size.width;
    canvas.drawLine(
      Offset(px, 0), Offset(px, size.height),
      Paint()..color = const Color(0xFFFF6B00)..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _SpectrogramOverlayPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.duration != duration;
  }
}
