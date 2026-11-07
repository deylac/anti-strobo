import Foundation

/// Un réglage d'exposition de la caméra : temps de pose et ISO.
public struct Exposure: Sendable, Equatable, Codable {
    public var durationSeconds: Double
    public var iso: Double

    /// Proportionnel à la lumière reçue par le capteur : `durée × ISO`.
    public var product: Double { durationSeconds * iso }

    public init(durationSeconds: Double, iso: Double) {
        self.durationSeconds = durationSeconds
        self.iso = iso
    }

    /// La même exposition, sa durée ramenée à `limits.maxDuration` au plus, ISO inchangé. Après un passage à une
    /// cadence plus haute (nouvelle série de mesures à 120 i/s après 30 i/s), la durée lue sur l'appareil peut
    /// encore être celle de l'ancienne cadence, alors qu'une pose ne dure jamais plus d'une image : ses images
    /// sont prises avec la durée ramenée, et la mesure doit partir de celle-là.
    public func clampingDuration(to limits: ExposureLimits) -> Exposure {
        Exposure(durationSeconds: min(durationSeconds, limits.maxDuration), iso: iso)
    }
}

/// Ce que l'appareil autorise. `maxDuration` est la durée d'une image (1/120 s à 120 i/s).
public struct ExposureLimits: Sendable, Equatable {
    public var minDuration: Double
    public var maxDuration: Double
    public var minISO: Double
    public var maxISO: Double

    public init(minDuration: Double, maxDuration: Double, minISO: Double, maxISO: Double) {
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.minISO = minISO
        self.maxISO = maxISO
    }

    /// Bornes d'un format filmé à `fps` : une pose dure au plus une image, celle de la cadence comme celle que
    /// l'appareil applique vraiment (`appliedFrameDuration`, ramenée dans la plage du format), et pas plus que
    /// le format ne le permet : `maxDuration = max(minDuration, min(formatMaxDuration, 1/fps,
    /// appliedFrameDuration))`.
    public init(
        minDuration: Double,
        formatMaxDuration: Double,
        fps: Double,
        appliedFrameDuration: Double,
        minISO: Double,
        maxISO: Double
    ) {
        self.init(
            minDuration: minDuration,
            maxDuration: max(minDuration, min(formatMaxDuration, 1 / fps, appliedFrameDuration)),
            minISO: minISO,
            maxISO: maxISO
        )
    }

    fileprivate var minProduct: Double { minDuration * minISO }
    fileprivate var maxProduct: Double { maxDuration * maxISO }
}

public struct ExposureMeterConfig: Sendable {
    /// Luma moyenne que doit rendre l'exposition de référence.
    public var targetLuma = 0.42
    /// Écart maximal entre la luma mesurée et `targetLuma` pour qu'une étape soit stable.
    public var tolerance = 0.06
    /// Bonnes images par étape de mesure.
    public var framesPerStep = 24
    /// Étapes stables consécutives nécessaires pour déclarer l'exposition prête.
    public var requiredStableSteps = 2
    /// Au-delà (en secondes de vidéo), on s'arrête sur la meilleure exposition atteinte.
    public var timeoutSeconds = 10.0
    /// Gamma supposé entre le produit d'exposition et la luma : `luma ~ produit^(1 / gamma)`.
    public var gamma = 2.2
    /// À l'exposition maximale, une luma sous ce seuil veut dire que la scène est trop sombre pour être bien filmée.
    public var tooDarkLuma = 0.12
    /// Durée (secondes) de l'historique d'où l'on tire le rythme du stroboscope : les images plus anciennes sont
    /// oubliées, la mémoire reste bornée.
    public var rhythmWindowSeconds = 10.0

    public init() {}
}

public enum MeasurementFailure: Sendable, Equatable {
    /// Moins d'une étape d'images exploitables avant l'expiration (éclairs, images brûlées ou périmées seulement).
    case notEnoughGoodFrames
    /// Même l'exposition maximale rend une luma sous `tooDarkLuma`.
    case tooDark
}

public enum MeasurementState: Sendable, Equatable {
    /// `progress` est dans 0..<1 et ne recule jamais ; `secondsRemaining` vaut au moins 1 et ne remonte jamais.
    case measuring(progress: Double, secondsRemaining: Int)
    /// L'exposition de référence, à verrouiller pour tout l'enregistrement.
    case ready(Exposure)
    /// La mesure a échoué ; `best` est la meilleure exposition atteinte, pour pouvoir filmer quand même.
    case failed(MeasurementFailure, best: Exposure)
}

/// Cherche l'exposition qui rend une scène sans éclairs à `targetLuma`, en ignorant les éclairs du stroboscope.
///
/// Logique pure, sans accès à la caméra. Le code qui pilote la caméra donne chaque image avec l'exposition
/// qu'elle a réellement eue, et applique `target` à l'appareil chaque fois qu'il change.
///
/// Les images exploitables sont groupées en étapes de `framesPerStep`. Une étape dont la luma médiane est à
/// moins de `tolerance` de `targetLuma` est stable ; toute autre étape corrige le produit d'exposition de
/// `(targetLuma / médiane)^gamma`, ce qui remet à zéro le compte des étapes stables. La mesure est `ready`
/// après `requiredStableSteps` étapes stables d'affilée, ou à l'expiration (sauf échec). Une fois `ready` ou
/// `failed`, le mesureur ignore tout.
///
/// Une étape hors tolérance dont la correction ne peut plus bouger la cible, parce qu'elle est déjà à une
/// borne d'exposition, compte comme stable à cette borne : après `requiredStableSteps` étapes, le verdict
/// tombe sans attendre l'expiration (`failed(.tooDark)` au maximum si la luma est sous `tooDarkLuma`,
/// `ready` sinon).
///
/// Une image n'est *pas exploitable* quand elle :
/// - a été prise avec une exposition qui n'est pas (à 5 % près) la `target` courante : la caméra n'a pas encore
///   appliqué le nouveau réglage, et les appareils arrondissent les valeurs d'exposition, donc l'égalité
///   exacte n'est pas exigée ;
/// - est jugée « flash » par le détecteur en ligne ;
/// - est brûlée : plus de `FlashDetectorConfig.saturatedFractionMax` de ses pixels sont saturés, sa luma est
///   écrêtée et ne dit rien de la bonne exposition.
///
/// Si `framesPerStep` images de suite prises avec la `target` courante sont brûlées sans être jugées « flash »,
/// toute la scène est surexposée : le produit de `target` est divisé par 4 (les ISO baissent d'abord, puis la
/// durée), comme pour toute autre correction. Au produit minimum, on continue d'attendre jusqu'à l'expiration.
/// Une image avec lumière, brûlée ou non, est seulement écartée : une lumière allumée plus longtemps qu'une
/// étape n'est pas une surexposition, et ses images n'interrompent pas non plus une série d'images brûlées.
/// Une scène qui s'embrase d'un coup ressemble d'abord à une lumière : elle n'est vue comme surexposée qu'une
/// fois cette lumière plus longue que `FlashDetectorConfig.maxFlashRunSeconds`.
///
/// Quand une correction change la cible, les images déjà vues par le détecteur sont ramenées à la nouvelle
/// exposition (lumas × `(nouveau produit / ancien)^(1 / gamma)`) : les deux niveaux d'une lumière qui clignote
/// survivent au changement. Après une surexposition, leurs lumas écrêtées ne disent plus rien : le détecteur
/// repart de zéro.
///
/// Le mesureur garde aussi le verdict de chaque image jugée par le détecteur, pour en tirer le rythme du
/// stroboscope (`rhythm`) : le rythme ne dépend pas de l'exposition, cet historique traverse donc les
/// corrections de la cible. Il alimente le choix de la cadence de prise de vue (`CadencePlanner`) avec
/// `reachedMaximum`.
public struct ExposureMeter: Sendable {
    /// Verdict du détecteur sur une image, avec son horodatage : un point de l'historique du rythme.
    private struct RhythmSample: Sendable {
        var time: Double
        var verdict: FrameVerdict
    }

    /// L'exposition que la caméra doit appliquer.
    public private(set) var target: Exposure
    public private(set) var state: MeasurementState

    private let limits: ExposureLimits
    private let config: ExposureMeterConfig
    private let burntFractionMax: Double
    /// Durée maximale d'une lumière pour le détecteur : au-delà, c'est un changement d'éclairage (rythme).
    private let maxFlashRunSeconds: Double
    private var detector: OnlineFlashDetector

    /// Horodatage de la première image reçue, exploitable ou non : le délai d'expiration court depuis là.
    private var startTime: Double?
    /// Luma des images exploitables de l'étape en cours.
    private var stepLumas: [Double] = []
    private var stableSteps = 0
    /// Vrai dès qu'une étape complète a été mesurée.
    private var hasCompletedStep = false
    /// Images brûlées d'affilée, parmi celles prises avec la `target` courante.
    private var burntRun = 0
    /// Luma médiane de la dernière étape terminée, si elle a été mesurée avec la `target` courante.
    private var medianAtTarget: Double?

    private var goodFrameCount = 0
    private var firstGoodTime = 0.0
    private var lastGoodTime = 0.0

    /// Verdicts des `rhythmWindowSeconds` dernières secondes, de tous les réglages d'exposition. Les images
    /// périmées, que le détecteur ne juge pas, n'y figurent pas.
    private var rhythmHistory: [RhythmSample] = []

    /// Écart relatif des produits d'exposition en dessous duquel une image compte comme prise avec `target`.
    private static let exposureMatchTolerance = 0.05
    /// Écart relatif de produit en dessous duquel une exposition corrigée est la même que l'actuelle.
    private static let productEpsilon = 1e-6
    /// Facteur de réduction du produit quand la scène est surexposée.
    private static let overexposureDivisor = 4.0

    public init(
        limits: ExposureLimits,
        initial: Exposure,
        config: ExposureMeterConfig = .init(),
        detector: FlashDetectorConfig = .init()
    ) {
        precondition(limits.minDuration > 0 && limits.minDuration <= limits.maxDuration, "bornes de durée invalides")
        precondition(limits.minISO > 0 && limits.minISO <= limits.maxISO, "bornes d'ISO invalides")
        precondition(initial.product > 0, "l'exposition initiale doit être positive")
        precondition(config.framesPerStep > 0 && config.requiredStableSteps > 0, "une étape a besoin d'images et d'étapes")
        precondition(config.timeoutSeconds > 0, "le délai d'expiration doit être positif")

        self.limits = limits
        self.config = config
        self.burntFractionMax = detector.saturatedFractionMax
        self.maxFlashRunSeconds = detector.maxFlashRunSeconds
        self.detector = OnlineFlashDetector(config: detector)
        // Le même produit, réparti comme les expositions corrigées (durée d'abord) et borné aux limites :
        // les images déjà prises avec `initial` restent à moins de 5 % de la cible.
        self.target = Self.exposure(forProduct: initial.product, limits: limits)
        self.state = .measuring(progress: 0, secondsRemaining: max(1, Int(config.timeoutSeconds.rounded(.up))))
    }

    /// Reçoit une image.
    ///
    /// - Parameters:
    ///   - stats: statistiques de luma de l'image.
    ///   - time: horodatage de la prise de vue, en secondes, croissant.
    ///   - appliedExposure: l'exposition avec laquelle l'image a réellement été prise.
    /// - Returns: le nouvel état, aussi disponible dans `state`.
    @discardableResult
    public mutating func ingest(_ stats: FrameStats, at time: Double, appliedExposure: Exposure) -> MeasurementState {
        guard case .measuring = state else { return state }

        let start = startTime ?? time
        startTime = start

        // Une image périmée n'atteint pas non plus le détecteur : sa fenêtre doit se former à l'exposition cible.
        if matchesTarget(appliedExposure) {
            record(stats, at: time)
        }

        if case .measuring = state {
            let elapsed = time - start
            state = elapsed >= config.timeoutSeconds ? stateAtTimeout() : countdown(elapsed: elapsed)
        }
        return state
    }

    // MARK: - Rythme et exposition maximale

    /// Le rythme du stroboscope vu pendant la mesure : durée des moments sans lumière, part des images avec
    /// lumière. Tiré des verdicts du détecteur sur les `rhythmWindowSeconds` dernières secondes, quelle que
    /// fût la cible quand les images ont été prises. Valable dans tous les états, même une fois la mesure
    /// terminée (l'historique ne bouge plus alors).
    public var rhythm: StrobeRhythm {
        StrobeRhythmEstimator.estimate(
            times: rhythmHistory.map(\.time),
            verdicts: rhythmHistory.map(\.verdict),
            maxFlashRunSeconds: maxFlashRunSeconds
        )
    }

    /// Vrai si la cible est à l'exposition maximale (au millionième près) et que la dernière étape mesurée à
    /// cette exposition a une luma médiane sous `targetLuma − tolerance` : la scène est trop sombre pour la
    /// cadence actuelle, l'exposition ne peut plus l'éclaircir. Faux tant qu'aucune étape n'a été mesurée à la
    /// cible courante. Valable dans tous les états (`measuring`, `ready`, `failed`).
    public var reachedMaximum: Bool {
        guard isAtMaximum, let medianAtTarget else { return false }
        return medianAtTarget < config.targetLuma - config.tolerance
    }

    private var isAtMaximum: Bool {
        target.product >= limits.maxProduct * (1 - Self.productEpsilon)
    }

    // MARK: - Mesure

    private func matchesTarget(_ applied: Exposure) -> Bool {
        abs(applied.product - target.product) <= Self.exposureMatchTolerance * target.product
    }

    private mutating func record(_ stats: FrameStats, at time: Double) {
        // Toute image à l'exposition cible passe par le détecteur, pour que sa fenêtre reste continue.
        // Avec lumière, brûlée ou non : écartée, sans rien dire d'une surexposition.
        let verdict = detector.classify(stats, at: time)
        noteForRhythm(verdict, at: time)
        guard verdict == .good else { return }
        if stats.saturatedFraction > burntFractionMax {
            noteBurntFrame()
            return
        }
        burntRun = 0

        if goodFrameCount == 0 { firstGoodTime = time }
        lastGoodTime = time
        goodFrameCount += 1

        stepLumas.append(stats.meanLuma)
        if stepLumas.count >= config.framesPerStep {
            finishStep()
        }
    }

    /// Ajoute un verdict à l'historique du rythme et oublie ce qui a plus de `rhythmWindowSeconds`.
    private mutating func noteForRhythm(_ verdict: FrameVerdict, at time: Double) {
        rhythmHistory.append(RhythmSample(time: time, verdict: verdict))
        let oldest = time - config.rhythmWindowSeconds
        let expired = rhythmHistory.prefix { $0.time < oldest }.count
        rhythmHistory.removeFirst(expired)
    }

    /// Une série d'images brûlées sans lumière du strobe, aussi longue qu'une étape, veut dire que la scène
    /// elle-même est surexposée, et la luma écrêtée ne dit pas de combien. On baisse l'exposition d'un coup.
    /// Les lumas écrêtées vues par le détecteur ne se ramènent pas à la nouvelle exposition : il repart de zéro.
    private mutating func noteBurntFrame() {
        burntRun += 1
        guard burntRun >= config.framesPerStep else { return }

        burntRun = 0
        if retarget(to: exposure(forProduct: target.product / Self.overexposureDivisor)) {
            detector.reset()
        }
    }

    private mutating func finishStep() {
        let median = Self.median(of: stepLumas)
        stepLumas.removeAll(keepingCapacity: true)
        medianAtTarget = median
        hasCompletedStep = true

        if abs(median - config.targetLuma) > config.tolerance {
            let wantedProduct = target.product * pow(config.targetLuma / max(median, 0.01), config.gamma)
            if retarget(to: exposure(forProduct: wantedProduct)) { return }
            // La cible est déjà à la borne qui convient : on ne peut pas faire mieux, l'étape compte donc
            // comme stable à cette borne.
        }

        stableSteps += 1
        if stableSteps >= config.requiredStableSteps {
            state = finalState(latestMedian: median)
        }
    }

    /// Change l'exposition cible, sauf si elle ne bouge pas (déjà à une borne) ; dit si elle a changé.
    /// Tout ce qui a été mesuré à l'ancienne exposition est périmé, sauf l'historique du détecteur, ramené à la
    /// nouvelle exposition.
    @discardableResult
    private mutating func retarget(to corrected: Exposure) -> Bool {
        guard abs(corrected.product - target.product) > Self.productEpsilon * target.product else { return false }

        // La nouvelle exposition fait faire un saut volontaire à la luma, que le détecteur prendrait pour de la
        // lumière ; ramenées au nouveau niveau, les images déjà vues gardent aussi les deux niveaux d'un strobe.
        detector.rescale(by: pow(corrected.product / target.product, 1 / config.gamma))
        target = corrected
        stepLumas.removeAll(keepingCapacity: true)
        stableSteps = 0
        burntRun = 0
        medianAtTarget = nil
        return true
    }

    /// Répartit un produit entre durée et ISO : la durée grandit d'abord, jusqu'à `maxDuration`, puis les ISO.
    /// À la baisse, c'est l'inverse : les ISO descendent d'abord jusqu'à `minISO`, puis la durée.
    private func exposure(forProduct product: Double) -> Exposure {
        Self.exposure(forProduct: product, limits: limits)
    }

    private static func exposure(forProduct product: Double, limits: ExposureLimits) -> Exposure {
        let product = min(max(product, limits.minProduct), limits.maxProduct)
        let duration = min(max(product / limits.minISO, limits.minDuration), limits.maxDuration)
        let iso = min(max(product / duration, limits.minISO), limits.maxISO)
        return Exposure(durationSeconds: duration, iso: iso)
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: - Compte à rebours et expiration

    /// Temps restant d'après la cadence observée des bonnes images, borné par le temps restant avant l'expiration.
    /// Les estimations sont lissées : le compte à rebours ne remonte jamais et la progression ne recule jamais.
    private func countdown(elapsed: Double) -> MeasurementState {
        var remaining = config.timeoutSeconds - elapsed
        if goodFrameCount >= 2, lastGoodTime > firstGoodTime {
            let goodFramesPerSecond = Double(goodFrameCount - 1) / (lastGoodTime - firstGoodTime)
            // Tant qu'aucune étape n'est terminée, l'exposition de départ n'a pas été vérifiée : si elle est
            // mauvaise (le cas courant), il faudra une étape de plus pour la mesurer avant les étapes stables.
            let stepsLeft = config.requiredStableSteps - stableSteps + (hasCompletedStep ? 0 : 1)
            let framesLeft = stepsLeft * config.framesPerStep - stepLumas.count
            remaining = min(remaining, Double(framesLeft) / goodFramesPerSecond)
        }

        var progress = elapsed / (elapsed + remaining)
        var seconds = max(1, Int(remaining.rounded(.up)))
        if case let .measuring(previousProgress, previousSeconds) = state {
            progress = max(progress, previousProgress)
            seconds = min(seconds, previousSeconds)
        }
        return .measuring(progress: progress, secondsRemaining: seconds)
    }

    private func stateAtTimeout() -> MeasurementState {
        guard goodFrameCount >= config.framesPerStep else {
            return .failed(.notEnoughGoodFrames, best: target)
        }
        return finalState(latestMedian: medianAtTarget ?? (stepLumas.isEmpty ? nil : Self.median(of: stepLumas)))
    }

    /// Le verdict quand on ne cherche plus : trop sombre si la luma, mesurée à la cible, est sous `tooDarkLuma`
    /// alors que la cible est déjà à l'exposition maximale ; sinon la cible est la meilleure exposition possible.
    private func finalState(latestMedian: Double?) -> MeasurementState {
        if isAtMaximum, let latestMedian, latestMedian < config.tooDarkLuma {
            return .failed(.tooDark, best: target)
        }
        return .ready(target)
    }
}
