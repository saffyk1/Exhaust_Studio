# Exhaust Studio

A motorcycle exhaust audio enhancer for Android. Point it at a ride video,
run it through a broadcast-style mastering chain (HPF/LPF, dual-band EQ,
compressor, limiter, volume), and optionally regenerate the exhaust note
entirely using an AI audio model (Stable Audio 3), tuned with custom LoRAs
trained on real Harley Davidson and Royal Enfield Super Meteor exhaust
recordings.

Everything in the base "Enhance" pipeline runs **fully on-device** via
FFmpeg — no account, no internet connection, no server required. The
optional "AI Regenerate" mode needs a (free) Hugging Face account, covered
below.

## What's in this repo

- `exhaust_studio/` — the Flutter/Android app.
- `artifacts/` — a web-based UI mockup/reference (not the shipped app).
- `lib/`, `scripts/` — supporting API client / build scaffolding for a
  planned backend service; not required to run the app itself.

## Features

**Local enhance (always available, offline):**
- High-pass / low-pass filtering to strip wind buffet, chassis rumble, tyre
  hiss, and valve tick.
- Two parametric EQ bands (mid-bass body, engine bark/firing snap) plus
  fixed reference bands for tuning by ear.
- Broadcast-density compressor and a true-peak limiter.
- Built-in presets, plus save/load your own.

**AI Regenerate (optional, needs a Hugging Face account):**
- Runs your enhanced audio through a Stable Audio 3 ComfyUI pipeline to
  regenerate the exhaust note from a text prompt + your own audio as a
  conditioning reference (denoise-controlled, so you dial in how much of
  the AI's take vs. the original comes through).
- Three bundled LoRAs (Harley Davidson, Super Meteor, Super Meteor 2) you
  can mix in at adjustable strength.
- Full control over prompt, negative prompt, CFG scale, steps, and seed.

## How the AI Regenerate mode works

You don't need your own GPU, ComfyUI install, or server. Tap **Connect
Hugging Face Account** inside the AI Regenerate panel and the app will:

1. Open Hugging Face's sign-in page in your browser (OAuth — the app never
   sees or stores your password).
2. **Clone our Stable Audio 3 Space into your own Hugging Face account**
   (`your-username/exhaust-studio-audio`, private by default). This is a
   direct copy of the exact Space this app was built and tested against.
3. Wait for your copy to build and start — this is a Docker build that
   pulls in ComfyUI and the model weights, so **the first run typically
   takes a few minutes**. Every run after that is fast, since the Space
   stays built.
4. Save the resulting Space URL on your device so future generations go
   straight to your own Space, on your own free Hugging Face compute quota
   — not shared with other users of this app.

You can also skip the automated flow and paste in the URL of any
Stable-Audio-3-compatible ComfyUI Space you already run yourself.

### About Space sleep / restarts

Hugging Face Spaces on the free CPU tier can go idle and need a moment to
spin back up if you haven't used the app in a while (typically after a few
days of inactivity). If a generation fails or times out after a period of
not using the app:

1. Open `https://huggingface.co/spaces/<your-username>/exhaust-studio-audio`
   in a browser.
2. If it shows "Sleeping" or a restart prompt, click to wake it up (or it
   will auto-wake on the next visit/request — just give it a minute).
3. Try the generation again from the app.

This is a property of free Hugging Face Space hosting, not a bug in the
app — your own private clone stays yours regardless of how long it's been
idle, it just needs to "wake up" again.

## One-time developer setup (only needed if you fork/build this yourself)

The auto-clone flow needs a Hugging Face OAuth application registered
once, by the app's developer — **end users never do this step**, they only
sign in with their own existing HF account.

1. Go to https://huggingface.co/settings/applications/new while logged in
   as the account that owns the source Space (`saifvj/stable-audio-api`).
2. Set:
   - **Redirect URI:** `exhauststudio://callback`
   - **Scopes:** `read-repos`, `write-repos`
3. Copy the generated **Client ID**.
4. Paste it into `exhaust_studio/lib/hf_auth_service.dart`, replacing
   `REPLACE_WITH_YOUR_HF_OAUTH_CLIENT_ID`.
5. Rebuild the app.

If you fork this project to host your own source Space instead of
`saifvj/stable-audio-api`, update `hfSourceSpace` in the same file.

## Building the app

Requires the Flutter SDK (see `exhaust_studio/pubspec.yaml` for the SDK
constraint).

```
cd exhaust_studio
flutter pub get
flutter build apk --release
```

The signed release APK is produced at
`exhaust_studio/build/app/outputs/flutter-apk/app-release.apk`.

### Installing the APK

This is an unsigned/self-built APK, not distributed through the Play
Store, so Android will show an "install blocked" warning the first time.
On the device: when prompted, tap **Settings** → allow installs from the
app you used to open the APK (e.g. Files, Chrome), then retry the install.
This is standard for any APK installed outside the Play Store and does not
require enabling Developer Options.

## Tech stack

- Flutter / Dart
- FFmpeg (`ffmpeg_kit_flutter_new`) for local audio DSP
- Stable Audio 3 running in ComfyUI, hosted on Hugging Face Spaces
- Hugging Face OAuth (PKCE) for account sign-in and Space auto-cloning

## License

Apache 2.0 — see `LICENSE`.
