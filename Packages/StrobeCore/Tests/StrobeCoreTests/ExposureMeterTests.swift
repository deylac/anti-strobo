import Foundation
import Testing
@testable import StrobeCore

// MARK: - Caméra simulée

/// Bornes d'exposition d'un iPhone : de 1/8000 s à une image à 120 i/s, ISO 50 à 6400.
private let testLimits = ExposureLimits(minDuration: 1.0 / 8000, maxDuration: 1.0 / 120, minISO: 50, maxISO: 6400)

/// Produit d'exposition (durée × ISO) qui rend la scène normale à la luma cible.
private let correctProduct = 2.0
/// L'exposition vers laquelle le mesureur doit converger sur la scène normale : la durée d'abord, le reste en ISO.
private let correctExposure = Exposure(durationSeconds: 1.0 / 120, iso: 240)
/// Point de départ 4 fois trop sombre pour la scène normale.
private let fourTimesTooDark = Exposure(durationSeconds: 1.0 / 120, iso: 60)
/// Point de départ 16 fois trop clair pour la scène normale : toute l'image est brûlée.
private let sixteenTimesTooBright = Exposure(durationSeconds: 1.0 / 120, iso: 3840)

/// Une scène de luminosité constante vue par un capteur à courbe gamma :
/// `luma = borne((scène × produit)^(1 / gamma), 0, 1)`.
private struct SimulatedCamera {
    var scene: Double
    var gamma = 2.2

    /// La scène pour laquelle `product` donne exactement `luma`.
    init(luma: Double, atProduct product: Double, gamma: Double = 2.2) {
        self.scene = pow(luma, gamma) / product
        self.gamma = gamma
    }

    /// La scène normale : `correctProduct` rend la luma cible de 0,42.
    static func normal(gamma: Double = 2.2) -> SimulatedCamera {
        SimulatedCamera(luma: 0.42, atProduct: correctProduct, gamma: gamma)
    }

    func luma(_ exposure: Exposure) -> Double {
        min(1, max(0, pow(scene * exposure.product, 1 / gamma)))
    }

    /// La scène est uniforme : dès que sa luma atteint le seuil de saturation, tous les pixels sont brûlés.
    func stats(_ exposure: Exposure) -> FrameStats {
        let luma = luma(exposure)
        return FrameStats(meanLuma: luma, saturatedFraction: luma >= LumaSampler.saturationThreshold ? 1 : 0)
    }
}

/// Une image brûlée par un éclair de stroboscope.
private let flashFrame = FrameStats(meanLuma: 1, saturatedFraction: 1)
/// Un éclair qui reste sous la limite de saturation des images brûlées : seul son saut de luma le trahit.
private let softFlashFrame = FrameStats(meanLuma: 0.85, saturatedFraction: 0.1)
/// Lampe qui double la luma de la scène (gamma 2,2) : 0,42 -> 0,84 à la bonne exposition, sans brûler l'image,
/// et assez nette pour faire deux niveaux dès l'exposition de départ, 4 fois trop sombre (0,22 -> 0,45).
private let lampGain = pow(2.0, 2.2)

private struct Run: CustomTestStringConvertible {
    /// État publié après chaque image, dans l'ordre.
    var states: [MeasurementState] = []
    /// Cible du mesureur après chaque image, dans l'ordre.
    var targets: [Exposure] = []
    var meter: ExposureMeter
    /// Horodatage de la première image donnée au mesureur.
    var startTime = 0.0
    /// Horodatage de la dernière image donnée au mesureur.
    var endTime = 0.0
    var fps = 120.0

    /// Secondes de vidéo écoulées depuis la première image.
    var elapsed: Double { endTime - startTime }
    /// Horodatage de l'image qui a publié `states[index]`.
    func time(ofState index: Int) -> Double { startTime + Double(index) / fps }

    var final: MeasurementState { meter.state }
    /// Garde les messages d'échec courts : les détails internes du mesureur n'ont rien à y faire.
    var testDescription: String { "Run(\(final) après \(elapsed) s)" }
    var readyExposure: Exposure? {
        if case let .ready(exposure) = final { return exposure }
        return nil
    }
}

/// Garde les messages d'échec courts : l'historique et le détecteur du mesureur n'ont rien à y faire.
extension ExposureMeter: CustomTestStringConvertible {
    public var testDescription: String { "ExposureMeter(cible \(target), \(state))" }
}

/// Donne au mesureur les images de `camera` jusqu'à ce qu'il ait fini ou que `maxSeconds` de vidéo soient passées.
///
/// - Parameters:
///   - startTime: horodatage de la première image (les suivantes sont espacées de `1 / fps`).
///   - flashEvery: une image sur n (à partir de `flashOffset`) est `flash` au lieu de la scène.
///   - lamp: lampe qui clignote dans la scène : `dark` images éteinte puis `lit` images allumée, en boucle depuis
///     la première image. Allumée, elle rend la scène `lampGain` fois plus lumineuse, ou donne `litLampFrame`.
///   - applyLatencyFrames: images que la caméra met à appliquer une nouvelle `meter.target`
///     (0 = dès l'image suivante).
private func simulate(
    camera: SimulatedCamera = .normal(),
    initial: Exposure = fourTimesTooDark,
    limits: ExposureLimits = testLimits,
    config: ExposureMeterConfig = .init(),
    fps: Double = 120,
    startTime: Double = 0,
    flashEvery: Int? = nil,
    flashOffset: Int = 0,
    flash: FrameStats = flashFrame,
    lamp: (dark: Int, lit: Int)? = nil,
    litLampFrame: FrameStats? = nil,
    applyLatencyFrames: Int = 0,
    maxSeconds: Double = 12
) -> Run {
    var run = Run(meter: ExposureMeter(limits: limits, initial: initial, config: config), startTime: startTime, fps: fps)
    // targets[k] est la cible telle qu'elle était avant la prise de l'image k.
    var targets = [initial]
    var litCamera = camera
    litCamera.scene *= lampGain

    for index in 0..<Int(maxSeconds * fps) {
        let time = startTime + Double(index) / fps
        let applied = targets[max(0, index - applyLatencyFrames)]
        let isFlash = flashEvery.map { index % $0 == flashOffset } ?? false
        let isLampLit = lamp.map { index % ($0.dark + $0.lit) >= $0.dark } ?? false
        let lampStats = isLampLit ? litLampFrame ?? litCamera.stats(applied) : nil
        let stats = isFlash ? flash : lampStats ?? camera.stats(applied)

        let state = run.meter.ingest(stats, at: time, appliedExposure: applied)
        run.states.append(state)
        run.endTime = time
        run.targets.append(run.meter.target)
        targets.append(run.meter.target)

        if case .measuring = state { continue }
        break
    }
    return run
}

private func secondsRemaining(in states: [MeasurementState]) -> [Int] {
    states.compactMap {
        if case let .measuring(_, seconds) = $0 { return seconds }
        return nil
    }
}

private func progress(in states: [MeasurementState]) -> [Double] {
    states.compactMap {
        if case let .measuring(progress, _) = $0 { return progress }
        return nil
    }
}

/// Donne `count` images brûlées prises avec l'exposition courante du mesureur.
private func feedBurntFrames(_ count: Int, to meter: inout ExposureMeter, from index: inout Int) {
    for _ in 0..<count {
        meter.ingest(flashFrame, at: Double(index) / 120, appliedExposure: meter.target)
        index += 1
    }
}

// MARK: - Tests

@Suite("ExposureMeter")
struct ExposureMeterTests {
    @Test func convergesWithoutStrobe() throws {
        let camera = SimulatedCamera.normal()
        let run = simulate(camera: camera)

        let exposure = try #require(run.readyExposure)
        #expect(run.endTime < 2.0)
        #expect(abs(camera.luma(exposure) - 0.42) <= 0.06)
    }

    @Test func convergesWhateverTheClockStartsAt() throws {
        // Les horodatages d'une caméra ne partent pas de zéro : le délai d'expiration court depuis la
        // première image reçue, pas depuis l'horodatage 0.
        let camera = SimulatedCamera.normal()
        let run = simulate(camera: camera, startTime: 5000)

        let exposure = try #require(run.readyExposure)
        #expect(run.elapsed < 2.0)
        #expect(abs(camera.luma(exposure) - 0.42) <= 0.06)
    }

    @Test func ignoresFlashesWhenConverging() throws {
        let camera = SimulatedCamera.normal()
        let calm = try #require(simulate(camera: camera).readyExposure)
        let strobed = try #require(simulate(camera: camera, flashEvery: 8).readyExposure)

        let ratio = strobed.product / calm.product
        #expect(ratio >= 0.9 && ratio <= 1.1, "le produit avec stroboscope vaut \(ratio) fois celui sans")
        #expect(abs(camera.luma(strobed) - 0.42) <= 0.06)
    }

    @Test func detectorFiltersFlashesThatAreNotSaturated() throws {
        // Deux images par étape : une seule image claire entraînerait la médiane de l'étape (la moyenne de
        // deux valeurs) très loin, donc seul le détecteur de lumière peut écarter ces images. La première
        // correction d'exposition arrive à l'image 1 ; le détecteur garde les images 0 et 1, ramenées à la
        // nouvelle exposition, et juge dès sa 6e image : l'éclair de l'image 5 est écarté. S'il oubliait tout à
        // chaque correction, il n'aurait que 4 images et l'éclair entrerait dans la mesure.
        var config = ExposureMeterConfig()
        config.framesPerStep = 2
        let camera = SimulatedCamera.normal()

        let run = simulate(camera: camera, config: config, flashEvery: 6, flashOffset: 5, flash: softFlashFrame)

        let exposure = try #require(run.readyExposure)
        let ratio = exposure.product / correctProduct
        #expect(ratio >= 0.9 && ratio <= 1.1, "convergé vers \(ratio) fois le bon produit")
        #expect(run.endTime < 1, "a pris \(run.endTime) s")
    }

    @Test(arguments: [24, 30])
    func burntLampPhasesDoNotLowerExposure(phaseFrames: Int) throws {
        // Lampe dont les images allumées sont brûlées (ce que veut la V2), allumée 0,2 ou 0,25 s : autant ou plus
        // d'images brûlées d'affilée qu'une étape. Le détecteur y voit de la lumière à côté des images éteintes,
        // pas une scène brûlée : elles sont écartées, sans diviser l'exposition par 4.
        let camera = SimulatedCamera.normal()
        let run = simulate(camera: camera, lamp: (dark: phaseFrames, lit: phaseFrames), litLampFrame: flashFrame)

        let exposure = try #require(run.readyExposure)
        let ratio = exposure.product / correctProduct
        #expect(ratio >= 0.9 && ratio <= 1.1, "convergé vers \(ratio) fois le bon produit")
        for (previous, next) in zip([fourTimesTooDark] + run.targets, run.targets) {
            #expect(next.product > previous.product / 4 * 1.01, "exposition divisée par 4 : \(previous) -> \(next)")
        }
    }

    @Test func longLampPhasesDoNotLowerExposure() throws {
        // Lampe allumée 0,25 s puis éteinte 0,25 s : ses 30 images allumées d'affilée (plus qu'une étape) sont de
        // la lumière, pas une surexposition. Elles ne sont pas brûlées : écartées, sans diviser l'exposition par 4.
        let camera = SimulatedCamera.normal()
        let run = simulate(camera: camera, lamp: (dark: 30, lit: 30))

        let exposure = try #require(run.readyExposure)
        let ratio = exposure.product / correctProduct
        #expect(ratio >= 0.9 && ratio <= 1.1, "convergé vers \(ratio) fois le bon produit")
        for (previous, next) in zip([fourTimesTooDark] + run.targets, run.targets) {
            #expect(next.product > previous.product / 4 * 1.01, "exposition divisée par 4 : \(previous) -> \(next)")
        }
    }

    @Test func correctionKeepsTheLampLevels() throws {
        // Étapes de 30 images : la première se termine sur la dernière image éteinte de la lampe (image 29), juste
        // avant 30 images allumées. Le détecteur garde les images éteintes, ramenées à la nouvelle exposition :
        // la phase allumée qui suit est écartée et l'étape suivante se mesure sur les images éteintes.
        var config = ExposureMeterConfig()
        config.framesPerStep = 30
        let camera = SimulatedCamera.normal()
        let run = simulate(camera: camera, config: config, lamp: (dark: 30, lit: 30))

        let exposure = try #require(run.readyExposure)
        #expect(abs(exposure.product / correctProduct - 1) <= 0.1)
        // Après la première correction, la cible ne quitte plus le bon produit.
        for target in run.targets.dropFirst(30) {
            #expect(abs(target.product / correctProduct - 1) <= 0.1, "cible \(target)")
        }
    }

    @Test func countdownDecreases() {
        // Cadences rapides et lentes, avec et sans stroboscope, et un capteur dont le vrai gamma n'est pas celui
        // que suppose le mesureur (plusieurs étapes de correction, le compte des étapes stables repart à zéro).
        let scenarios: [(String, Run)] = [
            ("120 i/s", simulate()),
            ("120 i/s, stroboscope", simulate(flashEvery: 8)),
            ("30 i/s, stroboscope", simulate(fps: 30, flashEvery: 8)),
            ("60 i/s, gamma 1,6", simulate(camera: .normal(gamma: 1.6), fps: 60)),
            ("30 i/s, gamma 1,6, stroboscope", simulate(camera: .normal(gamma: 1.6), fps: 30, flashEvery: 8)),
            // Assez lent pour qu'une étape ratée fasse remonter l'estimation brute de plus d'une seconde.
            ("10 i/s, gamma 1,6", simulate(camera: .normal(gamma: 1.6), fps: 10)),
        ]

        for (name, run) in scenarios {
            #expect(run.readyExposure != nil, "\(name) : pas fini en `ready`, obtenu \(run.final)")

            let seconds = secondsRemaining(in: run.states)
            #expect(!seconds.isEmpty, "\(name) : aucun état `measuring` publié")
            #expect(seconds.allSatisfy { $0 >= 1 }, "\(name) : le compte à rebours est passé sous 1 : \(seconds)")
            for (previous, next) in zip(seconds, seconds.dropFirst()) {
                #expect(next <= previous, "\(name) : le compte à rebours est remonté de \(previous) à \(next)")
            }

            let fractions = progress(in: run.states)
            #expect(fractions.allSatisfy { $0 >= 0 && $0 < 1 }, "\(name) : progression hors de 0..<1")
            for (previous, next) in zip(fractions, fractions.dropFirst()) {
                #expect(next >= previous, "\(name) : la progression a reculé de \(previous) à \(next)")
            }
        }
    }

    @Test func tooDarkReported() {
        // À pleine exposition, la scène ne rend encore que 0,08 de luma : sous tooDarkLuma (0,12).
        let maxProduct = testLimits.maxDuration * testLimits.maxISO
        let camera = SimulatedCamera(luma: 0.08, atProduct: maxProduct)
        let run = simulate(camera: camera, initial: correctExposure)

        guard case let .failed(failure, best) = run.final else {
            Issue.record("échec attendu, obtenu \(run.final)")
            return
        }
        #expect(failure == .tooDark)
        #expect(best.durationSeconds == testLimits.maxDuration)
        #expect(abs(best.iso - testLimits.maxISO) < 1e-6)
        // Le maximum est atteint à la première correction : deux étapes de plus suffisent, inutile d'attendre.
        #expect(run.elapsed < 2, "verdict après \(run.elapsed) s")
    }

    @Test func dimAtMaximumEndsReadyWithoutWaiting() {
        // Même au maximum la scène ne rend que 0,25 : trop sombre pour la cible, mais pas « trop sombre ».
        let maxProduct = testLimits.maxDuration * testLimits.maxISO
        let camera = SimulatedCamera(luma: 0.25, atProduct: maxProduct)
        let run = simulate(camera: camera, initial: correctExposure)

        guard case let .ready(exposure) = run.final else {
            Issue.record("`ready` attendu, obtenu \(run.final)")
            return
        }
        #expect(abs(exposure.product - maxProduct) / maxProduct < 1e-6)
        #expect(run.elapsed < 2, "verdict après \(run.elapsed) s")
    }

    @Test func countdownStaysTruthfulAtALimit() {
        // Arrivé à une borne, le verdict tombe après deux étapes stables : le compte à rebours ne doit ni
        // s'arrêter sur « 1 s » pendant des secondes, ni annoncer un verdict bien plus tôt qu'il ne vient.
        let maxProduct = testLimits.maxDuration * testLimits.maxISO
        let minProduct = testLimits.minDuration * testLimits.minISO
        let tooDark = SimulatedCamera(luma: 0.08, atProduct: maxProduct)
        let tooBright = SimulatedCamera(luma: 0.6, atProduct: minProduct)
        let twiceTheMinimum = Exposure(durationSeconds: testLimits.minDuration * 2, iso: testLimits.minISO)
        let scenarios: [(String, Run)] = [
            ("trop sombre, 30 i/s", simulate(camera: tooDark, initial: correctExposure, fps: 30)),
            ("trop sombre, 10 i/s", simulate(camera: tooDark, initial: correctExposure, fps: 10)),
            ("trop clair, 30 i/s", simulate(camera: tooBright, initial: twiceTheMinimum, fps: 30)),
            ("trop clair, 10 i/s", simulate(camera: tooBright, initial: twiceTheMinimum, fps: 10)),
        ]

        for (name, run) in scenarios {
            if case .measuring = run.final {
                Issue.record("\(name) : pas de verdict, obtenu \(run.final)")
                continue
            }
            // 72 images : la correction vers la borne, puis deux étapes stables.
            #expect(abs(run.elapsed - 71 / run.fps) < 1e-9, "\(name) : verdict après \(run.elapsed) s")

            let seconds = secondsRemaining(in: run.states)
            for (index, remaining) in seconds.enumerated() {
                let wait = run.endTime - run.time(ofState: index)
                #expect(wait <= Double(remaining) + 1, "\(name) : « \(remaining) s » alors qu'il reste \(wait) s")
            }
            let firstOne = seconds.firstIndex(of: 1) ?? seconds.count
            let plateau = run.endTime - run.time(ofState: firstOne)
            #expect(plateau <= 1 + 1 / run.fps + 1e-9, "\(name) : « 1 s » affiché pendant \(plateau) s")
        }
    }

    @Test func darkWithoutReachingMaximumIsNotTooDark() {
        // Un capteur bien plus raide que le gamma supposé : la première correction tombe bien en dessous de
        // l'exposition maximale et la scène y lit encore 0,11 quand le temps est écoulé. Sombre, mais pas
        // « trop sombre » : le verdict exige d'avoir essayé l'exposition maximale.
        let camera = SimulatedCamera(luma: 0.05, atProduct: 0.1, gamma: 6)
        var config = ExposureMeterConfig()
        config.timeoutSeconds = 0.3
        let run = simulate(camera: camera, initial: Exposure(durationSeconds: 1.0 / 120, iso: 12), config: config)

        guard case let .ready(exposure) = run.final else {
            Issue.record("`ready` attendu à l'expiration, obtenu \(run.final)")
            return
        }
        #expect(exposure.product < testLimits.maxDuration * testLimits.maxISO / 2)
        #expect(camera.luma(exposure) < 0.12)
    }

    @Test func tooDarkVerdictNeedsALumaMeasuredAtMaximum() {
        // La première étape lit 0,05, ce qui envoie l'exposition à son maximum, où la scène est un bon 0,3.
        // Le temps s'écoule deux images après le début de l'étape suivante : le 0,05 a été mesuré à une autre
        // exposition et ne dit rien de l'exposition maximale.
        let maxProduct = testLimits.maxDuration * testLimits.maxISO
        let camera = SimulatedCamera(luma: 0.3, atProduct: maxProduct)
        let dimProduct = maxProduct * pow(0.05 / 0.3, 2.2)
        let initial = Exposure(durationSeconds: testLimits.maxDuration, iso: dimProduct / testLimits.maxDuration)
        var config = ExposureMeterConfig()
        config.timeoutSeconds = 24.5 / 120

        let run = simulate(camera: camera, initial: initial, config: config)

        guard case let .ready(exposure) = run.final else {
            Issue.record("`ready` attendu à l'expiration, obtenu \(run.final)")
            return
        }
        #expect(abs(exposure.product - maxProduct) / maxProduct < 1e-6)
    }

    /// Donne uniquement des images saturées au mesureur, depuis `startTime`, jusqu'à son verdict ou 10,5 s plus tard.
    private func feedOnlyFlashes(from startTime: Double) -> (meter: ExposureMeter, state: MeasurementState, elapsed: Double) {
        var meter = ExposureMeter(limits: testLimits, initial: correctExposure)
        var state = meter.state
        var elapsed = 0.0
        while elapsed <= 10.5, case .measuring = state {
            state = meter.ingest(flashFrame, at: startTime + elapsed, appliedExposure: meter.target)
            elapsed += 1.0 / 120
        }
        return (meter, state, elapsed)
    }

    @Test func allFlashesReportsNotEnoughGoodFrames() {
        // Des images saturées en permanence : le mesureur y voit une surexposition et descend jusqu'à
        // l'exposition minimale, où il attend l'expiration sans jamais avoir une image exploitable.
        let (meter, state, elapsed) = feedOnlyFlashes(from: 0)

        guard case let .failed(failure, best) = state else {
            Issue.record("échec attendu, obtenu \(state)")
            return
        }
        #expect(failure == .notEnoughGoodFrames)
        let minProduct = testLimits.minDuration * testLimits.minISO
        #expect(abs(best.product - minProduct) / minProduct < 1e-6, "la meilleure exposition est \(best)")
        #expect(best == meter.target)
        #expect(elapsed > 10, "abandon au bout de \(elapsed) s, avant l'expiration de 10 s")
    }

    @Test func timeoutRunsFromTheFirstFrameNotFromZero() {
        // Même scénario, mais l'horloge de la caméra est à 5000 s à la première image : le délai de 10 s se
        // compte depuis cette image.
        let (_, state, elapsed) = feedOnlyFlashes(from: 5000)

        if case .failed(.notEnoughGoodFrames, _) = state {} else {
            Issue.record("échec `notEnoughGoodFrames` attendu, obtenu \(state)")
        }
        #expect(elapsed > 10, "abandon au bout de \(elapsed) s, avant l'expiration de 10 s")
        #expect(elapsed < 10.1, "abandon au bout de \(elapsed) s, bien après l'expiration de 10 s")
    }

    @Test func recoversFromOverexposedStart() throws {
        // 16 fois trop clair : toutes les images sont brûlées (saturation 1, bien au-delà de 0,25). Le mesureur
        // baisse l'exposition de lui-même, puis mesure normalement.
        let camera = SimulatedCamera.normal()
        #expect(camera.stats(sixteenTimesTooBright).saturatedFraction > 0.25)

        let run = simulate(camera: camera, initial: sixteenTimesTooBright)

        let exposure = try #require(run.readyExposure)
        #expect(run.endTime < 10, "a atteint l'expiration de 10 s au lieu de converger")
        #expect(run.endTime < 2, "a pris \(run.endTime) s")
        #expect(abs(camera.luma(exposure) - 0.42) <= 0.06)
    }

    @Test func burntRunLowersTargetByFour() {
        var meter = ExposureMeter(limits: testLimits, initial: correctExposure)
        var index = 0

        feedBurntFrames(23, to: &meter, from: &index)
        #expect(meter.target == correctExposure)

        feedBurntFrames(1, to: &meter, from: &index)
        #expect(meter.target.durationSeconds == testLimits.maxDuration)
        #expect(abs(meter.target.iso - correctExposure.iso / 4) < 1e-9)
        if case .measuring = meter.state {} else {
            Issue.record("la mesure aurait dû continuer, obtenu \(meter.state)")
        }
    }

    @Test func aUsableFrameInterruptsTheBurntRun() {
        var meter = ExposureMeter(limits: testLimits, initial: correctExposure)
        var index = 0

        feedBurntFrames(23, to: &meter, from: &index)
        meter.ingest(FrameStats(meanLuma: 0.42, saturatedFraction: 0), at: Double(index) / 120, appliedExposure: meter.target)
        index += 1
        feedBurntFrames(23, to: &meter, from: &index)

        #expect(meter.target == correctExposure)
    }

    @Test func overexposureDiscardsWhatWasMeasuredBefore() {
        // Une étape stable (24 images à 0,42) et dix images de la suivante, puis la scène s'embrase et reste
        // brûlée. Juste après les images calmes, ses premières images brûlées ressemblent à une lumière : il faut
        // que cette « lumière » dure plus de 0,3 s, puis une étape d'images brûlées, pour diviser l'exposition.
        // Ce qui a été mesuré à l'ancienne exposition est alors périmé, il faut donc repartir de zéro : deux
        // étapes stables complètes, soit 48 images exploitables, pour être prêt.
        let usable = FrameStats(meanLuma: 0.42, saturatedFraction: 0)
        var meter = ExposureMeter(limits: testLimits, initial: correctExposure)
        var index = 0
        for _ in 0..<34 {
            meter.ingest(usable, at: Double(index) / 120, appliedExposure: meter.target)
            index += 1
        }
        var burntFrames = 0
        while meter.target == correctExposure, burntFrames < 120 {
            feedBurntFrames(1, to: &meter, from: &index)
            burntFrames += 1
        }
        let lightFrames = FlashDetectorConfig().maxFlashRunSeconds * 120
        #expect(Double(burntFrames) > lightFrames, "divisée après \(burntFrames) images brûlées")
        #expect(Double(burntFrames) <= lightFrames + 1 + 24, "divisée après \(burntFrames) images brûlées")

        var framesToReady = 0
        while case .measuring = meter.state, framesToReady < 200 {
            meter.ingest(usable, at: Double(index) / 120, appliedExposure: meter.target)
            index += 1
            framesToReady += 1
        }
        #expect(framesToReady == 48)
    }

    @Test func overexposureLowersISOBeforeDuration() {
        // À la baisse, le partage inverse celui de la hausse : les ISO d'abord, jusqu'à minISO, puis la durée.
        func targetAfterBurntRun(from initial: Exposure) -> Exposure {
            var meter = ExposureMeter(limits: testLimits, initial: initial)
            var index = 0
            feedBurntFrames(24, to: &meter, from: &index)
            return meter.target
        }

        let highISO = targetAfterBurntRun(from: Exposure(durationSeconds: 1.0 / 120, iso: 6400))
        #expect(highISO.durationSeconds == testLimits.maxDuration)
        #expect(abs(highISO.iso - 1600) < 1e-9)

        let lowISO = targetAfterBurntRun(from: Exposure(durationSeconds: 1.0 / 120, iso: 100))
        #expect(abs(lowISO.iso - testLimits.minISO) < 1e-9)
        #expect(abs(lowISO.durationSeconds - 1.0 / 240) < 1e-12)
    }

    @Test func overexposureStopsAtMinimumExposure() {
        let minProduct = testLimits.minDuration * testLimits.minISO
        var meter = ExposureMeter(limits: testLimits, initial: correctExposure)
        var index = 0

        feedBurntFrames(24 * 10, to: &meter, from: &index)

        #expect(abs(meter.target.product - minProduct) / minProduct < 1e-6)
        #expect(meter.target.iso >= testLimits.minISO && meter.target.durationSeconds >= testLimits.minDuration)
    }

    @Test func initialExposureIsSplitDurationFirstAndClamped() {
        let maxProduct = testLimits.maxDuration * testLimits.maxISO

        // Une pose plus longue qu'une image : même produit, pose ramenée à `maxDuration`, le reste en ISO.
        let tooLong = Exposure(durationSeconds: 1.0 / 60, iso: 100)
        var meter = ExposureMeter(limits: testLimits, initial: tooLong)
        #expect(meter.target.durationSeconds <= testLimits.maxDuration)
        #expect(abs(meter.target.product - tooLong.product) / tooLong.product < 1e-9)

        // Les images déjà prises avec `initial` comptent donc toujours (même produit) : deux étapes stables.
        var state = meter.state
        for index in 0..<48 {
            state = meter.ingest(
                FrameStats(meanLuma: 0.42, saturatedFraction: 0),
                at: Double(index) / 120,
                appliedExposure: tooLong
            )
        }
        #expect(state == .ready(meter.target))

        // Un produit hors des bornes est ramené dans les bornes.
        let tooMuch = ExposureMeter(limits: testLimits, initial: Exposure(durationSeconds: 1.0 / 30, iso: 6400))
        #expect(abs(tooMuch.target.product - maxProduct) / maxProduct < 1e-6)
        #expect(tooMuch.target.durationSeconds <= testLimits.maxDuration && tooMuch.target.iso <= testLimits.maxISO)

        let tooLittle = ExposureMeter(limits: testLimits, initial: Exposure(durationSeconds: 1.0 / 20000, iso: 10))
        let minProduct = testLimits.minDuration * testLimits.minISO
        #expect(abs(tooLittle.target.product - minProduct) / minProduct < 1e-6)
        #expect(tooLittle.target.durationSeconds >= testLimits.minDuration && tooLittle.target.iso >= testLimits.minISO - 1e-9)
    }

    @Test func staleExposureFramesIgnored() {
        let initial = fourTimesTooDark
        let old = correctExposure // 4 fois plus loin que la cible : nettement pas l'exposition en cours de mesure
        var meter = ExposureMeter(limits: testLimits, initial: initial)

        // Des images qui ont l'air parfaites (0,42) mais viennent de l'ancien réglage : si elles comptaient,
        // la mesure se terminerait au bout de deux étapes (48 images).
        var state = meter.state
        for index in 0..<150 {
            state = meter.ingest(
                FrameStats(meanLuma: 0.42, saturatedFraction: 0),
                at: Double(index) / 120,
                appliedExposure: old
            )
        }

        guard case .measuring = state else {
            Issue.record("des images périmées ont fait avancer la mesure jusqu'à \(state)")
            return
        }
        #expect(meter.target == initial)
    }

    @Test func staleFramesAreSkippedWhileTheCameraCatchesUp() throws {
        let camera = SimulatedCamera.normal()
        let run = simulate(camera: camera, applyLatencyFrames: 5)

        let exposure = try #require(run.readyExposure)
        #expect(abs(camera.luma(exposure) - 0.42) <= 0.06)
        #expect(run.endTime < 2.0)
    }

    @Test func quantizedAppliedExposureStillCounts() {
        // Un appareil réel rapporte une valeur proche de celle demandée, pas égale.
        func finish(appliedScale: Double) -> MeasurementState {
            var meter = ExposureMeter(limits: testLimits, initial: correctExposure)
            var state = meter.state
            for index in 0..<150 {
                let applied = Exposure(durationSeconds: correctExposure.durationSeconds, iso: correctExposure.iso * appliedScale)
                state = meter.ingest(
                    FrameStats(meanLuma: 0.42, saturatedFraction: 0),
                    at: Double(index) / 120,
                    appliedExposure: applied
                )
            }
            return state
        }

        #expect(finish(appliedScale: 1.03) == .ready(correctExposure))
        #expect(finish(appliedScale: 0.96) == .ready(correctExposure))
        if case .measuring = finish(appliedScale: 1.08) {} else {
            Issue.record("une image à 8 % de la cible ne doit pas compter")
        }
    }

    @Test func exposureStepIsNotMistakenForAFlash() throws {
        // 0,223 → 0,42 après la première correction est un saut que le détecteur de lumière signalerait
        // pendant ~0,3 s. Le mesureur ramène les images déjà vues du détecteur à la nouvelle exposition :
        // aucune image n'est perdue, soit trois étapes de 24 images.
        let run = simulate()

        _ = try #require(run.readyExposure)
        #expect(run.endTime <= 71.0 / 120 + 1e-9, "a pris \(run.endTime) s au lieu de 72 images")
    }

    @Test func splitFillsDurationBeforeISO() throws {
        // Scène sombre : le bon produit est 0,2, atteint avec l'ISO minimal et une pose de 1/250 s.
        let dim = SimulatedCamera(luma: 0.42, atProduct: 0.2)
        let dimExposure = try #require(simulate(camera: dim, initial: Exposure(durationSeconds: 1.0 / 120, iso: 100)).readyExposure)
        #expect(dimExposure.iso == testLimits.minISO)
        #expect(abs(dimExposure.durationSeconds - 0.004) / 0.004 < 0.1)

        // Scène bien éclairée : un produit de 20 demande la plus longue durée permise et le reste en ISO.
        let lit = SimulatedCamera(luma: 0.42, atProduct: 20)
        let litExposure = try #require(simulate(camera: lit).readyExposure)
        #expect(litExposure.durationSeconds == testLimits.maxDuration)
        #expect(abs(litExposure.iso - 2400) / 2400 < 0.1)
    }

    @Test func tooBrightSceneEndsReadyAtMinimumExposure() throws {
        // Même l'exposition la plus courte rend 0,6 : rien de plus à faire, le mieux possible est le minimum.
        let minProduct = testLimits.minDuration * testLimits.minISO
        let camera = SimulatedCamera(luma: 0.6, atProduct: minProduct)
        let twiceTheMinimum = Exposure(durationSeconds: testLimits.minDuration * 2, iso: testLimits.minISO)
        let run = simulate(camera: camera, initial: twiceTheMinimum)

        let exposure = try #require(run.readyExposure)
        #expect(abs(exposure.product - minProduct) / minProduct < 1e-6)
        #expect(exposure.iso >= testLimits.minISO && exposure.durationSeconds >= testLimits.minDuration)
        #expect(run.elapsed < 2, "verdict après \(run.elapsed) s")
    }

    @Test func finishedMeasurementIsFinal() {
        var ready = ExposureMeter(limits: testLimits, initial: correctExposure)
        var state = ready.state
        var index = 0
        while case .measuring = state {
            state = ready.ingest(FrameStats(meanLuma: 0.42, saturatedFraction: 0), at: Double(index) / 120, appliedExposure: correctExposure)
            index += 1
        }
        #expect(state == .ready(correctExposure))

        // Quoi qu'il arrive ensuite (image sombre, éclair, image très tardive), rien ne change.
        for stats in [FrameStats(meanLuma: 0.05, saturatedFraction: 0), flashFrame] {
            let after = ready.ingest(stats, at: 100 + Double(index), appliedExposure: correctExposure)
            #expect(after == .ready(correctExposure))
            #expect(ready.state == .ready(correctExposure))
            #expect(ready.target == correctExposure)
            index += 1
        }
    }

    // MARK: - Rythme du strobe et exposition maximale (V2)

    @Test func rhythmOfAHalfDutyLamp() {
        // 5 Hz, allumée la moitié du temps : 12 images éteintes puis 12 allumées à 120 i/s, soit des moments
        // sans lumière de 0,1 s.
        let run = simulate(lamp: (dark: 12, lit: 12))

        let rhythm = run.meter.rhythm
        #expect(rhythm.hasStrobe)
        #expect(abs(rhythm.shortestDarkGap - 0.1) <= 0.01, "moment sans lumière le plus court : \(rhythm.shortestDarkGap)")
        #expect(rhythm.lightFraction > 0.35 && rhythm.lightFraction < 0.55, "part avec lumière : \(rhythm.lightFraction)")
    }

    @Test func rhythmOfRareShortFlashes() {
        // Une image avec lumière sur 12 : chaque moment sans lumière dure 11 images, soit 11/120 s.
        let run = simulate(flashEvery: 12)

        let rhythm = run.meter.rhythm
        #expect(rhythm.hasStrobe)
        #expect(abs(rhythm.shortestDarkGap - 11.0 / 120) <= 0.01, "moment sans lumière le plus court : \(rhythm.shortestDarkGap)")
    }

    @Test func rhythmWithoutStrobe() {
        let run = simulate()

        #expect(run.meter.rhythm == StrobeRhythm(hasStrobe: false, shortestDarkGap: .infinity, lightFraction: 0))
    }

    @Test func rhythmIsKnownFromTheStartOfTheMeasurement() {
        // Rien reçu : pas de rythme.
        let meter = ExposureMeter(limits: testLimits, initial: correctExposure)
        #expect(meter.rhythm == StrobeRhythm(hasStrobe: false, shortestDarkGap: .infinity, lightFraction: 0))
    }

    @Test func rhythmSurvivesTheFirstExposureCorrection() {
        // Étapes de 48 images : la première correction (de l'exposition de départ, 4 fois trop sombre) tombe sur
        // la 84e image, à la fin du 4e moment sans lumière. Deux moments sans lumière encadrés ont alors été
        // vus, tous deux avant la correction : le rythme ne doit pas être oublié avec l'ancienne exposition.
        var config = ExposureMeterConfig()
        config.framesPerStep = 48
        let run = simulate(config: config, lamp: (dark: 12, lit: 12), maxSeconds: 84.5 / 120)

        #expect(run.targets.count == 84)
        let before = run.targets[run.targets.count - 2]
        let after = run.targets[run.targets.count - 1]
        #expect(after.product > before.product * 2, "la correction devait tomber sur la dernière image : \(before) -> \(after)")

        let rhythm = run.meter.rhythm
        #expect(rhythm.hasStrobe)
        #expect(abs(rhythm.shortestDarkGap - 0.1) <= 0.01, "moment sans lumière le plus court : \(rhythm.shortestDarkGap)")
    }

    @Test func rhythmIsKnownWhileStaleFramesAreSkipped() {
        // Les images périmées n'ont pas de verdict : elles manquent à l'historique, ce qui ne fait qu'écourter
        // un moment sans lumière au plus (jamais le rallonger).
        let run = simulate(lamp: (dark: 12, lit: 12), applyLatencyFrames: 5)

        let rhythm = run.meter.rhythm
        #expect(rhythm.hasStrobe)
        #expect(rhythm.shortestDarkGap <= 0.1 + 0.01, "moment sans lumière le plus court : \(rhythm.shortestDarkGap)")
        #expect(rhythm.shortestDarkGap >= 0.1 - 5.0 / 120 - 0.01, "moment sans lumière le plus court : \(rhythm.shortestDarkGap)")
    }

    @Test func rhythmOnlyRemembersTheLastTenSeconds() {
        // Mesure qui ne finit pas : 3 s de lampe à 5 Hz, puis une scène calme. Dix secondes après la fin de la
        // lampe, il reste de ses images dans l'historique ; au-delà, plus aucune.
        var config = ExposureMeterConfig()
        config.requiredStableSteps = 1_000_000
        config.timeoutSeconds = 1000
        var meter = ExposureMeter(limits: testLimits, initial: correctExposure, config: config)
        let camera = SimulatedCamera.normal()
        var litCamera = camera
        litCamera.scene *= lampGain

        func feed(seconds range: Range<Double>, lampOn: Bool) {
            for index in Int(range.lowerBound * 120)..<Int(range.upperBound * 120) {
                let isLit = lampOn && index % 24 >= 12
                let stats = (isLit ? litCamera : camera).stats(meter.target)
                meter.ingest(stats, at: Double(index) / 120, appliedExposure: meter.target)
            }
        }

        feed(seconds: 0..<3, lampOn: true)
        #expect(meter.rhythm.hasStrobe)

        feed(seconds: 3..<12, lampOn: false)
        #expect(meter.rhythm.hasStrobe, "la lampe a fini il y a 9 s : encore dans l'historique de 10 s")

        feed(seconds: 12..<14, lampOn: false)
        #expect(meter.rhythm == StrobeRhythm(hasStrobe: false, shortestDarkGap: .infinity, lightFraction: 0))
        if case .measuring = meter.state {} else {
            Issue.record("la mesure devait durer tout le test, obtenu \(meter.state)")
        }
    }

    @Test func reachedMaximumWhenTooDark() {
        let maxProduct = testLimits.maxDuration * testLimits.maxISO
        let run = simulate(camera: SimulatedCamera(luma: 0.08, atProduct: maxProduct), initial: correctExposure)

        #expect(run.final == .failed(.tooDark, best: run.meter.target))
        #expect(run.meter.reachedMaximum)
    }

    @Test func reachedMaximumWhenDimAtMaximum() {
        // Même au maximum la scène ne rend que 0,25, sous 0,42 − 0,06 : l'exposition est `ready`, mais au maximum.
        let maxProduct = testLimits.maxDuration * testLimits.maxISO
        let run = simulate(camera: SimulatedCamera(luma: 0.25, atProduct: maxProduct), initial: correctExposure)

        #expect(run.readyExposure != nil)
        #expect(run.meter.reachedMaximum)
    }

    @Test func notReachedMaximumWhenConverged() {
        let converged = simulate()
        #expect(converged.readyExposure != nil)
        #expect(!converged.meter.reachedMaximum)

        // Même au produit minimum, une scène trop claire n'est pas une scène trop sombre.
        let minProduct = testLimits.minDuration * testLimits.minISO
        let tooBright = simulate(
            camera: SimulatedCamera(luma: 0.6, atProduct: minProduct),
            initial: Exposure(durationSeconds: testLimits.minDuration * 2, iso: testLimits.minISO)
        )
        #expect(tooBright.readyExposure != nil)
        #expect(!tooBright.meter.reachedMaximum)
    }

    @Test func reachedMaximumNeedsALumaBelowTheTolerance() {
        let maxProduct = testLimits.maxDuration * testLimits.maxISO
        // 0,37 est dans la tolérance (0,42 ± 0,06) : la cible est au maximum, mais la scène y est bien exposée.
        let withinTolerance = simulate(camera: SimulatedCamera(luma: 0.37, atProduct: maxProduct), initial: correctExposure)
        #expect(withinTolerance.readyExposure != nil)
        #expect(!withinTolerance.meter.reachedMaximum)

        let belowTolerance = simulate(camera: SimulatedCamera(luma: 0.35, atProduct: maxProduct), initial: correctExposure)
        #expect(belowTolerance.readyExposure != nil)
        #expect(belowTolerance.meter.reachedMaximum)
    }

    @Test func reachedMaximumIsKnownWhileMeasuring() {
        // Scène à 0,08 au maximum. La 1re étape (24 images) envoie la cible au maximum ; la 2e est la première
        // mesurée au maximum, et dit déjà que la scène y est trop sombre, deux étapes avant le verdict.
        let maxProduct = testLimits.maxDuration * testLimits.maxISO
        let camera = SimulatedCamera(luma: 0.08, atProduct: maxProduct)
        var meter = ExposureMeter(limits: testLimits, initial: correctExposure)
        #expect(!meter.reachedMaximum)

        var firstTrue: Int?
        for index in 0..<72 {
            let state = meter.ingest(camera.stats(meter.target), at: Double(index) / 120, appliedExposure: meter.target)
            if firstTrue == nil, meter.reachedMaximum { firstTrue = index }
            if index == 47 {
                if case .measuring = state {} else { Issue.record("encore en mesure à l'image 47, obtenu \(state)") }
            }
        }
        #expect(firstTrue == 47, "premier `reachedMaximum` à l'image \(String(describing: firstTrue))")
        #expect(meter.state == .failed(.tooDark, best: meter.target))
        #expect(meter.reachedMaximum, "valable aussi une fois la mesure terminée")
    }

    @Test func reachedMaximumIsFalseUntilAStepWasMeasuredAtMaximum() {
        // Démarrer au maximum ne dit rien de la scène : aucune étape n'a encore été mesurée.
        let maxExposure = Exposure(durationSeconds: testLimits.maxDuration, iso: testLimits.maxISO)
        var meter = ExposureMeter(limits: testLimits, initial: maxExposure)
        #expect(abs(meter.target.product - maxExposure.product) / maxExposure.product < 1e-9)
        #expect(!meter.reachedMaximum)

        let dim = FrameStats(meanLuma: 0.2, saturatedFraction: 0)
        for index in 0..<23 {
            meter.ingest(dim, at: Double(index) / 120, appliedExposure: meter.target)
        }
        #expect(!meter.reachedMaximum)
        meter.ingest(dim, at: 23.0 / 120, appliedExposure: meter.target)
        #expect(meter.reachedMaximum)
    }

    @Test func darkHalfDutyLampLeadsToCadence60() {
        // Pièce sombre, lampe à 5 Hz allumée la moitié du temps, depuis l'exposition maximale : le mesureur ne
        // peut pas éclaircir davantage, et le rythme permet 60 i/s mais pas 30 i/s.
        let maxProduct = testLimits.maxDuration * testLimits.maxISO
        let run = simulate(
            camera: SimulatedCamera(luma: 0.2, atProduct: maxProduct),
            initial: Exposure(durationSeconds: testLimits.maxDuration, iso: testLimits.maxISO),
            lamp: (dark: 12, lit: 12)
        )

        #expect(run.readyExposure != nil)
        #expect(run.meter.reachedMaximum)
        #expect(run.meter.rhythm.hasStrobe)
        let cadence = CadencePlanner.nextCadence(
            current: 120,
            available: [120, 60, 30],
            reachedMaximum: run.meter.reachedMaximum,
            rhythm: run.meter.rhythm
        )
        #expect(cadence == 60, "rythme : \(run.meter.rhythm)")
    }
}

// MARK: - Bornes d'exposition d'une cadence

@Suite("ExposureLimits")
struct ExposureLimitsTests {
    @Test func aPoseLastsAtMostOneAppliedFrame() {
        // 120 i/s : 1/120 s ; la durée d'image appliquée la plus courte l'emporte (1/125 s).
        let at120 = ExposureLimits(
            minDuration: 1e-5, formatMaxDuration: 0.5, fps: 120, appliedFrameDuration: 1.0 / 120, minISO: 50, maxISO: 3200
        )
        #expect(at120.maxDuration == 1.0 / 120)
        let shorterFrame = ExposureLimits(
            minDuration: 1e-5, formatMaxDuration: 0.5, fps: 120, appliedFrameDuration: 1.0 / 125, minISO: 50, maxISO: 3200
        )
        #expect(shorterFrame.maxDuration == 1.0 / 125)
        // Le format limite la pose (1/60 s à 30 i/s).
        let formatBound = ExposureLimits(
            minDuration: 1e-5, formatMaxDuration: 1.0 / 60, fps: 30, appliedFrameDuration: 1.0 / 30, minISO: 50, maxISO: 3200
        )
        #expect(formatBound.maxDuration == 1.0 / 60)
        // Jamais sous la durée minimale.
        let tiny = ExposureLimits(
            minDuration: 0.02, formatMaxDuration: 0.5, fps: 120, appliedFrameDuration: 1.0 / 120, minISO: 50, maxISO: 3200
        )
        #expect(tiny.maxDuration == 0.02)
        #expect(at120.minISO == 50 && at120.maxISO == 3200 && at120.minDuration == 1e-5)
    }

    @Test func upwardCadenceSwitchClampsTheDurationAndKeepsTheISO() {
        // L'appareil pose encore 1/30 s (ancienne cadence) quand une nouvelle série de mesures repart à 120 i/s.
        let limits = ExposureLimits(minDuration: 1e-5, maxDuration: 1.0 / 120, minISO: 50, maxISO: 3200)
        let clamped = Exposure(durationSeconds: 1.0 / 30, iso: 800).clampingDuration(to: limits)
        #expect(clamped == Exposure(durationSeconds: 1.0 / 120, iso: 800))
        // Une pose déjà permise ne change pas.
        let short = Exposure(durationSeconds: 1.0 / 240, iso: 800)
        #expect(short.clampingDuration(to: limits) == short)
    }
}
