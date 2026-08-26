import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// ─────────────────────────────────────────────────────────────────────────────
// Result model
// ─────────────────────────────────────────────────────────────────────────────
class Sa3Result {
  final bool success;
  final String? outputPath; // local temp path of downloaded MP3
  final String? error;

  const Sa3Result.ok(this.outputPath) : success = true, error = null;
  const Sa3Result.err(this.error)     : success = false, outputPath = null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Parameters — mirrors Cell 9 exactly
// ─────────────────────────────────────────────────────────────────────────────
class Sa3Params {
  final String prompt;
  final String negativePrompt;
  final int seed;
  final double denoise;
  final double cfg;
  final int steps;
  final bool useHarleyLora;
  final double harleyLoraStrength;
  final bool useMeteorLora;
  final double meteorLoraStrength;
  final bool useMeteorLora2;
  final double meteorLora2Strength;
  final bool addNoise;

  const Sa3Params({
    required this.prompt,
    this.negativePrompt = '',
    this.seed = -1,
    this.denoise = 0.4,
    this.cfg = 1.0,
    this.steps = 8,
    this.useHarleyLora = false,
    this.harleyLoraStrength = 1.0,
    this.useMeteorLora = false,
    this.meteorLoraStrength = 1.0,
    this.useMeteorLora2 = false,
    this.meteorLora2Strength = 1.0,
    this.addNoise = false,
  });

  Sa3Params copyWith({
    String? prompt,
    String? negativePrompt,
    int? seed,
    double? denoise,
    double? cfg,
    int? steps,
    bool? useHarleyLora,
    double? harleyLoraStrength,
    bool? useMeteorLora,
    double? meteorLoraStrength,
    bool? useMeteorLora2,
    double? meteorLora2Strength,
    bool? addNoise,

  }) {
    return Sa3Params(
      prompt: prompt ?? this.prompt,
      negativePrompt: negativePrompt ?? this.negativePrompt,
      seed: seed ?? this.seed,
      denoise: denoise ?? this.denoise,
      cfg: cfg ?? this.cfg,
      steps: steps ?? this.steps,
      useHarleyLora: useHarleyLora ?? this.useHarleyLora,
      harleyLoraStrength: harleyLoraStrength ?? this.harleyLoraStrength,
      useMeteorLora: useMeteorLora ?? this.useMeteorLora,
      meteorLoraStrength: meteorLoraStrength ?? this.meteorLoraStrength,
      useMeteorLora2: useMeteorLora2 ?? this.useMeteorLora2,
      meteorLora2Strength: meteorLora2Strength ?? this.meteorLora2Strength,
      addNoise: addNoise ?? this.addNoise,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Service — pure dart:io, no third-party packages
// ─────────────────────────────────────────────────────────────────────────────
class StableAudioService {
  final String baseUrl; // e.g. "https://xxxx.trycloudflare.com"

  String? _currentPromptId;
  bool _cancelRequested = false;

  StableAudioService(this.baseUrl);

  // ── Main entry point ──────────────────────────────────────────────────────
  Future<Sa3Result> process({
    required String audioPath,
    required Sa3Params params,
    required String outputDir,
    void Function(String)? onStatus,
  }) async {
    try {
      _cancelRequested = false;
      // 1. Upload audio via multipart — ComfyUI uses /upload/image for all files
      onStatus?.call('Uploading audio to ComfyUI…');
      final uploadedName = await _uploadFile(audioPath);
      print('UPLOADED FILE: $uploadedName');
      if (uploadedName == null) {
        return Sa3Result.err('Upload failed — check the Cloudflare URL is correct and Colab is running.');
      }


      // 2. Build workflow and queue prompt
      onStatus?.call('Queuing workflow…');
      final effectiveSeed = params.seed < 0
          ? Random().nextInt(2147483647)
          : params.seed;

      final workflow = _buildWorkflow(params, effectiveSeed, uploadedName);
      print('UPLOADED FILE: $uploadedName');
      print('WORKFLOW JSON:');
      print(jsonEncode(workflow));
      final clientId = _uuid();
      final promptId = await _queuePrompt(workflow, clientId);

      if (promptId == null) {
        return Sa3Result.err('Failed to queue workflow — server may be busy.');
      }

      _currentPromptId = promptId;


      // 3. Poll /history until done
      onStatus?.call('Generating audio');
      final filename = await _pollHistory(promptId, onStatus);
      if (filename == null) {
        return Sa3Result.err('Generation timed out or no audio output found.');
      }

      // 4. Download result
      onStatus?.call('Downloading result…');
      final ext    = filename.endsWith('.mp3') ? 'mp3' : 'wav';
      final outPath = '$outputDir/sa3_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final ok = await _downloadFile(filename, outPath);
      if (!ok) return Sa3Result.err('Download failed.');

      return Sa3Result.ok(outPath);

    } on SocketException catch (e) {
      return Sa3Result.err('Cannot reach Colab — is the tunnel running?\n${e.message}');
    } on TimeoutException {
      return Sa3Result.err('Request timed out. Paste a fresh Cloudflare URL.');
    } catch (e) {
      return Sa3Result.err('Error: $e');
    }
  }

  // ── Upload file via multipart/form-data ───────────────────────────────────
  // ComfyUI endpoint: POST /upload/image  field name: "image"

  // ── Queue workflow prompt ─────────────────────────────────────────────────
  Future<String?> _uploadFile(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final name = filePath.split('/').last;

    final boundary =
        '----FlutterSA3Boundary${DateTime.now().millisecondsSinceEpoch}';

    final body = StringBuffer();
    body.write('--$boundary\r\n');
    body.write(
        'Content-Disposition: form-data; name="image"; filename="$name"\r\n');
    body.write('Content-Type: audio/mpeg\r\n\r\n');

    final header = utf8.encode(body.toString());
    final footer = utf8.encode('\r\n--$boundary--\r\n');

    final bodyBytes = [...header, ...bytes, ...footer];

    final uri = Uri.parse('$baseUrl/upload/image');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);

    final req = await client.postUrl(uri);

    req.headers.set(
        'Content-Type',
        'multipart/form-data; boundary=$boundary');

    req.headers.set(
        'Content-Length',
        bodyBytes.length.toString());

    req.headers.set(
        'ngrok-skip-browser-warning',
        'true');

    req.add(bodyBytes);

    final resp =
    await req.close().timeout(const Duration(seconds: 60));

    final respBody =
    await resp.transform(utf8.decoder).join();

    client.close();

    print('UPLOAD STATUS: ${resp.statusCode}');
    print('UPLOAD RESPONSE: $respBody');

    if (resp.statusCode == 200) {
      final json = jsonDecode(respBody);
      return json['name'];
    }

    return null;
  }
  Future<String?> _queuePrompt(
      Map<String, dynamic> workflow,
      String clientId,
      ) async {

    final uri = Uri.parse('$baseUrl/prompt');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);

    final req = await client.postUrl(uri);

    req.headers.set('Content-Type', 'application/json');
    req.headers.set('ngrok-skip-browser-warning', 'true');

    final payload = {
      'prompt': workflow,
      'client_id': clientId,
    };

    final body = jsonEncode(payload);

    print('QUEUE REQUEST:');
    print(body);

    req.write(body);

    final resp =
    await req.close().timeout(const Duration(seconds: 60));

    final respBody =
    await resp.transform(utf8.decoder).join();

    client.close();

    print('QUEUE STATUS: ${resp.statusCode}');
    print('QUEUE RESPONSE: $respBody');

    if (resp.statusCode == 200) {
      final json = jsonDecode(respBody);
      return json['prompt_id'];
    }

    return null;
  }
  // Cancel current run //

  Future<void> interrupt() async {
    _cancelRequested = true;

    final uri = Uri.parse('$baseUrl/interrupt');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);

    try {
      final req = await client.postUrl(uri);
      req.headers.set('ngrok-skip-browser-warning', 'true');

      final resp = await req.close();

      print('INTERRUPT STATUS: ${resp.statusCode}');
    } finally {
      client.close();
    }
  }

  // ── Poll /history/{id} every 5 s until output appears ────────────────────
  Future<String?> _pollHistory(
    String promptId,
    void Function(String)? onStatus, {
    int maxAttempts = 120,
  }) async {
    final uri = Uri.parse('$baseUrl/history/$promptId');

    for (var i = 0; i < maxAttempts; i++) {

      if (_cancelRequested) {
      return null;
      }
      await Future.delayed(const Duration(seconds: 2));

      try {
        final client = HttpClient();
        final req = await client.getUrl(uri);
        req.headers.set('ngrok-skip-browser-warning', 'true');
        final resp = await req.close().timeout(const Duration(seconds: 10));
        final body = await resp.transform(utf8.decoder).join();
        client.close();

        if (resp.statusCode != 200) continue;

        final hist = jsonDecode(body) as Map<String, dynamic>;
        if (!hist.containsKey(promptId)) {
          if (i % 6 == 5) onStatus?.call('Still generating… (${(i + 1) * 5}s)');
          continue;
        }

        // Prompt is done — find audio output from node "19" (SaveAudioMP3)
        final outputs = (hist[promptId] as Map)['outputs'] as Map<String, dynamic>? ?? {};
        for (final nodeOut in outputs.values) {
          final audioList = (nodeOut as Map<String, dynamic>)['audio'] as List?;
          if (audioList != null && audioList.isNotEmpty) {
            return (audioList.first as Map<String, dynamic>)['filename'] as String?;
          }
        }
        return null; // done but no audio node
      } catch (_) {
        // keep polling
      }
    }
    return null;
  }

  // ── Download output file ──────────────────────────────────────────────────
  Future<bool> _downloadFile(String filename, String savePath) async {
    final uri    = Uri.parse('$baseUrl/view?filename=$filename&type=output');
    final client = HttpClient();
    final req    = await client.getUrl(uri);
    req.headers.set('ngrok-skip-browser-warning', 'true');

    final resp = await req.close().timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) { client.close(); return false; }

    final outFile = File(savePath);
    final sink    = outFile.openWrite();
    await resp.pipe(sink);
    await sink.close();
    client.close();
    return true;
  }

  // ── Workflow JSON — exact mirror of Cell 9 (no input audio node since
  //    ComfyUI SA3 generates from text; the uploaded file is passed via
  //    EmptyLatentAudio for now; inpainting can be wired in Cell 9 later) ──
  //
  // NOTE: The uploaded audio name is stored in the workflow for future
  // inpainting use. Currently the workflow generates fresh from prompt.
  // To enable inpainting, wire node 57 to a LoadAudio→VAEEncodeAudio chain.
  Map<String, dynamic> _buildWorkflow(
      Sa3Params p,
      int seed,
      String uploadedAudioName,
      ) {
    return {
      "62": {
        "class_type": "CheckpointLoaderSimple",
        "inputs": {
          "ckpt_name": "stable_audio_3_small_sfx.safetensors",
        },
      },

      "98": {
        "class_type": "LoraLoaderModelOnly",
        "inputs": {
          "model": ["62", 0],
          "lora_name": "sa3 harley lora.ckpt",
          "strength_model": p.useHarleyLora ? p.harleyLoraStrength : 0.0,
        },
      },
      "99": {
        "class_type": "LoraLoaderModelOnly",
        "inputs": {
          "model": ["98", 0],
          "lora_name": "sa3 super meteor pure exhaust.ckpt",
          "strength_model": p.useMeteorLora ? p.meteorLoraStrength : 0.0,
        },
      },
      "100": {
        "class_type": "LoraLoaderModelOnly",
        "inputs": {
          "model": ["99", 0],
          "lora_name": "sa3 super meteor lora 2.ckpt",
          "strength_model": p.useMeteorLora2 ? p.meteorLora2Strength : 0.0,
        },
      },

      "26": {
        "class_type": "CLIPLoader",
        "inputs": {
          "clip_name": "t5gemma_b_b_ul2.safetensors",
          "type": "stable_audio",
        },
      },

      "59": {
        "class_type": "LoadAudio",
        "inputs": {
          "audio": uploadedAudioName,
        },
      },

      "61": {
        "class_type": "VAEEncodeAudio",
        "inputs": {
          "audio": ["59", 0],
          "vae": ["62", 2],
        },
      },

      "6": {
        "class_type": "CLIPTextEncode",
        "inputs": {
          "text": p.prompt,
          "clip": ["26", 0],
        },
      },

      "7": {
        "class_type": "CLIPTextEncode",
        "inputs": {
          "text": p.negativePrompt,
          "clip": ["26", 0],
        },
      },

      "81": {
        "class_type": "PingPongSampler",
        "inputs": {
          "s_noise": 1.0,
          "step_blend_mode": "lerp",
          "first_ancestral_step": 0,
          "pingpong_blend": 1.0,
          "blend_mode": "lerp",
          "last_ancestral_step": -1
        },
      },

      "80": {
        "class_type": "BasicScheduler",
        "inputs": {
          "model": ["100", 0],
          "scheduler": "kl_optimal",
          "steps": p.steps,
          "denoise": p.denoise,
        },
      },

      "79": {
        "class_type": "SamplerCustom",
        "inputs": {
          "model": ["100", 0],
          "positive": ["6", 0],
          "negative": ["7", 0],
          "sampler": ["81", 0],
          "sigmas": ["80", 0],
          "latent_image": ["61", 0],
          "noise_seed": seed,
          "cfg": p.cfg,
          "add_noise": p.addNoise,
        },
      },

      "12": {
        "class_type": "VAEDecodeAudio",
        "inputs": {
          "samples": ["79", 1],
          "vae": ["62", 2],
        },
      },

      "19": {
        "class_type": "SaveAudioMP3",
        "inputs": {
          "audio": ["12", 0],
          "filename_prefix": "sa3_flutter_out",
          "quality": "320k",
        },
      },
    };
  }

  // ── Health check ──────────────────────────────────────────────────────────
  Future<bool> ping() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final req  = await client.getUrl(Uri.parse('$baseUrl/system_stats'));
      req.headers.set('ngrok-skip-browser-warning', 'true');
      final resp = await req.close();
      client.close();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Tiny UUID v4 without package:uuid ─────────────────────────────────────
  String _uuid() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final h = bytes.map(hex).toList();
    return '${h.sublist(0,4).join()}-${h.sublist(4,6).join()}-'
           '${h.sublist(6,8).join()}-${h.sublist(8,10).join()}-'
           '${h.sublist(10).join()}';
  }
}
