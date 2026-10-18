# Guida Visiva

An offline mobility aid for people with low vision caused by a restricted visual field (for example retinitis pigmentosa). The phone camera warns about low and lateral obstacles, level changes such as steps and curbs, and light/dark transitions. A local assistant can describe the scene and read signs aloud.

> **Status: research prototype.** Phase 0 (technical feasibility on the device) is complete and its outcome confirmed; the MVP is next.
> The app is meant to **complement the white cane, never to replace it**. It has not been validated and must not be distributed.

## Principles

- **Fully offline**: every model runs on the phone. No images leave the device.
- **No LiDAR required**: it must work on ordinary phones. LiDAR will be an optional extra.
- **Accessible first**: few large controls, high contrast, VoiceOver/TalkBack support. The user interface and the voice are in Italian.
- **No added light**: the app never turns on the torch or any other light.

## Planned features (MVP)

| Feature | Technology (iOS) |
|---|---|
| Obstacles ahead and to the sides, low obstacles | ARKit (planes and tracking) + Depth Anything V2 Small on Core ML (Neural Engine) |
| Level changes: step up/down (experimental) | ARKit floor plane + depth discontinuities |
| Feedback: vibration per zone, directional audio, short voice messages | Core Haptics, AVAudioEngine, speech |
| Light/dark transition warning and reliability indicator | ARKit light estimation and tracking state |
| "What is in front of me?" on request (indicative description) | QVAC: VisionPsy Nano 460M Flash (English) + Bergamot EN→IT translation + Supertonic 3 Italian voice |
| Reading signs | Apple Vision text recognition |

Scene descriptions are never used for safety alerts: in testing the vision-language models got the direction of stairs wrong.

Android (ARCore) will follow, with the same event interface for the perception module.

## Phase 0 results

Measured on an iPhone 13 (no LiDAR, 4 GB RAM), the reference test device:

- **Depth**: 15–19 fps live on the Neural Engine, stable for 5 minutes; the phone only reaches the "fair" thermal state.
- **Signs**: Apple Vision reads them in 0.1–0.5 s. QVAC OCR was rejected: it is slow, and at default settings iOS kills the app for exceeding its memory limit.
- **Voice**: Supertonic 3 approved by the user.
- **"What is in front of me?"**: 9.3–13.5 s today; the target is ≤ 7 s without losing accuracy.
- **Darkness**: in near darkness (4–10 lux) ARKit tracking fails and camera frames are too dark to describe.

Details: [Phase 0A summary (Mac)](scripts/phase0/results/phase0a-summary.md) · [Phase 0B summary (iPhone)](scripts/phase0/results/phase0b-summary.md).

## Tech stack

- [Expo](https://expo.dev) SDK 58 / React Native 0.88, TypeScript
- Local Expo module [`modules/perception`](modules/perception) (Swift): ARKit, Core ML, Vision, AVFoundation
- [QVAC SDK](https://qvac.tether.io) for on-device AI (worker bundle generated at prebuild from [`qvac.config.json`](qvac.config.json))

## Repository layout

```
App.tsx                    Phase 0B test screen (Italian UI)
src/phase0/                Test runners: depth (Core ML) and QVAC (description, OCR, voice, classification)
modules/perception/        Native module: depth benchmark, live ARKit depth, memory/thermal probes, OCR, WAV
scripts/phase0/            Phase 0 tooling: Mac benchmarks (*.mjs, depth-bench) and iPhone helper scripts
scripts/phase0/results/    Phase 0 reports and summaries
qvac.config.json           QVAC plugins included in the mobile worker bundle
```

## Building for iOS

Requirements: macOS with Xcode 27, Node.js ≥ 22.17, a **physical iPhone** with iOS 17 or later (QVAC does not run on the simulator) and an Apple ID for signing.

```bash
npm install
npx expo prebuild --platform ios
```

Known pitfalls:

- iOS 27 requires the UIScene life cycle, which is why the project uses Expo SDK 58.
- The QVAC Expo plugin needs `bare-link` **v3** installed as a dev dependency (v4 has a different API).
- CocoaPods fails on paths with spaces unless `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` is set.

Then build, install and launch on the connected iPhone:

```bash
scripts/phase0/build-and-run.sh
```

## Phase 0 test workflow

The depth model, the test photos and the classifier weights are not bundled with the app. They are copied into the app's Documents folder on the device:

```bash
scripts/phase0/copy-to-iphone.sh
```

Tests that do not need the camera can run unattended from the Mac (`PHASE0_AUTO`):

```bash
scripts/phase0/build-and-run.sh depth-photos,descriptions,ocr
```

Available tests: `depth-photos`, `depth-live`, `depth-long`, `what-is-ahead`, `descriptions`, `ocr`, `voice`, `classification`. Set `CONSOLE=1` to stream the app output, including a memory trace.

Fetch the reports, depth maps, audio and camera shots:

```bash
scripts/phase0/fetch-from-iphone.sh
```

## Privacy

Test photos, camera shots and everything derived from them stay on the developer's machine. They are excluded by `.gitignore` and never committed.

## Licence

No licence has been chosen yet. The models used have their own licences, which must be checked before any distribution: some datasets used to train the vision-language model carry non-commercial terms.
