import Foundation
import Testing
@testable import StrobeCore

// MARK: - Aides

/// Horodatages réguliers de `count` images à `fps` images par seconde.
private func timestamps(count: Int, fps: Double = 120) -> [Double] {
    (0..<count).map { Double($0) / fps }
}

/// Verdicts : `flash` pour les indices où `isLit` est vrai, `good` partout ailleurs.
private func verdicts(count: Int, isLit: (Int) -> Bool) -> [FrameVerdict] {
    (0..<count).map { isLit($0) ? .flash : .good }
}

/// Rythme de `count` images régulières à 120 i/s, avec lumière là où `isLit` est vrai.
private func rhythm(count: Int, isLit: (Int) -> Bool) -> StrobeRhythm {
    StrobeRhythmEstimator.estimate(times: timestamps(count: count), verdicts: verdicts(count: count, isLit: isLit))
}

/// 5 Hz, allumé la moitié du temps, à 120 i/s : 12 images avec lumière, puis 12 sans.
private func halfDuty(_ index: Int) -> Bool { (index / 12).isMultiple(of: 2) }

// MARK: - Tests

@Suite("StrobeRhythm")
struct StrobeRhythmTests {
    @Test func halfDutyStrobe() {
        let rhythm = rhythm(count: 360, isLit: halfDuty)

        #expect(rhythm.hasStrobe)
        #expect(abs(rhythm.shortestDarkGap - 0.1) <= 0.01, "moment sans lumière le plus court : \(rhythm.shortestDarkGap)")
        #expect(abs(rhythm.lightFraction - 0.5) <= 0.05)
    }

    @Test func noFlashMeansNoStrobe() {
        let rhythm = rhythm(count: 240) { _ in false }

        #expect(!rhythm.hasStrobe)
        #expect(rhythm.shortestDarkGap == .infinity)
        #expect(rhythm.lightFraction == 0)
    }

    @Test func rareShortFlashes() {
        // Une image avec lumière sur 12 : chaque moment sans lumière dure 11 images, soit 11/120 s.
        let rhythm = rhythm(count: 240) { $0 % 12 == 0 }

        #expect(rhythm.hasStrobe)
        #expect(abs(rhythm.shortestDarkGap - 0.0917) <= 0.01, "moment sans lumière le plus court : \(rhythm.shortestDarkGap)")
        #expect(abs(rhythm.lightFraction - 1.0 / 12) < 1e-9)
    }

    @Test func singleLightMomentGivesNoRhythm() {
        // Un seul moment avec lumière (un éclair isolé, ou le début d'un changement d'éclairage) : aucun moment
        // sans lumière n'est encadré, le rythme est inconnu.
        let rhythm = rhythm(count: 240) { (100..<104).contains($0) }

        #expect(!rhythm.hasStrobe)
        #expect(rhythm.shortestDarkGap == .infinity)
        #expect(abs(rhythm.lightFraction - 4.0 / 240) < 1e-9)
    }

    @Test func twoLightMomentsGiveNoRhythm() {
        // Deux moments avec lumière n'encadrent qu'un moment sans lumière : deux marches d'éclairage en donnent
        // autant. Il en faut au moins deux pour parler d'un strobe.
        let rhythm = rhythm(count: 240) { $0 == 100 || $0 == 121 }

        #expect(!rhythm.hasStrobe)
        #expect(rhythm.shortestDarkGap == .infinity)
    }

    @Test func twoLightingStepsAreNotAStrobe() {
        // Bout à bout : l'éclairage monte deux fois (0,1 -> 0,3 -> 0,9). En ligne, les 0,3 s qui suivent chaque
        // marche sont annoncées avec lumière ; le long moment entre les deux n'est pas un rythme.
        let count = 360
        let times = timestamps(count: count)
        var detector = OnlineFlashDetector()
        let judged = (0..<count).map { index in
            let luma = index < 120 ? 0.1 : index < 240 ? 0.3 : 0.9
            return detector.classify(FrameStats(meanLuma: luma, saturatedFraction: 0), at: times[index])
        }

        let rhythm = StrobeRhythmEstimator.estimate(times: times, verdicts: judged)
        #expect(rhythm.lightFraction > 0, "les marches devraient être annoncées en ligne")
        #expect(!rhythm.hasStrobe)
        #expect(rhythm.shortestDarkGap == .infinity)
    }

    @Test func lightingChangesAreNotAStrobe() {
        // 60 i/s, 10 s : la lumière s'allume 0,35 s toutes les 0,6 s. Plus longue que `maxFlashRunSeconds`, ce
        // n'est pas un strobe mais une suite de changements d'éclairage : en ligne, chacun est annoncé avec
        // lumière sur ses 0,3 premières secondes, puis gardé. Ces moments coupés à la limite ne bornent aucun
        // moment sans lumière : pas de rythme, et la cadence ne descend jamais sous 60 i/s (avec un « rythme »
        // de 0,3 s, 30 i/s aurait été permis).
        let count = 600
        let times = timestamps(count: count, fps: 60)
        var detector = OnlineFlashDetector()
        let judged = (0..<count).map { index in
            let luma = index % 36 >= 15 ? 0.4 : 0.1
            return detector.classify(FrameStats(meanLuma: luma, saturatedFraction: 0), at: times[index])
        }

        let rhythm = StrobeRhythmEstimator.estimate(times: times, verdicts: judged)
        #expect(rhythm.lightFraction > 0, "les changements devraient être annoncés en ligne")
        #expect(!rhythm.hasStrobe)
        #expect(rhythm.shortestDarkGap == .infinity)
        let cadences: [Double] = [120, 60, 30]
        #expect(CadencePlanner.nextCadence(current: 120, available: cadences, reachedMaximum: true, rhythm: rhythm) == 60)
        #expect(CadencePlanner.nextCadence(current: 60, available: cadences, reachedMaximum: true, rhythm: rhythm) == nil)
    }

    @Test func lightReachingTheLimitIsALightingChange() {
        // 120 i/s : moments avec lumière de 36 images (36/120 = 0,3 s, la limite) séparés de 12 images sans
        // lumière : changements d'éclairage, aucun rythme. Une image de moins (0,292 s) : un strobe.
        let atLimit = rhythm(count: 480) { $0 % 48 >= 12 }
        #expect(!atLimit.hasStrobe)

        let belowLimit = rhythm(count: 480) { $0 % 48 >= 13 }
        #expect(belowLimit.hasStrobe)
        #expect(abs(belowLimit.shortestDarkGap - 13.0 / 120) < 1e-9)

        // Limite réglable : à 0,5 s, les moments de 0,3 s redeviennent un strobe.
        let tunable = StrobeRhythmEstimator.estimate(
            times: timestamps(count: 480),
            verdicts: verdicts(count: 480) { $0 % 48 >= 12 },
            maxFlashRunSeconds: 0.5
        )
        #expect(tunable.hasStrobe)
        #expect(abs(tunable.shortestDarkGap - 0.1) < 1e-9)
    }

    @Test func gapsNextToALightingChangeAreNotMeasured() {
        // 120 i/s : un strobe (6 images avec lumière, 12 sans), puis un changement d'éclairage annoncé sur
        // 0,3 s (37 images), puis le strobe reprend. Les deux moments sans lumière qui bordent le changement
        // (ici de 20 images, plus longs) ne comptent pas ; les autres donnent 0,1 s.
        var lit = Set<Int>()
        for start in stride(from: 0, to: 108, by: 18) { lit.formUnion(start..<(start + 6)) }
        lit.formUnion(128..<165)
        for start in stride(from: 185, to: 360, by: 18) { lit.formUnion(start..<(start + 6)) }
        let times = timestamps(count: 360)
        let rhythm = StrobeRhythmEstimator.estimate(times: times, verdicts: verdicts(count: 360) { lit.contains($0) })

        #expect(rhythm.hasStrobe)
        #expect(abs(rhythm.shortestDarkGap - 0.1) < 1e-9)
    }

    @Test func darkMomentsAtTheEdgesAreNotMeasured() {
        // Avant le premier et après le dernier moment avec lumière, on ne sait pas quand la lumière s'est éteinte
        // ou rallumée : ces longs moments ne comptent pas. Restent ceux du milieu : 20 images (1/6 s) et 28.
        let rhythm = rhythm(count: 240) { $0 == 100 || $0 == 121 || $0 == 150 }

        #expect(rhythm.hasStrobe)
        #expect(abs(rhythm.shortestDarkGap - 20.0 / 120) < 1e-9)
    }

    @Test func strayShortDarkMomentIsIgnored() {
        // Une image sans lumière isolée au milieu d'un moment avec lumière (détection imparfaite) : le 20e centile
        // l'écarte, le moment sans lumière le plus court reste celui du strobe.
        let rhythm = rhythm(count: 360) { halfDuty($0) && $0 != 30 }

        #expect(rhythm.hasStrobe)
        #expect(abs(rhythm.shortestDarkGap - 0.1) <= 0.01, "moment sans lumière le plus court : \(rhythm.shortestDarkGap)")
    }

    @Test func durationUsesTheTypicalFrameInterval() {
        // 30 i/s avec un trou d'horodatage isolé : l'intervalle d'une image reste 1/30 s (médiane des écarts).
        // Moments avec lumière aux images 0, 4 et 8 : chaque moment sans lumière (3 images) dure 3/30 s.
        var times = timestamps(count: 30, fps: 30)
        for index in 20..<30 { times[index] += 0.5 }
        let lit = verdicts(count: 30) { $0.isMultiple(of: 4) && $0 <= 8 }
        let rhythm = StrobeRhythmEstimator.estimate(times: times, verdicts: lit)

        #expect(abs(rhythm.shortestDarkGap - 0.1) < 1e-9)
    }

    @Test func emptyInputHasNoStrobe() {
        let rhythm = StrobeRhythmEstimator.estimate(times: [], verdicts: [])

        #expect(rhythm == StrobeRhythm(hasStrobe: false, shortestDarkGap: .infinity, lightFraction: 0))
    }

    @Test func rhythmOfTheOnlineDetectorOnAHalfDutyLamp() {
        // Bout à bout : la lampe de l'essai sur iPhone, jugée image par image comme pendant la mesure.
        let count = 360
        let times = timestamps(count: count)
        var detector = OnlineFlashDetector()
        let judged = (0..<count).map { index in
            let stats = FrameStats(meanLuma: halfDuty(index) ? 0.15 : 0.03, saturatedFraction: 0)
            return detector.classify(stats, at: times[index])
        }

        let rhythm = StrobeRhythmEstimator.estimate(times: times, verdicts: judged)
        #expect(rhythm.hasStrobe)
        #expect(abs(rhythm.shortestDarkGap - 0.1) <= 0.01, "moment sans lumière le plus court : \(rhythm.shortestDarkGap)")
        #expect(abs(rhythm.lightFraction - 0.5) <= 0.05)
    }
}
