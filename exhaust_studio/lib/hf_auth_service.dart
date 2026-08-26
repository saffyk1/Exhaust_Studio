// ─────────────────────────────────────────────────────────────────────────────
// Hugging Face OAuth + Space auto-cloning
//
// Lets a user sign in with their own Hugging Face account and have this app's
// Stable Audio 3 Space (saifvj/stable-audio-api) duplicated into their own
// account automatically — no manual ComfyUI/Tailscale setup required.
//
// Flow:
//   1. connect() opens the system browser to HF's OAuth authorize page
//      (PKCE, no client secret needed — this is a public/native app).
//   2. HF redirects back to this app via the `exhauststudio://callback`
//      custom URL scheme, captured by flutter_web_auth_2.
//   3. Exchange the authorization code for an access token.
//   4. Look up the signed-in user's username (whoami-v2).
//   5. Call the Space "duplicate" endpoint to clone saifvj/stable-audio-api
//      into <username>/exhaust-studio-audio (private by default).
//   6. Poll the new Space's runtime until it's RUNNING (first build can take
//      a few minutes since it has to build the ComfyUI Docker image).
//   7. Return the live Space URL for use as StableAudioService's baseUrl.
//
// IMPORTANT — one-time manual setup required (see README.md):
// You must register a free OAuth application at
// https://huggingface.co/settings/applications/new with:
//   - Redirect URI: exhauststudio://callback
//   - Scopes: read-repos, write-repos
// and paste the resulting Client ID into `hfOAuthClientId` below. This is a
// one-time step for the app's developer (you), not something each end user
// has to do — end users only sign in with their own HF account.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

/// Fill this in after registering the OAuth app on huggingface.co.
/// See README.md → "One-time developer setup" for exact steps.
const String hfOAuthClientId = '61436169-b99e-48f6-8b08-3373878e619a';

/// Must exactly match the redirect URI registered on huggingface.co,
/// and match the intent-filter added in AndroidManifest.xml.
const String hfRedirectUri = 'exhauststudio://callback';
const String hfCallbackScheme = 'exhauststudio';

/// The Space this app clones for each new user. Change if you fork this
/// project and host your own source Space.
const String hfSourceSpace = 'saifvj/stable-audio-api';

/// Name given to the cloned Space in the user's own account.
const String hfClonedSpaceName = 'exhaust-studio-audio';

class HfCloneResult {
  final bool success;
  final String? spaceUrl;   // e.g. https://username-exhaust-studio-audio.hf.space
  final String? username;
  final String? error;

  const HfCloneResult.ok({required this.spaceUrl, required this.username})
      : success = true, error = null;
  const HfCloneResult.err(this.error)
      : success = false, spaceUrl = null, username = null;
}

class HfAuthService {
  /// Runs the full connect → duplicate → wait-until-running flow.
  /// [onStatus] is called with human-readable progress updates for the UI.
  static Future<HfCloneResult> connectAndClone({
    void Function(String)? onStatus,
  }) async {
    if (hfOAuthClientId == 'REPLACE_WITH_YOUR_HF_OAUTH_CLIENT_ID') {
      return const HfCloneResult.err(
        'App is not configured with a Hugging Face OAuth Client ID yet. '
        'See README.md — this is a one-time setup step for the app developer.',
      );
    }

    try {
      onStatus?.call('Opening Hugging Face sign-in…');
      final verifier = _randomVerifier();
      final challenge = _codeChallenge(verifier);

      final authorizeUri = Uri.https('huggingface.co', '/oauth/authorize', {
        'client_id': hfOAuthClientId,
        'redirect_uri': hfRedirectUri,
        'response_type': 'code',
        'scope': 'read-repos write-repos',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      });

      final resultUrl = await FlutterWebAuth2.authenticate(
        url: authorizeUri.toString(),
        callbackUrlScheme: hfCallbackScheme,
      );

      final code = Uri.parse(resultUrl).queryParameters['code'];
      if (code == null) {
        return const HfCloneResult.err('Sign-in was cancelled or did not return a code.');
      }

      onStatus?.call('Exchanging code for access token…');
      final token = await _exchangeCodeForToken(code, verifier);
      if (token == null) {
        return const HfCloneResult.err('Failed to exchange authorization code for a token.');
      }

      onStatus?.call('Looking up your Hugging Face username…');
      final username = await _whoami(token);
      if (username == null) {
        return const HfCloneResult.err('Failed to read account info from Hugging Face.');
      }

      onStatus?.call('Cloning the Stable Audio 3 Space into your account…');
      final targetRepo = '$username/$hfClonedSpaceName';
      final duplicateOk = await _duplicateSpace(token, targetRepo);
      if (!duplicateOk) {
        // Might already exist from a previous connect — that's fine, keep going.
        onStatus?.call('Space may already exist — checking status…');
      }

      onStatus?.call('Waiting for your Space to build and start…\n(first time only — usually a few minutes)');
      final running = await _waitUntilRunning(token, targetRepo, onStatus: onStatus);
      if (!running) {
        return HfCloneResult.err(
          'Space was cloned to $targetRepo but did not finish starting. '
          'Open https://huggingface.co/spaces/$targetRepo to check the build logs, '
          'then try again.',
        );
      }

      final spaceUrl = _spaceSubdomainUrl(username, hfClonedSpaceName);
      return HfCloneResult.ok(spaceUrl: spaceUrl, username: username);
    } catch (e) {
      return HfCloneResult.err('Error connecting to Hugging Face: $e');
    }
  }

  // ── PKCE helpers ────────────────────────────────────────────────────────
  static String _randomVerifier() {
    final r = Random.secure();
    final bytes = List<int>.generate(64, (_) => r.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static String _codeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  // ── Token exchange ──────────────────────────────────────────────────────
  static Future<String?> _exchangeCodeForToken(String code, String verifier) async {
    final resp = await http.post(
      Uri.https('huggingface.co', '/oauth/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'client_id': hfOAuthClientId,
        'code': code,
        'redirect_uri': hfRedirectUri,
        'code_verifier': verifier,
      },
    );
    if (resp.statusCode != 200) return null;
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return json['access_token'] as String?;
  }

  // ── Whoami ──────────────────────────────────────────────────────────────
  static Future<String?> _whoami(String token) async {
    final resp = await http.get(
      Uri.https('huggingface.co', '/api/whoami-v2'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (resp.statusCode != 200) return null;
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return json['name'] as String?;
  }

  // ── Duplicate space ─────────────────────────────────────────────────────
  static Future<bool> _duplicateSpace(String token, String targetRepo) async {
    final resp = await http.post(
      Uri.https('huggingface.co', '/api/spaces/$hfSourceSpace/duplicate'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'repository': targetRepo,
        'private': true,
      }),
    );
    // 200/201 = created, 409/400-ish "already exists" is also acceptable.
    return resp.statusCode == 200 || resp.statusCode == 201;
  }

  // ── Poll runtime status ─────────────────────────────────────────────────
  static Future<bool> _waitUntilRunning(
    String token,
    String targetRepo, {
    void Function(String)? onStatus,
    int maxAttempts = 90, // ~7.5 min at 5s intervals
  }) async {
    for (var i = 0; i < maxAttempts; i++) {
      await Future.delayed(const Duration(seconds: 5));
      try {
        final resp = await http.get(
          Uri.https('huggingface.co', '/api/spaces/$targetRepo/runtime'),
          headers: {'Authorization': 'Bearer $token'},
        );
        if (resp.statusCode == 200) {
          final json = jsonDecode(resp.body) as Map<String, dynamic>;
          final stage = json['stage'] as String?;
          if (stage == 'RUNNING') return true;
          if (stage == 'RUNTIME_ERROR' || stage == 'BUILD_ERROR') return false;
          onStatus?.call('Building your Space… ($stage)');
        }
      } catch (_) {
        // keep polling
      }
    }
    return false;
  }

  static String _spaceSubdomainUrl(String username, String spaceName) {
    String slugify(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]'), '-')
        .replaceAll(RegExp(r'-+'), '-');
    return 'https://${slugify(username)}-${slugify(spaceName)}.hf.space';
  }
}
