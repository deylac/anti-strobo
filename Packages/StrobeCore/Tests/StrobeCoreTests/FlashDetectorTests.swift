import Foundation
import Testing
@testable import StrobeCore

// MARK: - Aides

/// Cadence des scènes de test : 120 images par seconde.
private func time(_ index: Int) -> Double { Double(index) / 120 }

/// Bruit déterministe dans [-amplitude, +amplitude] : pas de hasard, les tests restent reproductibles.
private func noise(_ index: Int, amplitude: Double = 0.01) -> Double {
    Double((index * 7919) % 21 - 10) / 10 * amplitude
}

/// Image « calme » : luma `luma` ± bruit, saturation constante.
private func steady(_ index: Int, luma: Double, saturation: Double = 0, noise amplitude: Double = 0.01) -> FrameStats {
    FrameStats(meanLuma: luma + noise(index, amplitude: amplitude), saturatedFraction: saturation)
}

private func timestamps(count: Int) -> [Double] { (0..<count).map(time) }

private func onlineVerdicts(
    _ stats: [FrameStats],
    times: [Double],
    config: FlashDetectorConfig = .init()
) -> [FrameVerdict] {
    var detector = OnlineFlashDetector(config: config)
    return zip(stats, times).map { detector.classify($0, at: $1) }
}

private func offlineVerdicts(
    _ stats: [FrameStats],
    times: [Double],
    config: FlashDetectorConfig = .init()
) -> [FrameVerdict] {
    OfflineFlashDetector.classify(stats, times: times, config: config)
}

private extension Array where Element == FrameVerdict {
    /// Indices des images jugées « flash ».
    var flashIndices: [Int] { indices.filter { self[$0] == .flash } }
}

// MARK: - Tests

@Suite("FlashDetector")
struct FlashDetectorTests {
    @Test func steadySceneHasNoFlash() {
        let stats = (0..<240).map { steady($0, luma: 0.3) }
        let times = timestamps(count: 240)

        #expect(onlineVerdicts(stats, times: times).flashIndices == [])
        #expect(offlineVerdicts(stats, times: times).flashIndices == [])
    }

    // MARK: Lumière allumée longtemps

    @Test func halfDutyLampIsLight() {
        // L'essai sur iPhone : une lampe à 5 Hz allumée la moitié du temps, seule source d'une pièce sombre.
        // 12 images allumées (≈ 0,15) puis 12 éteintes (≈ 0,03), pendant 3 s. Une médiane glissante prenait
        // cette lumière pour l'éclairage normal ; ici, les deux niveaux se voient dans chaque fenêtre.
        let count = 360
        let lit = (0..<count).filter { ($0 / 12).isMultiple(of: 2) }
        let stats = (0..<count).map { steady($0, luma: lit.contains($0) ? 0.15 : 0.03, noise: 0.005) }
        let times = timestamps(count: count)

        #expect(offlineVerdicts(stats, times: times).flashIndices == lit)

        // En ligne : passé 0,5 s, la fenêtre a forcément vu les deux niveaux.
        let online = onlineVerdicts(stats, times: times).flashIndices
        #expect(online.filter { $0 >= 60 } == lit.filter { $0 >= 60 })
        // Même avant, aucune image éteinte n'est retirée.
        #expect(Set(online).isSubset(of: Set(lit)))
    }

    @Test func halfDutyLampAt30fpsIsLight() {
        // La même lampe telle qu'elle apparaît dans l'export 30 i/s de l'essai :
        // 3 images à ≈ 0,15 puis 3 à ≈ 0,03.
        let count = 90
        let times = (0..<count).map { Double($0) / 30 }
        let lit = (0..<count).filter { ($0 / 3).isMultiple(of: 2) }
        let stats = (0..<count).map { steady($0, luma: lit.contains($0) ? 0.15 : 0.03, noise: 0.005) }

        #expect(offlineVerdicts(stats, times: times).flashIndices == lit)

        let online = onlineVerdicts(stats, times: times).flashIndices
        #expect(online.filter { $0 >= 15 } == lit.filter { $0 >= 15 })
        #expect(Set(online).isSubset(of: Set(lit)))
    }

    @Test func saturatedHalfDutyStrobeIsLight() {
        // Strobe de concert allumé la moitié du temps, dont les images éclairées sont brûlées.
        let count = 360
        let lit = (0..<count).filter { ($0 / 12).isMultiple(of: 2) }
        let stats = (0..<count).map { index in
            lit.contains(index)
                ? FrameStats(meanLuma: 0.97, saturatedFraction: 0.9)
                : steady(index, luma: 0.2)
        }
        let times = timestamps(count: count)

        #expect(offlineVerdicts(stats, times: times).flashIndices == lit)

        let online = onlineVerdicts(stats, times: times).flashIndices
        #expect(online.filter { $0 >= 60 } == lit.filter { $0 >= 60 })
        #expect(Set(online).isSubset(of: Set(lit)))
    }

    // MARK: Éclairs courts et rares

    @Test func rareShortFlashesStillDetected() {
        // Strobe de concert classique : une image brûlée sur 12 à 120 i/s.
        let stats = (0..<240).map { index in
            index % 12 == 0
                ? FrameStats(meanLuma: 0.95, saturatedFraction: 0.6)
                : steady(index, luma: 0.25)
        }
        let times = timestamps(count: 240)
        let strobes = Array(stride(from: 0, to: 240, by: 12))

        #expect(offlineVerdicts(stats, times: times).flashIndices == strobes)

        // En ligne : la fenêtre se remplit pendant les 60 premières images (0,5 s).
        let online = onlineVerdicts(stats, times: times).flashIndices
        #expect(online.filter { $0 >= 60 } == strobes.filter { $0 >= 60 })
        // Même pendant la montée en charge, aucune image calme n'est prise pour un éclair.
        #expect(Set(online).isSubset(of: Set(strobes)))

        // Le même strobe quand l'éclairage de la scène monte d'un cran (0,25 -> 0,5) au bout de 1 s.
        let steppedStrobes = Array(stride(from: 6, to: 360, by: 12))
        let stepped = (0..<360).map { index in
            steppedStrobes.contains(index)
                ? FrameStats(meanLuma: 0.95, saturatedFraction: 0.6)
                : steady(index, luma: index < 120 ? 0.25 : 0.5)
        }
        let steppedTimes = timestamps(count: 360)
        #expect(offlineVerdicts(stepped, times: steppedTimes).flashIndices == steppedStrobes)

        // En ligne, les 0,3 s qui suivent la marche ne peuvent pas être connues pour un changement d'éclairage.
        let unknown = 120...(120 + 36)
        let steppedOnline = onlineVerdicts(stepped, times: steppedTimes).flashIndices
        #expect(steppedOnline.filter { $0 >= 60 && !unknown.contains($0) }
            == steppedStrobes.filter { $0 >= 60 && !unknown.contains($0) })
    }

    @Test func strobeNextToLightingStepStillDetected() {
        // Éclairs brûlés juste après une marche montante (0,1 -> 0,5) : la marche impose la coupure, l'éclair
        // tombe dans le niveau haut avec 0,5, mais sa lumière à lui ne dure qu'une image.
        let strobes = [132, 144, 240]
        let stepUp = (0..<360).map { index in
            strobes.contains(index)
                ? FrameStats(meanLuma: 0.95, saturatedFraction: 0.6)
                : steady(index, luma: index < 120 ? 0.1 : 0.5)
        }
        let times = timestamps(count: 360)
        #expect(offlineVerdicts(stepUp, times: times).flashIndices == strobes)
        #expect(Set(strobes).isSubset(of: Set(onlineVerdicts(stepUp, times: times).flashIndices)))

        // Éclairs juste avant une marche descendante (0,5 -> 0,1).
        let before = [96, 108, 240]
        let stepDown = (0..<360).map { index in
            before.contains(index)
                ? FrameStats(meanLuma: 0.95, saturatedFraction: 0.6)
                : steady(index, luma: index < 120 ? 0.5 : 0.1)
        }
        #expect(offlineVerdicts(stepDown, times: times).flashIndices == before)
        #expect(onlineVerdicts(stepDown, times: times).flashIndices == before)

        // Les mêmes éclairs sans être brûlés : seule leur luma, nettement au-dessus de leurs voisines, les trahit.
        let softStepUp = stepUp.map { $0.meanLuma > 0.9 ? FrameStats(meanLuma: 0.95, saturatedFraction: 0.1) : $0 }
        let softStepDown = stepDown.map { $0.meanLuma > 0.9 ? FrameStats(meanLuma: 0.95, saturatedFraction: 0.1) : $0 }
        #expect(offlineVerdicts(softStepUp, times: times).flashIndices == strobes)
        #expect(offlineVerdicts(softStepDown, times: times).flashIndices == before)
    }

    @Test func shortFlashNearSmallStepStillDetected() {
        // Marche trop faible pour faire deux niveaux (0,3 -> 0,45), mais c'est elle qui sépare le mieux la
        // fenêtre : la coupure échoue. Un éclair court non saturé (0,8) reste détecté comme en V1, par rapport
        // à la médiane de la fenêtre.
        let flashes = [132, 240]
        let stats = (0..<360).map { index in
            flashes.contains(index)
                ? FrameStats(meanLuma: 0.8, saturatedFraction: 0)
                : steady(index, luma: index < 120 ? 0.3 : 0.45, noise: 0.005)
        }
        let times = timestamps(count: 360)

        #expect(offlineVerdicts(stats, times: times).flashIndices == flashes)
        #expect(onlineVerdicts(stats, times: times).flashIndices == flashes)
    }

    @Test func lowFrameRateIsJudged() {
        // À 10 i/s, une fenêtre de 0,5 s ne contient que 5 images : assez pour juger à cette cadence.
        let count = 60
        let times = (0..<count).map { Double($0) / 10 }
        let strobes = Array(stride(from: 5, to: count, by: 10))
        let stats = (0..<count).map { index in
            strobes.contains(index)
                ? FrameStats(meanLuma: 0.95, saturatedFraction: 0.6)
                : steady(index, luma: 0.25)
        }

        #expect(offlineVerdicts(stats, times: times).flashIndices == strobes)
        let online = onlineVerdicts(stats, times: times).flashIndices
        #expect(online.filter { $0 >= 10 } == strobes.filter { $0 >= 10 })
        #expect(Set(online).isSubset(of: Set(strobes)))
    }

    @Test func darkSceneSmallFlashDetected() {
        // 0,05 -> 0,30 : écart absolu modeste, mais bien supérieur au seuil 0,05 * 1,6 + 0,04.
        let stats = (0..<240).map { index in
            index % 12 == 6
                ? FrameStats(meanLuma: 0.30, saturatedFraction: 0.02)
                : steady(index, luma: 0.05, noise: 0.005)
        }
        let times = timestamps(count: 240)
        let strobes = Array(stride(from: 6, to: 240, by: 12))

        #expect(offlineVerdicts(stats, times: times).flashIndices == strobes)

        let online = onlineVerdicts(stats, times: times).flashIndices
        #expect(online.filter { $0 >= 60 } == strobes.filter { $0 >= 60 })
        #expect(Set(online).isSubset(of: Set(strobes)))
    }

    // MARK: Changements d'éclairage

    @Test func slowBreathingLightIsNotLight() {
        // Projecteur qui « respire » : luma 0,1 <-> 0,5 à 0,5 Hz, pendant 4 s. En ligne, l'image la plus récente
        // d'une montée est toujours la plus claire de sa fenêtre, mais elle ne s'allume pas d'un coup : aucune
        // lumière ne commence, et aucun rythme de strobe n'apparaît.
        let count = 480
        let times = timestamps(count: count)
        let stats = (0..<count).map { steady($0, luma: 0.3 - 0.2 * cos(2 * .pi * 0.5 * time($0)), noise: 0.005) }

        let online = onlineVerdicts(stats, times: times)
        #expect(online.flashIndices == [])
        #expect(!StrobeRhythmEstimator.estimate(times: times, verdicts: online).hasStrobe)
        #expect(offlineVerdicts(stats, times: times).flashIndices == [])
    }

    @Test func halfLitEdgeFrameDoesNotHideTheLamp() {
        // Lampe 12/12 (0,15 / 0,03) dont chaque allumage commence par une image à moitié éclairée (0,07,
        // obturateur roulant). Règle V2-R9 : au-dessus de 20 % de l'écart entre les deux niveaux (0,054), elle
        // part avec la lumière ; en ligne, la lumière qui suit reste retirée elle aussi.
        let count = 360
        let lit = (0..<count).filter { $0 % 24 >= 12 }
        let stats = (0..<count).map { index in
            steady(index, luma: index % 24 == 12 ? 0.07 : (lit.contains(index) ? 0.15 : 0.03), noise: 0.005)
        }
        let times = timestamps(count: count)

        let online = onlineVerdicts(stats, times: times).flashIndices
        #expect(online.filter { $0 >= 60 } == lit.filter { $0 >= 60 })
        #expect(offlineVerdicts(stats, times: times).flashIndices == lit)
    }

    /// Le seuil des images à moitié éclairées se règle (`edgeShare`) : un bord à 22 % de l'écart entre les deux
    /// niveaux part avec la lumière au réglage par défaut (20 %), mais reste au réglage de 25 %, hors ligne
    /// comme en ligne.
    @Test func edgeShareIsTunable() {
        let count = 360
        let lit = (0..<count).filter { $0 % 24 >= 13 }
        let edges = (0..<count).filter { $0 % 24 == 12 }
        // Niveaux 0,05 et 0,45 : 20 % de l'écart → 0,13, 25 % → 0,15 ; le bord est à 0,14.
        let stats = (0..<count).map { index in
            steady(index, luma: index % 24 == 12 ? 0.14 : (lit.contains(index) ? 0.45 : 0.05), noise: 0.003)
        }
        let times = timestamps(count: count)
        var quarter = FlashDetectorConfig()
        quarter.edgeShare = 0.25

        #expect(offlineVerdicts(stats, times: times).flashIndices == (lit + edges).sorted())
        #expect(offlineVerdicts(stats, times: times, config: quarter).flashIndices == lit)
        let online = onlineVerdicts(stats, times: times).flashIndices.filter { $0 >= 60 }
        #expect(online == (lit + edges).sorted().filter { $0 >= 60 })
        let onlineQuarter = onlineVerdicts(stats, times: times, config: quarter).flashIndices.filter { $0 >= 60 }
        #expect(onlineQuarter == lit.filter { $0 >= 60 })
    }

    /// Lampe à 5 Hz dont chaque période allumée est bordée d'une image à moitié éclairée de chaque côté : la
    /// lampe s'allume puis s'éteint pendant la pose (obturateur roulant, pose partielle), comme les images 300
    /// et 309 de l'essai sur iPhone. Règle V2-R9 : dans une fenêtre à deux niveaux, une image n'est sans lumière
    /// que sous `edgeShare` de l'écart (bas + 0,2 × (haut − bas)) ; ces bords partent avec la lumière, hors
    /// ligne comme en ligne. À 120 i/s (période de 24 images) et à 30 i/s (période de 6, l'export de l'essai).
    @Test(arguments: [120.0, 30.0])
    func halfLitEdgesOnBothSidesAreLight(fps: Double) {
        let period = Int(fps / 5)
        let count = Int(fps * 3)
        // Période : éteinte, bord d'allumage (0,07), allumée (0,15), bord d'extinction (0,10).
        let leading = period / 2 - 1
        let trailing = period - 1
        func luma(_ index: Int) -> Double {
            switch index % period {
            case leading: 0.07
            case trailing: 0.10
            case let phase where phase > leading: 0.15
            default: 0.03
            }
        }
        let times = (0..<count).map { Double($0) / fps }
        let stats = (0..<count).map { steady($0, luma: luma($0), noise: 0.005) }
        let lit = (0..<count).filter { $0 % period >= leading }
        let edges = (0..<count).filter { $0 % period == leading || $0 % period == trailing }

        let offline = offlineVerdicts(stats, times: times).flashIndices
        #expect(offline == lit)
        #expect(Set(edges).isSubset(of: Set(offline)))

        // En ligne : passé 0,5 s, la fenêtre a vu les deux niveaux ; avant, aucune image éteinte n'est retirée.
        let warmUp = Int(fps / 2)
        let online = onlineVerdicts(stats, times: times).flashIndices
        #expect(online.filter { $0 >= warmUp } == lit.filter { $0 >= warmUp })
        #expect(Set(online).isSubset(of: Set(lit)))
    }

    @Test func slowFadeIsNotLight() {
        // Fondu de projecteur : 0,1 -> 0,5 en 3 s. Sur 0,5 s, la luma ne bouge que de 0,07 : coupée en deux,
        // une rampe donne deux groupes séparés de 0,03, loin du rapport 1,6 + marge 0,04.
        let count = 360
        let stats = (0..<count).map { steady($0, luma: 0.1 + 0.4 * Double($0) / Double(count - 1), noise: 0.005) }
        let times = timestamps(count: count)

        #expect(onlineVerdicts(stats, times: times).flashIndices == [])
        #expect(offlineVerdicts(stats, times: times).flashIndices == [])
    }

    @Test(arguments: [2.0, 1.0, 0.5])
    func fastFadeFromDarkIsNotLight(seconds: Double) {
        // Projecteur qui s'allume en fondu depuis le noir (0,02 -> 0,8), puis reste allumé 1 s. Assez rapide pour
        // que des fenêtres se coupent en deux niveaux, mais cette lumière dure : rien n'est retiré de la vidéo.
        // Le bruit d'une image à l'autre (± 0,005) dépasse la pente par image : il ne doit pas couper la période.
        let rampCount = Int(seconds * 120)
        let lumas = (0..<rampCount).map { 0.02 + 0.78 * Double($0) / Double(rampCount - 1) }
            + Array(repeating: 0.8, count: 120)
        let stats = lumas.indices.map { steady($0, luma: lumas[$0], noise: 0.005) }

        #expect(offlineVerdicts(stats, times: timestamps(count: stats.count)).flashIndices == [])
    }

    @Test func sustainedStepIsNotLight() {
        let stats = (0..<360).map { steady($0, luma: $0 < 120 ? 0.3 : 0.7) }
        let times = timestamps(count: 360)

        // Hors ligne : la nouvelle lumière dure 2 s, bien plus que maxFlashRunSeconds : rien n'est retiré.
        #expect(offlineVerdicts(stats, times: times).flashIndices == [])

        // En ligne : les premières images de la marche ne peuvent pas être connues pour ce qu'elles sont,
        // mais passé maxFlashRunSeconds la fenêtre repart du nouveau niveau.
        let online = onlineVerdicts(stats, times: times)
        let settled = time(120) + FlashDetectorConfig().maxFlashRunSeconds
        #expect(online[..<120].allSatisfy { $0 == .good })
        let lateFlashes = online.flashIndices.filter { time($0) > settled }
        #expect(lateFlashes == [])
    }

    @Test func localBrightSpotNotFlash() {
        // Projecteur dans le champ : 10 % de pixels brûlés en permanence, luma moyenne stable.
        let stats = (0..<240).map { steady($0, luma: 0.3, saturation: 0.1) }
        let times = timestamps(count: 240)

        #expect(onlineVerdicts(stats, times: times).flashIndices == [])
        #expect(offlineVerdicts(stats, times: times).flashIndices == [])
    }

    // MARK: Saturation

    @Test func saturationAloneTriggersFlash() {
        // Luma 0,40 : sous le seuil 0,3 * 1,6 + 0,04 = 0,52 ; seule la saturation (0 -> 0,5) trahit l'éclair.
        let stats = (0..<240).map { index in
            index % 12 == 3
                ? FrameStats(meanLuma: 0.40, saturatedFraction: 0.5)
                : steady(index, luma: 0.3, saturation: 0.02)
        }
        let times = timestamps(count: 240)
        let strobes = Array(stride(from: 3, to: 240, by: 12))

        #expect(offlineVerdicts(stats, times: times).flashIndices == strobes)
        let online = onlineVerdicts(stats, times: times).flashIndices
        #expect(online.filter { $0 >= 60 } == strobes.filter { $0 >= 60 })
    }

    @Test func permanentlySaturatedSceneIsNotFlash() {
        // Le niveau bas dépasse déjà saturatedFractionMax : la saturation ne dit plus rien.
        let stats = (0..<240).map { steady($0, luma: 0.6, saturation: 0.4) }
        let times = timestamps(count: 240)

        #expect(onlineVerdicts(stats, times: times).flashIndices == [])
        #expect(offlineVerdicts(stats, times: times).flashIndices == [])
    }

    // MARK: Durée des périodes avec lumière, en secondes

    @Test func lightPeriodLengthIsMeasuredInSeconds() {
        // 24 images/s avec un peu de gigue : 0,3 s vaut 7,2 intervalles, pas un nombre entier d'images.
        let count = 120
        let times = (0..<count).map { Double($0) / 24 + noise($0, amplitude: 0.004) }

        func scene(burst: Range<Int>) -> [FrameStats] {
            (0..<count).map { index in
                burst.contains(index)
                    ? FrameStats(meanLuma: 0.9, saturatedFraction: 0.5)
                    : steady(index, luma: 0.25)
            }
        }

        // 7 images (≈ 0,25 s) : de la lumière, en ligne comme hors ligne.
        let short = scene(burst: 60..<67)
        #expect(offlineVerdicts(short, times: times).flashIndices == Array(60..<67))
        #expect(onlineVerdicts(short, times: times).flashIndices == Array(60..<67))

        // 9 images (≈ 0,33 s) : un changement d'éclairage. Hors ligne, rien n'est retiré ;
        // en ligne, seules les images dans la limite de 0,3 s ont déjà été annoncées.
        let long = scene(burst: 60..<69)
        #expect(offlineVerdicts(long, times: times).flashIndices == [])
        #expect(onlineVerdicts(long, times: times).flashIndices == Array(60..<68))
    }

    @Test func lightLastingExactlyTheLimitIsLightWhateverTheRounding() {
        // 30 i/s, lampe allumée 10 images sur 16 : chaque période allumée s'étend sur 9/30 = 0,3 s pile, la
        // limite. Selon l'image de départ, (i + 9)/30 − i/30 vaut 0,30000000000000004 en flottant : sans
        // tolérance, certaines périodes passaient pour des changements d'éclairage et restaient dans la vidéo.
        // La scène finit éteinte (une lumière coupée par la fin ne se voit plus sur deux niveaux).
        let count = 150
        let times = (0..<count).map { Double($0) / 30 }
        let lit = (0..<count).filter { $0 % 16 >= 6 }
        let stats = (0..<count).map { FrameStats(meanLuma: lit.contains($0) ? 0.6 : 0.1, saturatedFraction: 0) }

        #expect(offlineVerdicts(stats, times: times).flashIndices == lit)
        // En ligne, une fois les deux niveaux vus (après la première période) : toute la période est annoncée.
        let online = onlineVerdicts(stats, times: times).flashIndices
        #expect(online.filter { $0 >= 16 } == lit.filter { $0 >= 16 })
    }

    @Test func onlineFollowsIlluminationChange() {
        // Marche 0,2 -> 0,4 (au-dessus de 0,2 * 1,6 + 0,04), puis éclairs sur le nouveau niveau.
        let count = 360
        let strobes = Array(stride(from: 210, to: count, by: 12))
        let stats = (0..<count).map { index in
            strobes.contains(index)
                ? FrameStats(meanLuma: 0.95, saturatedFraction: 0.6)
                : steady(index, luma: index < 120 ? 0.2 : 0.4)
        }
        let verdicts = onlineVerdicts(stats, times: timestamps(count: count))

        // Une fois la fenêtre repartie du nouveau niveau, les éclairs sont détectés par rapport à lui.
        let settled = time(120) + FlashDetectorConfig().maxFlashRunSeconds
        #expect(verdicts.flashIndices.filter { time($0) > settled } == strobes)
    }

    // MARK: Cas limites

    @Test func tooFewFramesAreNotJudged() {
        // Moins de 6 images dans la fenêtre : pas assez pour parler de deux niveaux, tout est gardé.
        let dark = FrameStats(meanLuma: 0.1, saturatedFraction: 0)
        let bright = FrameStats(meanLuma: 0.9, saturatedFraction: 0)

        let five = [dark, dark, bright, dark, dark]
        #expect(offlineVerdicts(five, times: timestamps(count: 5)).flashIndices == [])
        let six = five + [dark]
        #expect(offlineVerdicts(six, times: timestamps(count: 6)).flashIndices == [2])

        // En ligne, la fenêtre ne contient que les images déjà reçues.
        let brightFifth = [dark, dark, dark, dark, bright]
        #expect(onlineVerdicts(brightFifth, times: timestamps(count: 5)).flashIndices == [])
        let brightSixth = [dark, dark, dark, dark, dark, bright]
        #expect(onlineVerdicts(brightSixth, times: timestamps(count: 6)).flashIndices == [5])
    }

    @Test func resetForgetsPreviousBaseline() {
        let dark = (0..<60).map { steady($0, luma: 0.1) }
        let brighter = (0..<60).map { steady($0, luma: 0.5) }
        let times = timestamps(count: 60)

        var fresh = OnlineFlashDetector()
        let expected = zip(brighter, times).map { fresh.classify($0, at: $1) }

        var reused = OnlineFlashDetector()
        for (stats, t) in zip(dark, times) { _ = reused.classify(stats, at: t) }
        reused.reset()
        let afterReset = zip(brighter, times).map { reused.classify($0, at: $1) }

        #expect(afterReset == expected)
        // Sans reset, 0,5 aurait été pris pour de la lumière à côté de 0,1 ; le détecteur neuf n'a qu'un niveau.
        #expect(afterReset.flashIndices == [])
    }

    @Test func rescaleKeepsBothLevels() {
        // Lampe 50 % : 15 images éteintes (0,05) puis 15 allumées (0,2). À l'image 75, au début d'une phase
        // allumée, l'exposition est divisée par 2 et toutes les lumas avec : la lampe allumée (0,1) est alors
        // plus sombre que les anciennes images allumées. Ramenées à la nouvelle exposition, les images déjà vues
        // gardent les deux niveaux : la phase allumée qui suit est retirée tout de suite.
        let count = 150
        let lit = (0..<count).filter { !($0 / 15).isMultiple(of: 2) }
        let times = timestamps(count: count)

        var rescaled = OnlineFlashDetector()
        var forgetful = OnlineFlashDetector()
        var rescaledVerdicts: [FrameVerdict] = []
        var forgetfulVerdicts: [FrameVerdict] = []
        for index in 0..<count {
            if index == 75 {
                rescaled.rescale(by: 0.5)
                forgetful.reset()
            }
            let luma = (lit.contains(index) ? 0.2 : 0.05) * (index >= 75 ? 0.5 : 1)
            let stats = FrameStats(meanLuma: luma, saturatedFraction: 0)
            rescaledVerdicts.append(rescaled.classify(stats, at: times[index]))
            forgetfulVerdicts.append(forgetful.classify(stats, at: times[index]))
        }

        #expect(rescaledVerdicts.flashIndices.filter { $0 >= 15 } == lit.filter { $0 >= 15 })
        // Sans les images d'avant, la phase allumée qui suit le changement n'a qu'un niveau : elle serait gardée.
        #expect(forgetfulVerdicts.flashIndices.filter { (75..<90).contains($0) } == [])
    }

    @Test func rescaleClampsToTheLumaRange() {
        // Éclairs à 0,9 sur une scène à 0,25, puis l'exposition double. Un éclair ne peut pas dépasser une luma
        // de 1 : ramenés sans borne (1,8), les anciens éclairs feraient passer le nouveau (1) pour le niveau bas.
        var detector = OnlineFlashDetector()
        for index in 0..<60 {
            let luma = index % 12 == 6 ? 0.9 : 0.25
            _ = detector.classify(FrameStats(meanLuma: luma, saturatedFraction: 0), at: time(index))
        }
        detector.rescale(by: 2)
        for index in 60..<66 {
            #expect(detector.classify(FrameStats(meanLuma: 0.5, saturatedFraction: 0), at: time(index)) == .good)
        }
        #expect(detector.classify(FrameStats(meanLuma: 1, saturatedFraction: 0), at: time(66)) == .flash)
    }

    @Test func offlineEmptyInputGivesEmptyOutput() {
        #expect(OfflineFlashDetector.classify([], times: []) == [])
    }

    @Test func configDefaultsAndCoding() throws {
        let config = FlashDetectorConfig()
        #expect(config.relativeJump == 1.6)
        #expect(config.absoluteMargin == 0.04)
        #expect(config.saturatedFractionMax == 0.25)
        #expect(config.baselineWindowSeconds == 0.5)
        #expect(config.maxFlashRunSeconds == 0.3)
        #expect(config.edgeShare == 0.2)

        var tuned = config
        tuned.relativeJump = 2
        tuned.edgeShare = 0.3
        let decoded = try JSONDecoder().decode(FlashDetectorConfig.self, from: JSONEncoder().encode(tuned))
        #expect(decoded == tuned)

        let verdicts = try JSONDecoder().decode([FrameVerdict].self, from: JSONEncoder().encode([FrameVerdict.good, .flash]))
        #expect(verdicts == [.good, .flash])
    }
}
