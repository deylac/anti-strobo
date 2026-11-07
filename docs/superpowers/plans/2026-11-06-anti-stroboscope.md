# Anti-Strobo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Une app iPhone qui mesure une exposition de référence sans tenir compte des flashs de stroboscope, filme à 120 i/s avec cette exposition verrouillée, puis produit une version 30 i/s sans les images brûlées, en gardant l'original.

**Architecture:** Toute la logique testable (mesure de luminance, détection de flash, mesure d'exposition, choix des images, nettoyage vidéo AVFoundation, estimation de stockage, textes d'état) vit dans un package Swift `StrobeCore` qui compile pour iOS et macOS et se teste avec `swift test` sur le Mac. L'app iOS (projet XcodeGen) n'est qu'une couche fine : capture caméra, enregistrement, tâche de fond, sauvegarde Photos, SwiftUI. Un outil en ligne de commande `strobe-tune` rejoue le nettoyage sur Mac pour régler les seuils à partir de vraies vidéos.

**Tech Stack:** Swift 6.4, SwiftUI, AVFoundation, BackgroundTasks (`BGContinuedProcessingTask`, iOS 26), Photos, XcodeGen, Swift Testing, Xcode 27.2.

**Spec:** `docs/superpowers/specs/2026-11-06-anti-stroboscope-design.md`

## Global Constraints

- iPhone uniquement, déploiement minimum **iOS 26.0** (requis par `BGContinuedProcessingTask`) ; `StrobeCore` cible `.iOS(.v26)` et `.macOS(.v26)`.
- Pas d'API privée ; Info.plist déclare `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSPhotoLibraryAddUsageDescription`.
- Équipe `P55APCSVXL`, bundle id `app.camantistrobo.ios` (choix de Claude), nom affiché « Anti-Strobo » (choix de Claude).
- Capture à **120 i/s** quand l'appareil le permet ; sortie nettoyée à **30 i/s**.
- L'exposition de référence est verrouillée pendant tout l'enregistrement : jamais de réajustement, jamais d'auto-exposition native.
- Aucune limite de durée imposée par l'app.
- Invariants : durée nettoyée = durée originale (±1/30 s) ; audio nettoyé = audio original, synchro ±1 image ; aucune image retenue n'est un flash quand une bonne image existe dans le créneau ; l'original n'est jamais modifié.
- Textes d'interface en français, tutoiement, sans jargon photo (pas « ISO », pas « obturation »).
- Envoi TestFlight uniquement avec le go explicite de l'auteur.

## Review Focus

1. **Aucun strobe pendant la mesure ou le tournage** : la mesure doit aboutir vite, et le nettoyage doit garder toutes les images (aucune retirée). → tests dans Task 3 et Task 6.
2. **Changement d'éclairage de scène en plein tournage** (passage à un éclairage plus fort et durable) : ce n'est pas un flash, ça ne doit pas vider la vidéo pendant des secondes. → test `sustainedStepIsNotFlash` dans Task 2.
3. **Strobe très rapide** (une image sur deux brûlée, ou une longue rafale) : pas d'image figée plus de 0,2 s, repli sur l'image la moins brûlée. → tests dans Task 4.
4. **Enregistrement coupé net** (iOS coupe la caméra pour chauffe, appel, app tuée) : l'original déjà filmé reste lisible et passe au nettoyage. → `movieFragmentInterval` dans Task 10 + test `cleansFragmentedPartialFile` dans Task 6.
5. **Pas de piste audio** (micro refusé) **ou cadence irrégulière** (images perdues à la capture) : le nettoyage fonctionne sur les horodatages, pas sur les indices, et n'exige pas d'audio. → tests dans Task 4 et Task 6.

---

## File Structure

```
cam-anti-stroboscope/
  project.yml                         XcodeGen : cible app iOS + dépendance locale StrobeCore
  App/
    AntiStroboApp.swift               point d'entrée, enregistrement de la tâche de fond, reprise
    Camera/CameraController.swift     session AVCapture, format, exposition custom, flux d'images
    Camera/MovieRecorder.swift        AVAssetWriter 120 i/s + audio, fichiers fragmentés
    Processing/CleaningCoordinator.swift  file de travaux, BGContinuedProcessingTask, Photos
    UI/CameraScreen.swift             écran unique : aperçu, badge de mesure, bouton, barre d'état
    UI/PreviewView.swift              AVCaptureVideoPreviewLayer en SwiftUI
    UI/ProcessingBanner.swift         progression et confirmation de fin
  Packages/StrobeCore/
    Package.swift
    Sources/StrobeCore/
      FrameStats.swift                FrameStats + LumaSampler
      FlashDetector.swift             détection en ligne (mesure) et hors ligne (nettoyage)
      ExposureMeter.swift             machine d'état de la mesure de référence
      FrameSelector.swift             choix d'une image source par créneau 30 i/s
      FormatChooser.swift             choix du format caméra
      StorageEstimator.swift          temps d'enregistrement restant
      VideoCleaner.swift              analyse + réécriture AVAssetReader/Writer
      CleaningJobStore.swift          persistance JSON des travaux
      StatusText.swift                textes d'état français (testables)
    Sources/strobe-tune/main.swift    CLI de réglage
    Tests/StrobeCoreTests/
      Support/SyntheticVideo.swift    génère des .mov de test (flashs à des indices connus, audio)
      *Tests.swift                    un fichier de test par source
  Config/ExportOptions-TestFlight-Internal.plist
  scripts/testflight.sh
```

---

### Task 1: Dépôt, package et mesure de luminance

**Files:**
- Create: `.gitignore`, `Packages/StrobeCore/Package.swift`, `Packages/StrobeCore/Sources/StrobeCore/FrameStats.swift`
- Test: `Packages/StrobeCore/Tests/StrobeCoreTests/FrameStatsTests.swift`

**Interfaces:**
- Produces:
  - `public struct FrameStats: Sendable, Equatable, Codable { public var meanLuma: Double; public var saturatedFraction: Double }` (tous deux dans 0…1)
  - `public enum LumaSampler { public static func stats(of buffer: CVPixelBuffer, step: Int = 8) -> FrameStats }`

- [ ] **Step 1:** `git init` à la racine, `.gitignore` (`.build/`, `*.xcodeproj`, `build/`, `DerivedData/`, `.DS_Store`, `*.p8`), commit du spec et de ce plan.
- [ ] **Step 2:** `Package.swift` : outils 6.2, plateformes `.iOS(.v26)`, `.macOS(.v26)` ; produit bibliothèque `StrobeCore`, exécutable `strobe-tune` (dépend de StrobeCore, fichier `main.swift` vide pour l'instant), cible de test `StrobeCoreTests` avec Swift Testing.
- [ ] **Step 3: Write the failing tests** : construire des `CVPixelBuffer` 64×64 en `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` remplis d'une valeur Y constante.
  - `uniformGray` : Y=128 → `meanLuma ≈ 128/255` (±0,005), `saturatedFraction == 0`.
  - `fullyBlown` : Y=255 → `meanLuma ≈ 1`, `saturatedFraction == 1`.
  - `halfBlown` : moitié haute Y=255, moitié basse Y=20 → `saturatedFraction ≈ 0.5` (±0,05).
  - `videoRangeNormalized` : format `…VideoRange`, Y=235 → `meanLuma ≈ 1`, `saturatedFraction == 1` ; Y=16 → `meanLuma ≈ 0`.
- [ ] **Step 4:** `cd Packages/StrobeCore && swift test --filter FrameStatsTests` → FAIL (symboles absents).
- [ ] **Step 5:** Implémenter `LumaSampler.stats` : lit le plan Y avec un pas `step` en x et y ; plein écart → Y/255, plage vidéo → (Y−16)/219 borné à 0…1 ; un pixel est saturé si la luma normalisée ≥ 0,98. Accepte aussi BGRA (luma Rec.709) pour les tests et la CLI.
- [ ] **Step 6:** `swift test --filter FrameStatsTests` → PASS.
- [ ] **Step 7:** Commit `feat(core): luminance sampling`.

### Task 2: Détecteur de flash

**Files:**
- Create: `Sources/StrobeCore/FlashDetector.swift`
- Test: `Tests/StrobeCoreTests/FlashDetectorTests.swift`

**Interfaces:**
- Consumes: `FrameStats`
- Produces:
  - `public enum FrameVerdict: Sendable, Equatable, Codable { case good, flash }`
  - `public struct FlashDetectorConfig: Sendable, Codable, Equatable { public var relativeJump = 1.6; public var absoluteMargin = 0.04; public var saturatedFractionMax = 0.25; public var baselineWindowSeconds = 0.5; public var maxFlashRunSeconds = 0.12 }`
  - `public struct OnlineFlashDetector { public init(config: FlashDetectorConfig = .init()); public mutating func classify(_ s: FrameStats, at time: Double) -> FrameVerdict; public mutating func reset() }`
  - `public enum OfflineFlashDetector { public static func classify(_ stats: [FrameStats], times: [Double], config: FlashDetectorConfig = .init()) -> [FrameVerdict] }`

Règle (les deux variantes) : une image est un flash si `meanLuma > baseline * relativeJump + absoluteMargin` **ou** `saturatedFraction > saturatedFractionMax` alors que la référence locale ne l'est pas. Ligne de base : médiane des `meanLuma` des images jugées bonnes dans les `baselineWindowSeconds` précédentes (en ligne) ou centrées autour de l'image (hors ligne, médiane de toutes les images de la fenêtre). Toute suite contiguë de « flash » plus longue que `maxFlashRunSeconds` est un changement d'éclairage, pas un éclair : hors ligne, elle est reclassée « good » ; en ligne, la ligne de base est réinitialisée sur le nouveau niveau (sinon elle resterait bloquée sur l'ancien). Le réglage fin des seuils se fait plus tard avec `strobe-tune` ; ces valeurs sont des points de départ.

- [ ] **Step 1: Write the failing tests** (horodatages à 1/120 s) :
  - `steadySceneHasNoFlash` : 240 images à luma 0,3 ± bruit 0,01 → aucun `.flash`, en ligne et hors ligne.
  - `periodicStrobeDetected` : base 0,25, une image sur 12 à luma 0,95 et saturation 0,6 → exactement ces indices en `.flash` (hors ligne) ; en ligne, idem après les 60 premières images.
  - `darkSceneSmallFlashDetected` : base 0,05, flashs à 0,30 → détectés (la marge absolue ne masque pas un vrai flash en salle sombre).
  - `sustainedStepIsNotFlash` : 120 images à 0,3 puis 240 à 0,7 → hors ligne, aucune image `.flash` dans la seconde partie après reclassement des suites longues ; en ligne, plus aucun `.flash` au-delà de `maxFlashRunSeconds` après la marche.
  - `localBrightSpotNotFlash` : luma moyenne stable 0,3 mais saturation 0,1 constante (projecteur dans le champ) → aucun flash.
- [ ] **Step 2:** `swift test --filter FlashDetectorTests` → FAIL.
- [ ] **Step 3:** Implémenter `OnlineFlashDetector` et `OfflineFlashDetector` selon la règle ci-dessus.
- [ ] **Step 4:** `swift test --filter FlashDetectorTests` → PASS.
- [ ] **Step 5:** Commit `feat(core): flash detection`.

### Task 3: Mesure de l'exposition de référence

**Files:**
- Create: `Sources/StrobeCore/ExposureMeter.swift`
- Test: `Tests/StrobeCoreTests/ExposureMeterTests.swift`

**Interfaces:**
- Consumes: `FrameStats`, `OnlineFlashDetector`
- Produces:
  - `public struct Exposure: Sendable, Equatable, Codable { public var durationSeconds: Double; public var iso: Double; public var product: Double { durationSeconds * iso } }`
  - `public struct ExposureLimits: Sendable, Equatable { public var minDuration, maxDuration, minISO, maxISO: Double }` (`maxDuration` = durée d'une image, 1/120 s à 120 i/s)
  - `public struct ExposureMeterConfig: Sendable { public var targetLuma = 0.42; public var tolerance = 0.06; public var framesPerStep = 24; public var requiredStableSteps = 2; public var timeoutSeconds = 10.0; public var gamma = 2.2; public var tooDarkLuma = 0.12 }`
  - `public enum MeasurementFailure: Sendable, Equatable { case notEnoughGoodFrames, tooDark }`
  - `public enum MeasurementState: Sendable, Equatable { case measuring(progress: Double, secondsRemaining: Int); case ready(Exposure); case failed(MeasurementFailure, best: Exposure) }`
  - `public struct ExposureMeter { public init(limits: ExposureLimits, initial: Exposure, config: ExposureMeterConfig = .init(), detector: FlashDetectorConfig = .init()); public private(set) var target: Exposure; public private(set) var state: MeasurementState; public mutating func ingest(_ stats: FrameStats, at time: Double, appliedExposure: Exposure) -> MeasurementState }`

Algorithme : `target` est l'exposition que la caméra doit appliquer. Les images dont `appliedExposure != target` sont ignorées (la caméra n'a pas encore appliqué le réglage). Les images jugées flash par le détecteur en ligne sont ignorées. Après `framesPerStep` bonnes images : `m` = médiane de leur luma. Si `|m − targetLuma| ≤ tolerance` → une étape stable de plus ; sinon remise à zéro des étapes stables et nouveau produit = `target.product × (targetLuma / max(m, 0.01))^gamma`, borné aux limites. Répartition : durée d'abord jusqu'à `maxDuration`, le reste en ISO. `ready` après `requiredStableSteps` étapes stables. Compte à rebours : `secondsRemaining = ceil(étapes restantes × framesPerStep / cadence observée des bonnes images)`, borné au temps restant avant `timeoutSeconds` ; `progress = écoulé / (écoulé + restant)`. À l'expiration : moins de `framesPerStep` bonnes images → `failed(.notEnoughGoodFrames)` ; exposition au maximum et `m < tooDarkLuma` → `failed(.tooDark)` ; sinon `ready(target)`. `failed` porte toujours la meilleure exposition atteinte, pour pouvoir filmer quand même.

Les tests utilisent une caméra simulée : `luma = clamp((scène × product)^(1/gamma))` avec une scène constante, plus des flashs à luma 1 tous les N images.

- [ ] **Step 1: Write the failing tests** :
  - `convergesWithoutStrobe` : scène normale, sans flash, exposition initiale 4× trop faible → `ready` en moins de 2 s simulées, luma résultante dans 0,42 ± 0,06.
  - `ignoresFlashesWhenConverging` : même scène avec un flash toutes les 8 images → même `Exposure` finale (±10 % sur le produit) que sans flash.
  - `countdownDecreases` : les `secondsRemaining` successifs ne remontent jamais de plus d'1 s, et l'état `measuring` publie toujours une valeur ≥ 1 avant `ready`.
  - `tooDarkReported` : scène si sombre que la luma reste < 0,12 à `maxDuration × maxISO` → `failed(.tooDark, best:)` avec `best` au maximum.
  - `allFlashesReportsNotEnoughGoodFrames` : uniquement des images saturées pendant 10 s → `failed(.notEnoughGoodFrames, …)`.
  - `staleExposureFramesIgnored` : des images avec `appliedExposure` ancienne ne font pas avancer la mesure.
- [ ] **Step 2:** `swift test --filter ExposureMeterTests` → FAIL.
- [ ] **Step 3:** Implémenter `ExposureMeter`.
- [ ] **Step 4:** `swift test --filter ExposureMeterTests` → PASS.
- [ ] **Step 5:** Commit `feat(core): reference exposure metering`.

### Task 4: Choix des images de sortie

**Files:**
- Create: `Sources/StrobeCore/FrameSelector.swift`
- Test: `Tests/StrobeCoreTests/FrameSelectorTests.swift`

**Interfaces:**
- Consumes: `FrameStats`, `FrameVerdict`
- Produces:
  - `public struct SelectionReport: Sendable, Equatable, Codable { public var slots: Int; public var heldSlots: Int; public var fallbackSlots: Int }`
  - `public enum FrameSelector { public static func select(times: [Double], verdicts: [FrameVerdict], stats: [FrameStats], duration: Double, outputFPS: Double = 30, maxHoldSeconds: Double = 0.2) -> (indices: [Int], report: SelectionReport) }`

Règle : nombre de créneaux = `Int((duration × outputFPS).rounded())`. Créneau k couvre `[k/fps, (k+1)/fps)`. S'il contient une bonne image : la première bonne image du créneau. Sinon, si la dernière bonne image choisie date de moins de `maxHoldSeconds` : on la répète (`heldSlots`). Sinon : l'image du créneau de plus faible `meanLuma` (`fallbackSlots`) ; si le créneau est vide (fin de fichier, images perdues), l'image choisie au créneau précédent. Les indices retournés sont croissants (jamais de retour en arrière).

- [ ] **Step 1: Write the failing tests** :
  - `noFlashKeepsOneFramePerSlot` : 120 i/s, 2 s, tout bon → 60 indices, valeurs `0, 4, 8, …`, `heldSlots == 0`.
  - `flashFramesNeverChosenWhenAlternativeExists` : flash à chaque indice multiple de 4 → aucun indice retourné n'est un flash.
  - `shortGapHoldsLastGood` : 3 créneaux entièrement flashés → ces créneaux répètent la dernière bonne image, `heldSlots == 3`.
  - `longBurstFallsBackToLeastBurnt` : 1 s entièrement flashée avec des lumas variables → après 0,2 s de répétition, chaque créneau prend son image la moins lumineuse ; `fallbackSlots > 0` ; aucune image répétée plus de `0,2 × 30` créneaux d'affilée.
  - `irregularTimestamps` : horodatages avec trous (images perdues) → toujours `slots` indices, monotones.
  - `slotCountMatchesDuration` : durée 10,01 s → 300 créneaux.
- [ ] **Step 2:** `swift test --filter FrameSelectorTests` → FAIL.
- [ ] **Step 3:** Implémenter `FrameSelector.select`.
- [ ] **Step 4:** `swift test --filter FrameSelectorTests` → PASS.
- [ ] **Step 5:** Commit `feat(core): output frame selection`.

### Task 5: Choix du format et estimation de stockage

**Files:**
- Create: `Sources/StrobeCore/FormatChooser.swift`, `Sources/StrobeCore/StorageEstimator.swift`
- Test: `Tests/StrobeCoreTests/FormatChooserTests.swift`, `Tests/StrobeCoreTests/StorageEstimatorTests.swift`

**Interfaces:**
- Produces:
  - `public struct CameraFormatInfo: Sendable, Equatable { public var index: Int; public var width: Int; public var height: Int; public var maxFPS: Double }`
  - `public enum FormatChooser { public static func choose(_ formats: [CameraFormatInfo]) -> (index: Int, fps: Double)? }`
  - `public enum StorageEstimator { public static func nominalBytesPerSecond(width: Int, height: Int, fps: Double) -> Double; public static func remainingRecordingSeconds(freeBytes: Int64, bytesPerSecond: Double, cleanedRatio: Double = 0.3, safetyBytes: Int64 = 500_000_000) -> TimeInterval }`

Règles : `choose` prend la cadence 120 si un format l'offre (V1 n'utilise pas 240, choix de Claude : plus bruité en salle sombre), en préférant la hauteur 1080, sinon la plus grande hauteur ≤ 1080, sinon la plus petite au-dessus ; sans 120, la meilleure cadence ≥ 60 en 1080 ; sinon 30. `nominalBytesPerSecond = width × height × fps × 0.09 / 8` (≈ 2,8 Mo/s en 1080p120, soit ≈ 10 Go/h). `remainingRecordingSeconds = max(0, (freeBytes − safetyBytes) / (bytesPerSecond × (1 + cleanedRatio)))`.

- [ ] **Step 1: Write the failing tests** :
  - `prefers1080at120` : formats 4K/120, 1080/120, 720/240 → 1080/120.
  - `fallsBackTo60` : seulement 1080/60 et 4K/30 → 1080/60.
  - `emptyReturnsNil`.
  - `tenGigsPerHourAt1080p120` : `nominalBytesPerSecond(1920,1080,120) × 3600` entre 9 et 11 Go.
  - `remainingAccountsForCleanedCopyAndSafety` : 13,5 Go libres à 2,8 Mo/s → ≈ 3 571 s (±1 %) ; 0,4 Go libres → 0.
- [ ] **Step 2:** `swift test --filter "FormatChooserTests|StorageEstimatorTests"` → FAIL.
- [ ] **Step 3:** Implémenter les deux.
- [ ] **Step 4:** Relancer → PASS.
- [ ] **Step 5:** Commit `feat(core): format choice and storage estimate`.

### Task 6: Nettoyage vidéo

**Files:**
- Create: `Sources/StrobeCore/VideoCleaner.swift`, `Tests/StrobeCoreTests/Support/SyntheticVideo.swift`
- Test: `Tests/StrobeCoreTests/VideoCleanerTests.swift`

**Interfaces:**
- Consumes: `LumaSampler`, `OfflineFlashDetector`, `FrameSelector`
- Produces:
  - `public struct CleanerConfig: Sendable, Codable, Equatable { public var detector = FlashDetectorConfig(); public var outputFPS = 30.0; public var maxHoldSeconds = 0.2 }`
  - `public struct FrameRecord: Sendable, Codable, Equatable { public var time: Double; public var stats: FrameStats; public var verdict: FrameVerdict }`
  - `public struct CleanReport: Sendable, Codable, Equatable { public var totalFrames: Int; public var flashFrames: Int; public var selection: SelectionReport }`
  - `public struct VideoCleaner: Sendable { public init(config: CleanerConfig = .init()); public func analyze(_ url: URL, progress: @Sendable (Double) -> Void) async throws -> [FrameRecord]; public func clean(input: URL, output: URL, progress: @Sendable (Double) -> Void) async throws -> CleanReport }`
  - Test support : `enum SyntheticVideo { static func make(at url: URL, fps: Double, seconds: Double, size: CGSize, flashIndices: Set<Int>, baseLuma: Double, withAudio: Bool, fragmentInterval: Double? = nil, truncateAfterSeconds: Double? = nil) throws }` — chaque image porte son indice source encodé en blocs noirs/blancs dans une bande du haut (16 bits), pour que les tests relisent quelle image source a été gardée ; audio = sinus 440 Hz.

Pipeline : passe 1 (`analyze`, progression 0→0,5) lit la piste vidéo en `420YpCbCr8BiPlanarFullRange` avec `AVAssetReader`, calcule `FrameStats` et l'horodatage, puis `OfflineFlashDetector`. Passe 2 (0,5→1) : `FrameSelector.select`, relecture du fichier, écriture des images choisies avec `AVAssetWriterInputPixelBufferAdaptor` à l'horodatage `k/outputFPS`, HEVC, même résolution et même `preferredTransform` que l'original ; la piste audio est recopiée sans réencodage (sortie `outputSettings: nil`, entrée avec `sourceFormatHint`). Pas de piste audio → vidéo seule. Vérifie `Task.isCancelled` toutes les 30 images et lève `CancellationError`. Écrit d'abord dans `output` + `.partial`, renomme à la fin.

- [ ] **Step 1: Write the failing tests** (fichiers générés dans un dossier temporaire, 120 i/s, 320×180) :
  - `noStrobeKeepsEveryFourthFrame` : 3 s sans flash → 90 images en sortie, indices source relus = `0, 4, 8, …`, `flashFrames == 0`.
  - `strobeFramesRemoved` : flash tous les 10 indices → aucun indice source relu n'appartient à `flashIndices`.
  - `durationsPreserved` : durée vidéo sortie = durée entrée ± 1/30 s ; durée audio sortie = durée audio entrée ± 1/30 s.
  - `worksWithoutAudio` : `withAudio: false` → sortie lisible, une seule piste vidéo.
  - `cleansFragmentedPartialFile` : fichier écrit avec `fragmentInterval: 1` et coupé avant `finishWriting` (`truncateAfterSeconds: 2.5`) → `clean` réussit, durée sortie ≥ 2 s.
  - `originalUntouched` : SHA-256 du fichier d'entrée identique avant et après `clean`.
  - `cancellationStopsAndLeavesNoOutput` : annuler la `Task` en cours → `CancellationError`, ni `output` ni `.partial` présents.
  - `writesSampleForCLI` : écrit `/tmp/strobe-sample.mov` (5 s, 120 i/s, 640×360, flash tous les 10 indices, audio) ; sert d'échantillon aux Tasks 7 et 11.
- [ ] **Step 2:** `swift test --filter VideoCleanerTests` → FAIL.
- [ ] **Step 3:** Implémenter `SyntheticVideo` puis `VideoCleaner`.
- [ ] **Step 4:** `swift test --filter VideoCleanerTests` → PASS ; puis `swift test` complet → PASS.
- [ ] **Step 5:** Commit `feat(core): video cleaning pipeline`.

### Task 7: Outil de réglage `strobe-tune`

**Files:**
- Modify: `Sources/strobe-tune/main.swift`

**Interfaces:**
- Consumes: `VideoCleaner`, `CleanerConfig`

Usage : `swift run strobe-tune <entrée.mov> [--out nettoyée.mov] [--csv images.csv] [--jump 1.6] [--margin 0.04] [--sat 0.25] [--window 0.5] [--max-run 0.12] [--hold 0.2]`. Sans `--out`, analyse seule. Le CSV a une ligne par image : `index,time,meanLuma,saturatedFraction,verdict`. Affiche en fin le `CleanReport` (total, flashs, créneaux répétés, replis). Parsing d'arguments à la main (pas de dépendance).

- [ ] **Step 1:** Implémenter.
- [ ] **Step 2:** Vérifier : `swift test --filter writesSampleForCLI` (Task 6), puis `swift run strobe-tune /tmp/strobe-sample.mov --csv /tmp/s.csv --out /tmp/s-clean.mov` → code 0, CSV avec une ligne par image, rapport cohérent avec les flashs générés.
- [ ] **Step 3:** Commit `feat(tools): strobe-tune CLI`.

### Task 8: Persistance des travaux et textes d'état

**Files:**
- Create: `Sources/StrobeCore/CleaningJobStore.swift`, `Sources/StrobeCore/StatusText.swift`
- Test: `Tests/StrobeCoreTests/CleaningJobStoreTests.swift`, `Tests/StrobeCoreTests/StatusTextTests.swift`

**Interfaces:**
- Produces:
  - `public enum JobState: String, Sendable, Codable { case recorded, cleaned, saved }`
  - `public struct CleaningJob: Sendable, Codable, Equatable, Identifiable { public var id: UUID; public var originalFile: String; public var cleanedFile: String?; public var state: JobState; public var createdAt: Date }` (noms de fichiers relatifs au dossier `Recordings/`)
  - `public actor CleaningJobStore { public init(directory: URL); public func all() -> [CleaningJob]; public func upsert(_ job: CleaningJob) throws; public func remove(id: UUID) throws; public func pending() -> [CleaningJob] }` — `pending()` = état ≠ `.saved`, triés par date ; JSON `jobs.json` écrit de façon atomique.
  - `public enum StatusText { public static func measurement(_ s: MeasurementState) -> String; public static func remaining(seconds: TimeInterval) -> String; public static func thermal(_ state: ProcessInfo.ThermalState) -> String?; public static func processing(progress: Double) -> String; public static let done: String; public static let unreliableReferenceConfirm: String }`

Textes exacts :
- `measuring(_, n)` → `"Mesure de la lumière… \(n) s"`
- `ready` → `"Exposition prête"`
- `failed(.notEnoughGoodFrames, _)` → `"Trop de flashs pour mesurer. Touche l'écran pour réessayer."`
- `failed(.tooDark, _)` → `"Scène très sombre : l'image sera sombre. Touche l'écran pour réessayer."`
- `remaining` → `"≈ 2 h 15 min restantes"`, `"≈ 45 min restantes"`, `"Moins d'1 min restante"`
- `thermal(.serious)` → `"L'iPhone chauffe"` ; `.critical` → `"L'iPhone est très chaud : il peut couper la caméra"` ; sinon `nil`
- `processing(0.42)` → `"Nettoyage de la vidéo… 42 %"`
- `done` → `"Les deux vidéos sont dans ta pellicule"`
- `unreliableReferenceConfirm` → `"La mesure n'est pas fiable. Filmer quand même ?"`

- [ ] **Step 1: Write the failing tests** : aller-retour `upsert`/`all` après recréation de l'acteur sur le même dossier ; `pending` exclut `.saved` ; `remove` ; un test par texte ci-dessus (valeurs exactes).
- [ ] **Step 2:** `swift test --filter "CleaningJobStoreTests|StatusTextTests"` → FAIL.
- [ ] **Step 3:** Implémenter.
- [ ] **Step 4:** Relancer → PASS.
- [ ] **Step 5:** Commit `feat(core): job store and status text`.

### Task 9: Squelette de l'app

**Files:**
- Create: `project.yml`, `App/AntiStroboApp.swift`, `App/UI/CameraScreen.swift` (provisoire : texte « Anti-Strobo »)

`project.yml` : cible `AntiStrobo` (application iOS, iOS 26.0, iPhone seulement, portrait + paysage), `DEVELOPMENT_TEAM: P55APCSVXL`, signature automatique, `PRODUCT_BUNDLE_IDENTIFIER: app.camantistrobo.ios`, `CFBundleDisplayName: Anti-Strobo`, `MARKETING_VERSION: 0.1.0`, `CURRENT_PROJECT_VERSION: 1`, `ITSAppUsesNonExemptEncryption: false`, `UIRequiresFullScreen: true`, `UIStatusBarHidden: true`, `BGTaskSchedulerPermittedIdentifiers: [app.camantistrobo.ios.clean.*]`, et les trois descriptions d'usage :
- caméra : « Anti-Strobo filme le concert. »
- micro : « Anti-Strobo enregistre le son du concert avec la vidéo. »
- photos (ajout) : « Anti-Strobo range la vidéo originale et la vidéo nettoyée dans ta pellicule. »
Dépendance : package local `Packages/StrobeCore`.

- [ ] **Step 1:** Écrire les fichiers, `xcodegen generate`.
- [ ] **Step 2:** `xcodebuild -project AntiStrobo.xcodeproj -scheme AntiStrobo -destination 'generic/platform=iOS Simulator' build` → `BUILD SUCCEEDED`.
- [ ] **Step 3:** Commit `chore(app): XcodeGen project skeleton`.

### Task 10: Caméra, mesure et enregistrement

**Files:**
- Create: `App/Camera/CameraController.swift`, `App/Camera/MovieRecorder.swift`, `App/UI/PreviewView.swift`

**Interfaces:**
- Consumes: `FormatChooser`, `CameraFormatInfo`, `ExposureMeter`, `Exposure`, `ExposureLimits`, `MeasurementState`, `LumaSampler`, `StorageEstimator`
- Produces:
  - `@MainActor @Observable final class CameraController { var measurement: MeasurementState; var isRecording: Bool; var recordingStartedAt: Date?; var bytesPerSecond: Double; let session: AVCaptureSession; func start() async; func remeasure(); func startRecording(); func stopRecording() async -> URL?; var onRecordingInterrupted: ((URL) -> Void)? }`
  - `final class MovieRecorder { init(url: URL, videoSettings: [String: Any], audioSettings: [String: Any]?, sourceFormat: CMFormatDescription); func append(video: CMSampleBuffer); func append(audio: CMSampleBuffer); func finish() async throws -> URL }`

Comportement :
- `start()` : demande caméra + micro ; caméra grand-angle arrière ; `FormatChooser.choose` sur `device.formats` ; `activeVideoMin/MaxFrameDuration = 1/fps` ; sorties `AVCaptureVideoDataOutput` (`420YpCbCr8BiPlanarFullRange`, `alwaysDiscardsLateVideoFrames = false`) et `AVCaptureAudioDataOutput` sur une file série dédiée ; stabilisation vidéo désactivée (elle ajoute du délai et peut mélanger les images) ; puis lance la mesure.
- Mesure : `ExposureLimits` depuis `activeFormat.minISO/maxISO`, `minExposureDuration`, et `maxDuration = min(activeFormat.maxExposureDuration, 1/fps)`. Exposition initiale = celle courante de l'appareil. Pour chaque image vidéo : `LumaSampler.stats`, `meter.ingest(..., appliedExposure:)` avec l'exposition lue sur l'appareil au moment de l'image (`device.exposureDuration`, `device.iso`) ; à chaque nouveau `meter.target`, `setExposureModeCustom(duration:iso:)`. Balance des blancs verrouillée en même temps que l'exposition. `remeasure()` recrée l'`ExposureMeter` (interdit pendant l'enregistrement).
- Enregistrement : fichier `Recordings/<uuid>.mov` dans Documents ; HEVC, résolution du format, `AVVideoExpectedSourceFrameRateKey = fps` ; audio AAC 48 kHz stéréo si micro autorisé ; `movieFragmentInterval = 1 s` (un enregistrement coupé reste lisible). Aucune modification d'exposition pendant l'enregistrement (les appels `setExposureModeCustom` sont bloqués tant que `isRecording`). `bytesPerSecond` mis à jour chaque seconde d'après la taille du fichier.
- Interruptions : `AVCaptureSession.wasInterrupted` / `runtimeError` pendant l'enregistrement → `finish()` puis `onRecordingInterrupted(url)` ; l'original est remis au nettoyage comme un enregistrement normal.

- [ ] **Step 1:** Implémenter les trois fichiers.
- [ ] **Step 2:** Build simulateur → `BUILD SUCCEEDED` (le simulateur n'a pas de caméra : la vérification réelle se fera sur iPhone, Task 13).
- [ ] **Step 3:** Commit `feat(app): capture, reference metering and recording`.

### Task 11: Nettoyage en arrière-plan et sauvegarde Photos

**Files:**
- Create: `App/Processing/CleaningCoordinator.swift`
- Modify: `App/AntiStroboApp.swift`

**Interfaces:**
- Consumes: `VideoCleaner`, `CleaningJobStore`, `CleaningJob`, `JobState`
- Produces: `@MainActor @Observable final class CleaningCoordinator { var progress: Double?; var lastFinished: Date?; var pendingCount: Int; var error: String?; func enqueue(original: URL) async; func resumePending() }`

Comportement :
- `enqueue` (appelé juste après le toucher sur « Stop », donc suite à une action de l'utilisateur, comme l'exige iOS) : `upsert` du travail `.recorded`, puis soumet `BGContinuedProcessingTaskRequest(identifier: "app.camantistrobo.ios.clean.\(job.id)", title: "Nettoyage de la vidéo", subtitle: …)`. Le gestionnaire, enregistré au lancement dans `AntiStroboApp` avec `BGTaskScheduler.shared.register(forTaskWithIdentifier: "app.camantistrobo.ios.clean.*", …)`, lance `VideoCleaner.clean`, met à jour `task.progress` et `progress`, et à l'expiration annule la `Task` (le travail reste `.recorded`).
- Si la soumission est refusée par le système : nettoyage au premier plan avec la même progression.
- Fin du nettoyage → `.cleaned` ; puis `PHPhotoLibrary.shared().performChanges` ajoute l'original puis la version nettoyée (accès « ajout seulement ») → `.saved` ; ensuite seulement, suppression des copies locales dans `Recordings/` (choix de Claude : libérer la place, les fichiers vivent désormais dans Photos ; l'original lui-même n'est jamais modifié).
- Au lancement : `resumePending()` met `pendingCount` à jour ; l'écran affiche « Reprendre le nettoyage » (iOS n'autorise la tâche de fond que suite à un toucher), qui relance `enqueue` pour chaque travail en attente (un `.cleaned` passe directement à la sauvegarde Photos).

- [ ] **Step 1:** Implémenter.
- [ ] **Step 2:** Build simulateur → `BUILD SUCCEEDED`.
- [ ] **Step 3:** Vérification simulateur : un bouton de débogage `#if DEBUG` « Nettoyer un échantillon » copie une vidéo de test (`/tmp/strobe-sample.mov` de la Task 6, copiée dans `App/DebugResources/strobe-sample.mov`, ressource incluse seulement en Debug via `project.yml`) dans `Recordings/` et appelle `enqueue` ; lancer l'app dans le simulateur, toucher le bouton, constater la progression puis « Les deux vidéos sont dans ta pellicule » et deux vidéos dans Photos du simulateur.
- [ ] **Step 4:** Commit `feat(app): background cleaning and Photos export`.

### Task 12: Écran caméra

**Files:**
- Modify: `App/UI/CameraScreen.swift`
- Create: `App/UI/ProcessingBanner.swift`

**Interfaces:**
- Consumes: `CameraController`, `CleaningCoordinator`, `StatusText`, `StorageEstimator`

Contenu de l'écran (textes tous issus de `StatusText`) :
- Aperçu plein écran.
- Badge de mesure en haut, bien visible : compte à rebours pendant la mesure, « Exposition prête » en vert, message d'échec en orange. Toucher l'aperçu → `remeasure()` (sans effet pendant l'enregistrement).
- Barre d'état : temps restant (`StorageEstimator.remainingRecordingSeconds` avec `volumeAvailableCapacityForImportantUsageKey` et, avant l'enregistrement, `nominalBytesPerSecond` ; pendant, `bytesPerSecond` mesuré), batterie (`UIDevice.batteryLevel`), alerte de chauffe (`ProcessInfo.thermalStateDidChangeNotification`).
- Gros bouton enregistrer : grisé pendant la mesure ; plein quand `ready` ; en `failed`, toucher affiche la confirmation `unreliableReferenceConfirm` puis enregistre. Pendant l'enregistrement : chrono et bouton stop.
- `ProcessingBanner` : progression `processing(progress)`, puis `done` 4 s ; bouton « Reprendre le nettoyage » si `pendingCount > 0` et rien en cours.
- `UIApplication.shared.isIdleTimerDisabled = true` pendant que l'écran caméra est affiché.

- [ ] **Step 1:** Implémenter.
- [ ] **Step 2:** Build simulateur → `BUILD SUCCEEDED` ; lancer dans le simulateur et vérifier par capture que l'écran s'affiche sans plantage (l'aperçu est noir, sans caméra) et que la bannière de nettoyage de l'échantillon de debug fonctionne.
- [ ] **Step 3:** Commit `feat(app): camera screen`.

### Task 13: Build TestFlight (avec le go de l'auteur)

**Files:**
- Create: `Config/ExportOptions-TestFlight-Internal.plist` (méthode `app-store-connect`, `destination: upload`, `teamID: P55APCSVXL`, `testFlightInternalTestingOnly: true`, signature automatique), `scripts/testflight.sh`

`scripts/testflight.sh` : `xcodegen generate`, incrémente `CURRENT_PROJECT_VERSION`, `xcodebuild archive` (Release, `-derivedDataPath build/dd-archive`), puis `xcodebuild -exportArchive -exportOptionsPlist Config/ExportOptions-TestFlight-Internal.plist -allowProvisioningUpdates -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"`. Les trois variables viennent d'un `.env.local` non versionné (modèle : `.env.local.example`). L'app doit d'abord exister dans App Store Connect (bundle id `app.camantistrobo.ios`) : la créer via l'API ou demander à l'auteur.

- [ ] **Step 1:** Écrire les fichiers ; `swift test` complet → PASS ; build Release simulateur → `BUILD SUCCEEDED`.
- [ ] **Step 2:** **Demander le go à l'auteur.** Puis lancer `scripts/testflight.sh` → `EXPORT SUCCEEDED` / upload terminé.
- [ ] **Step 3:** Commit `chore: TestFlight build 1`, tag `build-1`.
- [ ] **Step 4:** Recette à remettre à l'auteur : sur iPhone, ouvrir l'app face à une source stroboscopique (lampe strobe, ou appli strobe sur un autre écran dans une pièce sombre) ; vérifier le compte à rebours puis « Exposition prête » ; filmer 30 s ; vérifier les deux vidéos dans la pellicule, l'absence d'images blanches dans la version nettoyée, le son synchro. Rapatrier l'original sur le Mac et le passer dans `strobe-tune --csv` pour régler les seuils.
