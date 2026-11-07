# Anti-Strobo V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Faire réellement disparaître la lumière stroboscopique, même quand elle est allumée la moitié du temps : détection à deux niveaux, exposition réglée sur les images sans lumière, cadence de prise de vue adaptative, vidéo 30 i/s reconstituée sans trous visibles (interpolation), débruitage.

**Architecture:** Les décisions restent des types purs testés dans `StrobeCore` (détection, rythme du strobe, choix de cadence, plan des créneaux). Le pipeline `VideoCleaner` exécute le plan avec VideoToolbox (`VTFrameRateConversion`, `VTTemporalNoiseFilter`, disponibles sur macOS 26 donc testables avec `swift test`). L'app ne fait que changer de cadence et remesurer.

**Tech Stack:** Swift 6.4, Swift Testing, AVFoundation, VideoToolbox (`VTFrameProcessor`), XcodeGen, Xcode 27.2.

**Spec:** `docs/superpowers/specs/2026-11-06-anti-stroboscope-design.md` (§10 = V2, binding; §1–9 still apply).

## Global Constraints

- Une image « avec lumière » est mauvaise, une image « sans lumière » est bonne, quelle que soit leur proportion (1 sur 120 jusqu'à plus de la moitié).
- Une période « avec lumière » plus longue que 0,3 s = changement d'éclairage (gardée), pas un strobe.
- Sortie nettoyée : 30 i/s, durée = original ±1/30 s, audio recopié tel quel, synchro ±1 image ; aucune image « avec lumière » gardée quand une bonne image existe autour ; l'original n'est jamais modifié.
- Trou ≤ 0,35 s entre deux bonnes images → images recréées par interpolation ; sinon (ou interpolation non prise en charge) → comportement V1 (répéter ≤ 0,2 s puis image la moins brûlée).
- Cadences de prise de vue autorisées : 120, 60, 30 i/s ; jamais sous 60 sans strobe détecté ; une cadence plus basse seulement si chaque moment sans lumière contient au moins 4 images à cette cadence.
- iOS 26 minimum ; textes en français, tutoiement, sans jargon photo ; commentaires en français.
- Pas d'envoi TestFlight dans ce plan.

## Review Focus

1. **Strobe court et rare (concert classique, 1 image sur 12 à 120 i/s)** : doit toujours être détecté comme en V1 → test `rareShortFlashesStillDetected` (Task 1).
2. **Lumière allumée 50 % du temps à 5 Hz (l'essai sur iPhone)** : tout le niveau haut part, la sortie ne contient que des images sans lumière et pas de gel → tests Task 1 et Task 4 (`halfDutyStrobeRemovedAndSmooth`).
3. **Scène sans strobe avec mouvement de luminosité lent (fondu de projecteur)** : rien n'est retiré → test `slowFadeIsNotLight` (Task 1).
4. **Interpolation non disponible / trou trop long** : retour V1 sans plantage → tests Task 3 et Task 4.
5. **Changement de cadence pendant la mesure** : la mesure reprend proprement, jamais de changement pendant l'enregistrement → Task 5 (relecture du code + vérification sur iPhone).

---

### Task 1: Détection à deux niveaux de lumière + rythme du strobe

**Files:**
- Modify: `Packages/StrobeCore/Sources/StrobeCore/FlashDetector.swift`
- Create: `Packages/StrobeCore/Sources/StrobeCore/StrobeRhythm.swift`
- Test: `Packages/StrobeCore/Tests/StrobeCoreTests/FlashDetectorTests.swift`, `StrobeRhythmTests.swift`

**Interfaces:**
- Keeps: `FrameVerdict`, `FlashDetectorConfig`, `OnlineFlashDetector.classify(_:at:)`, `.reset()`, `OfflineFlashDetector.classify(_:times:config:)` (same signatures — callers unchanged).
- `FlashDetectorConfig` gains `public var levelRatio = 1.6` (rapport minimal entre les moyennes des deux groupes, en luma), `public var absoluteMargin` stays, `maxFlashRunSeconds` default becomes **0.3**, `baselineWindowSeconds` stays 0.5; the old `relativeJump` is replaced by `levelRatio` (keep the property name `relativeJump` if renaming would churn tests — implementer's choice, document it).
- Produces: `public struct StrobeRhythm: Sendable, Equatable { public var hasStrobe: Bool; public var shortestDarkGap: Double /* s, 20e centile des durées des moments sans lumière */; public var lightFraction: Double }` and `public enum StrobeRhythmEstimator { public static func estimate(times: [Double], verdicts: [FrameVerdict]) -> StrobeRhythm }`.

Rule (both variants): in the window, sort the mean lumas; split them into two groups at the cut that maximises the between-group separation (Otsu on luma); the split is "two levels" if `mean(high) ≥ mean(low) × levelRatio + absoluteMargin` AND both groups are non-empty; frames of the high group are `.flash`. Saturation rule from V1 kept (a frame with `saturatedFraction > saturatedFractionMax` while the low group is not saturated is `.flash`). Runs of `.flash` longer than `maxFlashRunSeconds` are reclassified `.good` offline / reset the window online. Online: the window holds all recent frames (not only good ones) so a 50 % light is seen as two levels.

- [ ] **Step 1: Write the failing tests** (120 fps timestamps):
  - `halfDutyLampIsLight`: 5 Hz square wave, 12 frames at 0.15 then 12 at 0.03, 3 s → offline: exactly the 0.15 frames are `.flash`; online: same after the first 0.5 s.
  - `rareShortFlashesStillDetected`: base 0.25, one frame in 12 at 0.95 → those frames `.flash` (offline and online after 0.5 s).
  - `slowFadeIsNotLight`: luma ramps 0.1 → 0.5 linearly over 3 s → no `.flash`.
  - `sustainedStepIsNotLight`: 0.3 for 1 s then 0.7 for 2 s → no `.flash` after `maxFlashRunSeconds` (0.3 s) past the step, offline none at all.
  - `steadySceneHasNoFlash`, `localBrightSpotNotFlash`, `permanentlySaturatedSceneIsNotFlash`: V1 tests kept and green.
  - `StrobeRhythmTests`: 5 Hz 50 % → `hasStrobe`, `shortestDarkGap ≈ 0.1 ± 0.01`, `lightFraction ≈ 0.5 ± 0.05`; no flash → `hasStrobe == false`, `shortestDarkGap == .infinity`; 1 flash in 12 at 120 fps → `shortestDarkGap ≈ 0.0917 ± 0.01`.
- [ ] **Step 2:** `swift test --filter "FlashDetectorTests|StrobeRhythmTests"` → FAIL.
- [ ] **Step 3:** Implement. Update any V1 test whose expectation changes only because of the documented new rule (say which in the report).
- [ ] **Step 4:** Full `swift test` → PASS (ExposureMeter, FrameSelector, VideoCleaner suites must stay green or be updated with justification).
- [ ] **Step 5:** Commit `feat(core): two-level light detection and strobe rhythm`.

### Task 2: Choix de cadence adaptatif

**Files:**
- Create: `Packages/StrobeCore/Sources/StrobeCore/CadencePlanner.swift`
- Modify: `Packages/StrobeCore/Sources/StrobeCore/ExposureMeter.swift` (expose the rhythm observed during measurement)
- Test: `CadencePlannerTests.swift`, `ExposureMeterTests.swift`

**Interfaces:**
- Consumes: `StrobeRhythm`, `MeasurementState`, `MeasurementFailure`.
- Produces:
  - `ExposureMeter` gains `public var rhythm: StrobeRhythm` (computed from the frames it saw: times + online verdicts) and `public var reachedMaximum: Bool` (target at max product and last median below `targetLuma − tolerance`).
  - `public enum CadencePlanner { public static func nextCadence(current: Double, available: [Double], reachedMaximum: Bool, rhythm: StrobeRhythm, minimumFramesPerDarkGap: Int = 4, minimumWithoutStrobe: Double = 60) -> Double? }` — returns a lower cadence to switch to, or nil to stay. Rule: only if `reachedMaximum`; candidates below `current` in `available`, highest first; a candidate `c` is allowed if (`rhythm.hasStrobe` and `rhythm.shortestDarkGap × c ≥ minimumFramesPerDarkGap`) or (`!rhythm.hasStrobe` and `c ≥ minimumWithoutStrobe`); return the lowest allowed candidate (most light).

- [ ] **Step 1: Failing tests**: dark + 5 Hz 50 % (gap 0.1 s) at 120 → 60 (0.1×30 = 3 < 4 forbids 30); dark + no strobe at 120 → 60; dark + no strobe at 60 → nil; bright (`reachedMaximum` false) → nil; dark + slow strobe gap 0.2 s at 120 → 30; dark + very fast strobe gap 0.03 s → nil; `available` without 60 → skip to allowed ones only. ExposureMeter: rhythm of a simulated 50 % strobe ≈ gap 0.1 s; `reachedMaximum` true in the existing `tooDark`/dim-at-maximum scenarios, false when converged.
- [ ] **Step 2:** RED. **Step 3:** implement. **Step 4:** full `swift test` GREEN. **Step 5:** commit `feat(core): adaptive capture cadence`.

### Task 3: Plan des créneaux avec interpolation

**Files:**
- Modify: `Packages/StrobeCore/Sources/StrobeCore/FrameSelector.swift`
- Test: `FrameSelectorTests.swift`

**Interfaces:**
- Produces: `public enum SlotPlan: Sendable, Equatable { case source(Int); case interpolate(from: Int, to: Int, phase: Double); case hold(Int); case fallback(Int) }` and `public static func plan(times: [Double], verdicts: [FrameVerdict], stats: [FrameStats], duration: Double, outputFPS: Double = 30, maxHoldSeconds: Double = 0.2, maxInterpolationGap: Double = 0.35, interpolationAvailable: Bool) -> (slots: [SlotPlan], report: SelectionReport)`. `SelectionReport` gains `public var interpolatedSlots: Int` (default 0 in init for source compatibility). The existing `select(...)` stays and returns the V1 behaviour (it may be implemented as `plan(... interpolationAvailable: false)` mapped to indices).
- Rule: slot k at t = k/fps: a good frame in the slot → `.source(first good)`; else, if `interpolationAvailable`, let A = last good frame with time < t, B = first good frame with time ≥ t; if both exist and `time(B) − time(A) ≤ maxInterpolationGap` → `.interpolate(from: A, to: B, phase: (t − time(A)) / (time(B) − time(A)))` clamped to (0,1); otherwise V1 rules (`.hold` ≤ 0.2 s, then `.fallback` least burnt). Source indices referenced by successive slots never go backwards (B of one slot ≤ source of the next).

- [ ] **Step 1: Failing tests**: 50 % 5 Hz at 120 fps, 3 s → no slot references a flash frame; gap slots are `.interpolate` with phases strictly in (0,1) and increasing within a gap; `interpolationAvailable: false` → exactly V1 `select` output; gap 0.5 s → V1 behaviour for that gap; report counts consistent (`slots == source + interpolated + held + fallback`); all V1 FrameSelector tests still green via `select`.
- [ ] **Step 2–5:** RED, implement, full GREEN, commit `feat(core): slot plan with interpolation`.

### Task 4: Reconstitution et débruitage dans VideoCleaner

**Files:**
- Modify: `Packages/StrobeCore/Sources/StrobeCore/VideoCleaner.swift`, `VideoCleaner+Writing.swift`
- Create: `Packages/StrobeCore/Sources/StrobeCore/FrameSynthesizer.swift` (wraps `VTFrameProcessor` with `VTFrameRateConversionConfiguration`; pixel-format conversion with `VTPixelTransferSession` if the processor's supported formats exclude 8-bit 420), `Packages/StrobeCore/Sources/StrobeCore/NoiseReducer.swift` (wraps `VTTemporalNoiseFilterConfiguration`)
- Modify: `Sources/strobe-tune/*` (report interpolated count; `--no-interp` flag to force V1)
- Test: `VideoCleanerTests.swift`, `Support/SyntheticVideo.swift` (square-wave light option)

**Interfaces:**
- `CleanerConfig` gains `public var interpolate = true`, `public var maxInterpolationGap = 0.35`, `public var denoise = true`.
- `FrameSynthesizer`: `init?(width: Int, height: Int)` (nil when `VTFrameRateConversionConfiguration.isSupported` is false or init fails); `func frames(between a: CVPixelBuffer, and b: CVPixelBuffer, phases: [Float]) async throws -> [CVPixelBuffer]`.
- `NoiseReducer`: `init?(width:height:)`; applied to every written frame (source and interpolated) when `denoise` and the processor is supported; failure of a frame → write the frame unfiltered (never fail the clean because of denoising).
- Pass 2 executes the `SlotPlan`: it must keep the decoded frame A and decode ahead to B for `.interpolate` slots (group consecutive interpolate slots sharing (A,B) into one processor call). PTS check of V1 still applies to every source frame used (A, B, source, hold, fallback).

- [ ] **Step 1: Failing tests**: `halfDutyStrobeRemovedAndSmooth`: synthetic 120 fps, 3 s, light square wave 5 Hz 50 % (scene luma 0.1 vs 0.6) → output 90 frames; no output frame's decoded index band or luma matches a lit frame (mean luma of every output frame < 0.3); `interpolatedSlots > 0`; durations ±1/30 s; audio identical. `interpolationFallbackWhenDisabled`: `interpolate = false` → V1 output. `denoiseNeverFails`: denoise on/off produce same frame count and durations. All V1 VideoCleaner tests still green. Note: interpolated frames won't carry a decodable index band — adapt the index-reading assertions to skip interpolated slots (use the plan) and assert luma instead.
- [ ] **Step 2–4:** RED, implement, full `swift test` GREEN (several runs of VideoCleanerTests), plus `swift run strobe-tune` on `build/samples/strobe-sample.mov` and on a new 50 %-duty sample.
- [ ] **Step 5:** commit `feat(core): smooth reconstruction and denoise`.

### Task 5: Cadence adaptative dans l'app

**Files:**
- Modify: `App/Camera/SessionConfigurator.swift`, `App/Camera/CaptureDeviceControl.swift`, `App/Camera/FrameProcessor.swift`, `App/Camera/CameraController.swift`
- Modify (if needed): `Packages/StrobeCore/Sources/StrobeCore/FormatChooser.swift` (+ tests) to list cadences available for the chosen resolution.

**Interfaces:**
- Consumes: `CadencePlanner.nextCadence`, `ExposureMeter.rhythm`, `.reachedMaximum`, `StorageEstimator.nominalBytesPerSecond(width:height:fps:)`.
- `CaptureConfiguration` gains the list of cadences available for the active resolution (120/60/30 among `videoSupportedFrameRateRanges`, rounded).
- Behaviour: when the meter reaches a final state with `reachedMaximum`, before locking, ask `CadencePlanner`; if it returns a lower cadence, on the session queue set `activeVideoMin/MaxFrameDuration` to 1/c (same format if it supports it; else re-choose the format at that cadence with `FormatChooser` rules), update `ExposureLimits.maxDuration = min(format max, 1/c)`, `nominalBytesPerSecond`, and restart a fresh `ExposureMeter` (the badge keeps « Mesure de la lumière… »). At most one switch per cadence (no loops). Never while recording (existing gate). The recorder uses the active cadence for `AVVideoExpectedSourceFrameRateKey` and bitrate. Debug log: chosen cadence and rhythm.

- [ ] **Step 1:** implement; **Step 2:** `xcodegen generate`, simulator + generic iOS Debug/Release builds (CODE_SIGNING_ALLOWED=NO), zero warnings from our target; full `swift test`; **Step 3:** commit `feat(app): adaptive capture cadence`.

### Task 6: Vérification sur la vidéo d'essai et build iPhone

- [ ] `swift run -c release strobe-tune` on `19D25B75-568C-4789-9017-BC623544C329-clean.MOV` (30 fps lamp video): analysis report shows the lit frames classified as light (≈ half); write the cleaned output to the scratchpad and extract a contact sheet of 12 consecutive output frames to check no lit frame remains.
- [ ] Device Debug build signed (`-allowProvisioningUpdates`), install on the test iPhone, launch with log capture.
