import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "VideoCleaner")

/// Réglages du nettoyage : détection des éclairs, choix et reconstitution des images de sortie.
public struct CleanerConfig: Sendable, Codable, Equatable {
    /// Seuils du détecteur d'éclairs hors ligne.
    public var detector = FlashDetectorConfig()
    /// Cadence de la vidéo nettoyée (images par seconde).
    public var outputFPS = 30.0
    /// Durée maximale (secondes) pendant laquelle une bonne image est répétée faute de mieux.
    public var maxHoldSeconds = 0.2
    /// Recrée les images des créneaux sans bonne image par interpolation, quand l'appareil le permet ; faux,
    /// ou interpolation non prise en charge : choix des images de la V1 (répéter, puis image la moins brûlée).
    public var interpolate = true
    /// Écart maximal (secondes) entre les deux bonnes images qui bordent un trou pour le recréer ; relevé
    /// jusqu'au plus long trou qu'une lumière peut laisser, et borné à `interpolationGapLimit` (voir
    /// `effectiveInterpolationGap(frameStep:)`).
    public var maxInterpolationGap = 0.35
    /// Débruite la vidéo nettoyée quand la scène est sombre (`VideoCleaner.isDarkScene`), si l'appareil le permet.
    public var denoise = true
    /// Éclaircit la vidéo nettoyée d'une scène sombre (`ShadowLift.forScene`), et débruite alors plus fort.
    public var brightenDarkScenes = true

    public init() {}

    /// Plafond (secondes) de l'écart recréé : toutes les images d'un trou restent en mémoire jusqu'à leur
    /// écriture, et au-delà d'une demi-seconde le mouvement inventé entre A et B ne ressemble plus à la scène.
    public static let interpolationGapLimit = 0.5

    /// L'écart que le nettoyage applique à une vidéo dont l'écart médian entre deux images est `frameStep` :
    /// `min(interpolationGapLimit, max(maxInterpolationGap, detector.maxFlashRunSeconds + 2 × frameStep + 1 µs))`.
    ///
    /// Le détecteur garde comme lumière une période qui s'étend sur `maxFlashRunSeconds` au plus ; les deux
    /// bonnes images qui la bordent sont alors à `maxFlashRunSeconds + 2 × frameStep`. À 30 i/s, une lumière de
    /// 0,3 s laisse ainsi 11/30 s ≈ 0,367 s : avec 0,35 s, ce trou n'était pas recréé et la lumière retirée
    /// revenait dans la vidéo (maintien, puis image la moins brûlée). À 120 et 60 i/s, `maxInterpolationGap`
    /// l'emporte. Sans écart connu (`nil`), seule la durée de la lumière compte.
    ///
    /// Un `maxInterpolationGap` nul, négatif ou non numérique garde son sens (aucun trou recréé) et est rendu
    /// tel quel.
    public func effectiveInterpolationGap(frameStep: Double?) -> Double {
        guard maxInterpolationGap > 0 else { return maxInterpolationGap }
        let step = frameStep.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        let longestLightGap = detector.maxFlashRunSeconds + 2 * step + FlashDetectorConfig.runLengthTolerance
        // Comparaison fausse pour une durée de lumière non numérique : `maxInterpolationGap` reste.
        let gap = longestLightGap > maxInterpolationGap ? longestLightGap : maxInterpolationGap
        return min(gap, Self.interpolationGapLimit)
    }
}

/// Une image source analysée.
public struct FrameRecord: Sendable, Codable, Equatable {
    /// Horodatage en secondes sur la ligne de temps du fichier (`presentationTimeStamp`, sans recalage).
    public var time: Double
    public var stats: FrameStats
    public var verdict: FrameVerdict

    public init(time: Double, stats: FrameStats, verdict: FrameVerdict) {
        self.time = time
        self.stats = stats
        self.verdict = verdict
    }
}

/// Bilan d'un nettoyage.
public struct CleanReport: Sendable, Codable, Equatable {
    /// Nombre d'images de la vidéo source.
    public var totalFrames: Int
    /// Nombre d'images source jugées avec lumière (retirées).
    public var flashFrames: Int
    /// Bilan du plan des créneaux suivi par l'écriture (sans interpolation si la synthèse n'a pas pu démarrer).
    /// Les créneaux interpolés au plan dont la synthèse a échoué y restent comptés comme interpolés : voir
    /// `failedInterpolations`.
    public var selection: SelectionReport
    /// Créneaux interpolés au plan (parmi `selection.interpolatedSlots`) que la synthèse n'a pas recréés : ils
    /// répètent la dernière bonne image d'avant le trou. 0 sans écriture (`plannedReport`).
    public var failedInterpolations: Int
    /// Images de la vidéo nettoyée passées par le débruitage : 0 si la scène n'est pas sombre, si le
    /// débruitage est désactivé ou non pris en charge, ou sans écriture (`plannedReport`).
    public var denoisedFrames: Int
    /// Éclaircissement de la scène (`ShadowLift.forScene`) ; `.none` si elle n'est pas sombre, si
    /// l'éclaircissement est désactivé, ou sans écriture.
    public var shadowLift: ShadowLift
    /// Images de la vidéo nettoyée éclaircies (sans échec) ; 0 avec `shadowLift` à `.none`.
    public var brightenedFrames: Int
    /// Durée (secondes, horloge murale) de la passe d'analyse ; 0 quand l'analyse a été faite à part
    /// (`plannedReport`, ou écriture à partir d'une analyse donnée).
    public var analysisSeconds: Double
    /// Durée (secondes, horloge murale) de la passe d'écriture, synthèse et débruitage compris ; 0 sans écriture.
    public var writingSeconds: Double

    public init(
        totalFrames: Int,
        flashFrames: Int,
        selection: SelectionReport,
        failedInterpolations: Int = 0,
        denoisedFrames: Int = 0,
        shadowLift: ShadowLift = .none,
        brightenedFrames: Int = 0,
        analysisSeconds: Double = 0,
        writingSeconds: Double = 0
    ) {
        self.totalFrames = totalFrames
        self.flashFrames = flashFrames
        self.selection = selection
        self.failedInterpolations = failedInterpolations
        self.denoisedFrames = denoisedFrames
        self.shadowLift = shadowLift
        self.brightenedFrames = brightenedFrames
        self.analysisSeconds = analysisSeconds
        self.writingSeconds = writingSeconds
    }
}

/// Échecs propres au nettoyage. Les erreurs d'AVFoundation sont remontées telles quelles,
/// l'annulation par `CancellationError`.
public enum VideoCleanerError: Error, Equatable {
    /// Le fichier n'a pas de piste vidéo.
    case noVideoTrack
    /// La piste vidéo ne donne aucune image de sortie (aucune image lisible, ou durée nulle).
    case noVideoFrames
    /// La sortie demandée (ou son `.partial`) est le fichier d'origine, qui ne doit jamais être modifié.
    case outputIsInput
    /// La relecture de la source ne redonne pas les images de l'analyse (fichier modifié entre les deux
    /// passes, image illisible à la seconde lecture) : la vidéo nettoyée serait fausse.
    case sourceChanged
    /// Les horodatages de l'analyse reculent (fichier abîmé) : les images choisies ne peuvent pas être reprises
    /// dans l'ordre de la relecture. Le travail reste à reprendre, l'original est intact.
    case unorderedFrames
    /// La lecture a échoué sans erreur AVFoundation.
    case readFailed
    /// L'écriture a échoué sans erreur AVFoundation.
    case writeFailed
}

/// Nettoie une vidéo filmée à 120 i/s : retire les images brûlées par les stroboscopes et produit une
/// vidéo 30 i/s de même durée, audio recopié sans réencodage. L'original n'est jamais modifié.
///
/// Deux passes sur le fichier : `analyze` mesure chaque image et juge les éclairs (`OfflineFlashDetector`),
/// puis l'écriture planifie chaque créneau de sortie (`FrameSelector.plan`), recrée les images des trous
/// (`FrameSynthesizer`), débruite une scène sombre (`NoiseReducer`) et réencode en HEVC.
/// Les horodatages sont ceux de la ligne de temps du fichier, sans recalage : l'image de sortie k est
/// écrite à k / `outputFPS`, l'audio garde ses horodatages d'origine.
public struct VideoCleaner: Sendable {
    /// Nombre d'images (lues ou écrites) entre deux vérifications de l'annulation, et entre deux avancements.
    static let cancellationInterval = 30

    public let config: CleanerConfig

    public init(config: CleanerConfig = .init()) {
        self.config = config
    }

    /// Mesure et juge chaque image de la piste vidéo de `url`, dans l'ordre d'affichage.
    ///
    /// Toujours exécutée hors de l'acteur de l'appelant (`@concurrent`). `progress` reçoit une fraction
    /// croissante de 0 à 1 (1 à la fin). Vérifie l'annulation toutes les 30 images et lève alors
    /// `CancellationError`.
    @concurrent
    public func analyze(_ url: URL, progress: @Sendable (Double) -> Void) async throws -> [FrameRecord] {
        let source = try await SourceVideo(url: url)
        let records = try await analyzeFrames(of: source, progress: progress)
        progress(1)
        return records
    }

    /// Écrit à `output` la version nettoyée de `input` et renvoie le bilan.
    ///
    /// Toujours exécutée hors de l'acteur de l'appelant (`@concurrent`). L'écriture se fait d'abord dans
    /// `output` + `.partial`, renommé en `output` à la fin (un `output` existant est remplacé). En cas
    /// d'erreur ou d'annulation (`CancellationError`), le `.partial` est supprimé et un `output` existant
    /// reste intact. Si `output` ou son `.partial` désigne le fichier d'origine (même chemin, lien
    /// symbolique ou lien dur), rien n'est touché : `VideoCleanerError.outputIsInput`. `progress` reçoit une
    /// fraction croissante : 0…0,5 pour l'analyse, 0,5…1 pour l'écriture, 1 une fois `output` en place.
    @concurrent
    public func clean(
        input: URL,
        output: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> CleanReport {
        // Refuser avant toute suppression : le `.partial` d'un nettoyage interrompu est effacé juste après.
        let partial = Self.partialURL(for: output)
        guard !Self.isSameFile(input, output), !Self.isSameFile(input, partial) else {
            throw VideoCleanerError.outputIsInput
        }
        // Un `.partial` laissé par un nettoyage interrompu (app tuée) ne doit pas survivre à celui-ci.
        try? FileManager.default.removeItem(at: partial)

        let clock = ContinuousClock()
        let analysisStart = clock.now
        let source = try await SourceVideo(url: input)
        let records = try await analyzeFrames(of: source) { progress($0 * 0.5) }
        let analysisDuration = clock.now - analysisStart
        var report = try await render(records, of: source, to: output, progress: progress)
        report.analysisSeconds = analysisDuration.seconds
        return report
    }

    /// Bilan qu'aurait donné `clean` pour l'analyse `records` de `url`, sans rien écrire : même plan des
    /// créneaux (durée de la piste vidéo, interpolation si `config.interpolate` et si l'appareil la prend en
    /// charge à la taille de la vidéo). `denoisedFrames` vaut 0. Permet d'itérer sur les seuils sans payer
    /// l'écriture HEVC.
    public func plannedReport(for records: [FrameRecord], of url: URL) async throws -> CleanReport {
        let source = try await SourceVideo(url: url)
        let (slots, selection) = plannedSlots(for: records, of: source, canInterpolate: FrameSynthesizer.isSupported)
        // Comme le nettoyage : aucune image de sortie, c'est un échec.
        guard !slots.isEmpty else { throw VideoCleanerError.noVideoFrames }
        return CleanReport(
            totalFrames: records.count,
            flashFrames: records.count { $0.verdict == .flash },
            selection: selection
        )
    }

    /// Plan des créneaux que suivra le nettoyage : interpolation si `config.interpolate` et si l'appareil sait
    /// recréer des images à la taille de la vidéo (`canInterpolate`). Le même pour `clean` et `plannedReport`.
    func plannedSlots(
        for records: [FrameRecord],
        of source: SourceVideo,
        canInterpolate: (_ width: Int, _ height: Int) -> Bool
    ) -> (slots: [SlotPlan], report: SelectionReport) {
        let size = source.frameSize
        return slotPlan(
            for: records,
            duration: source.end,
            interpolationAvailable: config.interpolate && canInterpolate(size.width, size.height)
        )
    }

    /// Plan des créneaux de sortie pour l'analyse `records` (`FrameSelector.plan` avec les réglages ; écart
    /// recréé d'après la cadence de la vidéo, voir `CleanerConfig.effectiveInterpolationGap(frameStep:)`).
    func slotPlan(
        for records: [FrameRecord],
        duration: Double,
        interpolationAvailable: Bool
    ) -> (slots: [SlotPlan], report: SelectionReport) {
        let times = records.map(\.time)
        return FrameSelector.plan(
            times: times,
            verdicts: records.map(\.verdict),
            stats: records.map(\.stats),
            duration: duration,
            outputFPS: config.outputFPS,
            maxHoldSeconds: config.maxHoldSeconds,
            maxInterpolationGap: config.effectiveInterpolationGap(frameStep: medianStep(of: times)),
            interpolationAvailable: interpolationAvailable
        )
    }

    /// Vrai si l'appareil offre la synthèse d'images de VideoToolbox, toutes tailles confondues
    /// (`VTFrameRateConversionConfiguration.isSupported`). Toujours faux au simulateur. Pour le journal : le
    /// nettoyage vérifie la taille de chaque vidéo.
    public static var deviceSupportsInterpolation: Bool { FrameSynthesizer.isAvailable }

    /// Vrai si l'appareil offre le débruitage de VideoToolbox, toutes tailles confondues
    /// (`VTTemporalNoiseFilterConfiguration.isSupported`). Toujours faux au simulateur.
    public static var deviceSupportsDenoise: Bool { NoiseReducer.isAvailable }

    /// Luma moyenne des bonnes images sous laquelle la scène est sombre (débruitage).
    static let darkSceneLuma = 0.3

    /// Vrai si la scène est sombre : luma moyenne médiane des bonnes images sous `darkSceneLuma`. Le nettoyage
    /// ne connaît pas la sensibilité de la prise de vue : on suppose qu'une scène sombre a été filmée à haute
    /// sensibilité, donc avec du grain à retirer. Sans bonne image : faux.
    static func isDarkScene(_ records: [FrameRecord]) -> Bool {
        guard let luma = sceneLuma(records) else { return false }
        return luma < darkSceneLuma
    }

    /// Luma moyenne médiane des bonnes images de `records`, ou `nil` s'il n'y en a aucune.
    static func sceneLuma(_ records: [FrameRecord]) -> Double? {
        let lumas = records.filter { $0.verdict == .good }.map(\.stats.meanLuma).sorted()
        guard !lumas.isEmpty else { return nil }
        let middle = lumas.count / 2
        return lumas.count.isMultiple(of: 2) ? (lumas[middle - 1] + lumas[middle]) / 2 : lumas[middle]
    }

    /// Passe 2 à partir de l'analyse `records` : planifie les créneaux, écrit `output` + `.partial` (qui ne
    /// doit pas exister) et le renomme en `output`. `progress` reçoit 0,5…1.
    ///
    /// La synthèse n'est créée que si le plan a des trous à recréer ; si elle ne peut pas l'être, le plan
    /// repart sans interpolation (V1).
    ///
    /// Séparée de `clean` pour que les tests puissent fournir une analyse qui ne correspond plus à la source,
    /// ou d'autres traitements d'image (appelés avec la taille des images) : prise en charge de la synthèse
    /// (`canInterpolate`), synthèse (`makeInterpolator`) et débruitage (`makeReducer`).
    func render(
        _ records: [FrameRecord],
        of source: SourceVideo,
        to output: URL,
        canInterpolate: (_ width: Int, _ height: Int) -> Bool = FrameSynthesizer.isSupported,
        makeInterpolator: (_ width: Int, _ height: Int) -> (any FrameInterpolator)? = {
            FrameSynthesizer(width: $0, height: $1)
        },
        makeReducer: (_ width: Int, _ height: Int, _ strength: Float) -> NoiseReducer? = {
            NoiseReducer(width: $0, height: $1, strength: $2)
        },
        progress: (Double) -> Void
    ) async throws -> CleanReport {
        let clock = ContinuousClock()
        let writingStart = clock.now
        let size = source.frameSize
        var (slots, selection) = plannedSlots(for: records, of: source, canInterpolate: canInterpolate)
        guard !slots.isEmpty else { throw VideoCleanerError.noVideoFrames }
        // Sessions des processeurs closes dans tous les cas, avant de les lâcher (voir `FrameSynthesizer`).
        var interpolator: (any FrameInterpolator)?
        defer { interpolator?.finish() }
        if selection.interpolatedSlots > 0 {
            interpolator = makeInterpolator(size.width, size.height)
            if interpolator == nil {
                (slots, selection) = slotPlan(for: records, duration: source.end, interpolationAvailable: false)
            }
        }
        let wanted = config.brightenDarkScenes ? Self.sceneLuma(records).map(ShadowLift.forScene) ?? .none : .none
        let lifter = wanted.isNone ? nil : ShadowLifter(lift: wanted, width: size.width, height: size.height)
        // Sans éclaircissement (pas voulu, ou impossible à préparer), le débruitage d'avant.
        let lift = lifter == nil ? ShadowLift.none : wanted
        let reducer = config.denoise && Self.isDarkScene(records)
            ? makeReducer(size.width, size.height, lift.denoiseStrength)
            : nil
        defer { reducer?.finish() }
        if !lift.isNone {
            log.notice("""
                Scène sombre éclaircie : +\(lift.exposureEV, format: .fixed(precision: 2)) IL, \
                ombres \(lift.shadows, format: .fixed(precision: 2)), \
                débruitage \(lift.denoiseStrength, format: .fixed(precision: 2))
                """)
        }
        progress(0.5)

        let partial = Self.partialURL(for: output)
        let outcome: WriteOutcome
        do {
            outcome = try await write(
                slots, times: records.map(\.time), from: source, to: partial,
                interpolator: interpolator, reducer: reducer, lifter: lifter
            ) { progress(0.5 + $0 * 0.5) }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: output)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        progress(1)
        let failures = outcome.failureLog
        if failures.undetailed > 0 {
            log.error("""
                \(failures.failures) trou(s) non recréé(s) en tout (\(outcome.failedInterpolations) créneau(x)), \
                dont \(failures.undetailed) non détaillé(s)
                """)
        }
        return CleanReport(
            totalFrames: records.count,
            flashFrames: records.count { $0.verdict == .flash },
            selection: selection,
            failedInterpolations: outcome.failedInterpolations,
            denoisedFrames: outcome.denoisedFrames,
            shadowLift: lift,
            brightenedFrames: outcome.brightenedFrames,
            writingSeconds: (clock.now - writingStart).seconds
        )
    }

    /// Part de l'avancement de la passe 1 donnée à la lecture des images ; le reste va au jugement des zones.
    static let readingShareOfAnalysis = 0.9

    /// Passe 1 : lit toutes les images, les mesure, puis juge les éclairs. `progress` reçoit 0…1 (sans le 1 final) :
    /// jusqu'à `readingShareOfAnalysis` pendant la lecture, le reste zone après zone pendant le jugement, qui peut
    /// durer pour une longue vidéo (iOS arrête une tâche de fond qui n'avance plus).
    private func analyzeFrames(of source: SourceVideo, progress: (Double) -> Void) async throws -> [FrameRecord] {
        let frames = try VideoFrames(of: source)
        defer { frames.cancel() }

        var times: [Double] = []
        var stats: [FrameStats] = []
        var checkpoint = CancellationCheckpoint()
        var reported = 0.0
        while let frame = try frames.next() {
            times.append(frame.time)
            stats.append(LumaSampler.stats(of: frame.image))
            try await checkpoint.step()
            if times.count.isMultiple(of: VideoCleaner.cancellationInterval) {
                // Avancement d'après l'horodatage, borné à 0…1 et jamais en recul.
                let fraction = min(1, max(0, (frame.time - source.start) / (source.end - source.start)))
                    * Self.readingShareOfAnalysis
                if fraction > reported {
                    reported = fraction
                    progress(fraction)
                }
            }
        }

        let framesWithoutZones = stats.lazy.filter(\.zoneLumas.isEmpty).count
        if framesWithoutZones > 0 {
            // Une seule image sans zones (image illisible, format inattendu) et les zones ne sont plus jugées.
            log.error("\(framesWithoutZones) images sur \(stats.count) sans zones : seule l'image entière est jugée")
        }
        let verdicts = try OfflineFlashDetector.classify(stats, times: times, config: config.detector) { done, total in
            try Task.checkCancellation()
            let fraction = Self.readingShareOfAnalysis + (1 - Self.readingShareOfAnalysis) * Double(done) / Double(total)
            if fraction > reported, fraction < 1 {
                reported = fraction
                progress(fraction)
            }
        }
        // Les zones ne servent qu'à juger : la suite n'en garde pas de copie (64 octets par image).
        return times.indices.map {
            FrameRecord(time: times[$0], stats: stats[$0].withoutZones, verdict: verdicts[$0])
        }
    }

    /// Fichier intermédiaire du nettoyage vers `output`.
    static func partialURL(for output: URL) -> URL {
        URL(fileURLWithPath: output.path + ".partial")
    }

    /// Vrai si `first` et `second` désignent le même fichier : même chemin une fois les liens symboliques
    /// résolus, ou même identifiant de fichier (liens durs, casse différente sur un volume insensible).
    /// Un chemin inexistant n'est égal qu'à lui-même.
    public static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        let first = first.standardizedFileURL.resolvingSymlinksInPath()
        let second = second.standardizedFileURL.resolvingSymlinksInPath()
        if first.path == second.path { return true }
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let firstID = try? first.resourceValues(forKeys: key).fileResourceIdentifier,
              let secondID = try? second.resourceValues(forKeys: key).fileResourceIdentifier
        else { return false }
        return firstID.isEqual(secondID)
    }
}

private extension Duration {
    /// La durée en secondes.
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
