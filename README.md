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

**Local enhance (always available, offline, no account needed):**
- High-pass / low-pass filtering to strip wind buffet, chassis rumble, tyre
  hiss, and valve tick.
- Two adjustable parametric EQ bands (mid-bass body, engine bark/firing
  snap) plus fixed reference bands for tuning by ear.
- Broadcast-density compressor and a true-peak limiter.
- Built-in presets (Default, Track Day, Deep Rumble, Street Cruise, Wet
  Road, Race Mode), plus save/load your own custom presets.
- Trim your source clip before processing.

**AI Regenerate (optional, needs a free Hugging Face account):**
- Runs your enhanced audio through a Stable Audio 3 ComfyUI pipeline to
  regenerate the exhaust note from a text prompt + your own audio as a
  conditioning reference (denoise-controlled, so you dial in how much of
  the AI's take vs. the original comes through).
- Three bundled LoRAs (Harley Davidson, Super Meteor, Super Meteor 2) you
  can mix in at adjustable strength.
- Full control over prompt, negative prompt, CFG scale, steps, and seed.

## How the app works, step by step

1. **Upload a ride video.** Tap the empty video area to pick a clip from
   your gallery.
2. **Trim (optional).** As soon as a video loads, a TRIM range slider
   appears below it — drag the in/out handles to select just the section
   you want, then tap **LOCK TRIM** to commit (or leave it untrimmed to
   use the whole clip).
3. **Choose a tuning profile.** Switch between:
   - **Presets** — pick one of the six built-in profiles above, or one you
     saved yourself.
   - **Manual** — dial in every parametric EQ band, the compressor, and
     limiter yourself.
   The **Pipeline** readout below always shows exactly what each stage
   (HPF → LPF → EQ → EQ → Compressor → Volume → Limiter) is currently set
   to do, in order.
4. **Tap Enhance & Save to Gallery.** This runs the whole chain locally
   through FFmpeg — no upload, no account, no internet needed for this
   step. Once done, an ORIGINAL / ENHANCED toggle appears so you can A/B
   the result, with a scrubbable preview.
5. **(Optional) AI Regenerate.** Open the "AI Regenerate · SA3" panel
   below the Enhance button — see the next section for how this works and
   what it needs.
6. **Save or discard.** Save the final video to your gallery, or discard
   and start over.

## How the AI Regenerate mode works

You don't need your own GPU, ComfyUI install, or server. Tap **Connect
Hugging Face Account** inside the AI Regenerate panel and the app will:

1. Open Hugging Face's sign-in page in your browser (OAuth — the app never
   sees or stores your password).
2. **Clone our Stable Audio 3 Space into your own Hugging Face account**
   (`your-username/exhaust-studio-audio`, private by default). This is a
   direct copy of the exact Space this app was built and tested against —
   it never touches or reuses our account or compute after this one-time
   copy step.
3. Wait for your copy to build and start — this is a Docker build that
   pulls in ComfyUI and the model weights, so **the first run typically
   takes a few minutes**. Every run after that is fast, since the Space
   stays built.
4. The app automatically saves the resulting Space URL on your device —
   there's nothing to copy or paste yourself. Every generation after that
   goes straight to your own Space, on your own free Hugging Face compute
   quota, not shared with other users of this app.

Once connected, set your prompt, negative prompt, CFG scale, steps, and
optionally enable any of the three LoRAs at your preferred strength, then
generate.

### Getting good results

AI Regenerate exists to make an exhaust recording sound noticeably cleaner
and clearer than the local enhance pipeline alone can achieve — it's
rebuilding the tone, not just filtering it.

- **Start with the default values** (prompt, CFG, steps, denoise) — they're
  tuned to give a solid result out of the box. Treat everything below as
  optional tweaking once you've heard the default output.
- **LoRAs:** three are bundled — Harley Davidson, Super Meteor, and Super
  Meteor 2. Turn on whichever one (or two, mixed together) matches the
  exhaust character you're after; leave the rest off. They can be blended
  at different strengths, so it's worth experimenting with one active at a
  time first to hear what each one does on its own.
- **Denoise is the main thing to watch.** It controls how much of the
  output is your original audio vs. a fresh AI take:
  - Around the default (~0.4) and up to roughly **0.5–0.6**, you'll get a
    cleaner/clearer version of your own recording with the timing (revs,
    gear changes, etc.) staying close to the original.
  - Push it higher and the output starts to drift from your original
    timing — the AI takes more creative liberty with when things happen.
  - At **denoise = 1.0**, it's generating essentially from scratch —
    expect a completely different audio take, not a cleaned-up version of
    your recording.
- CFG scale and steps are fine left at their defaults; adjusting them
  mostly changes how strictly the output follows the prompt vs. how varied
  it sounds — worth playing with once you're comfortable with denoise.

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

## One-time developer setup (only needed if you fork this yourself)

Already done for this repo — the HF OAuth Client ID is already wired into
`exhaust_studio/lib/hf_auth_service.dart`, so end users can just tap
Connect and go. This section is only relevant if you fork the project and
want to host your own source Space instead of `saifvj/stable-audio-api`.

1. Go to https://huggingface.co/settings/applications/new while logged in
   as the account that owns your source Space (this URL works even though
   it isn't linked from the Settings sidebar).
2. Set:
   - **Redirect URI:** `exhauststudio://callback`
   - **Scopes:** `read-repos`, `write-repos`
   - Token expiration of 8 hours is fine — the app only uses the token
     briefly during the connect flow, then discards it.
3. Copy the generated **Client ID** (this is safe to be public — it's not
   a secret, just an app identifier).
4. Paste it into `hfOAuthClientId` in
   `exhaust_studio/lib/hf_auth_service.dart`, and update `hfSourceSpace` to
   point at your own Space.
5. Rebuild the app.

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
