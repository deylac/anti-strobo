import Foundation
import Testing
@testable import StrobeCore

// MARK: - Aides

/// Cadence des images sources de test : 120 images par seconde.
private let sourceFPS = 120.0

/// Une image sans intérêt pour la sélection : luma quelconque.
private let plainStats = FrameStats(meanLuma: 0.3, saturatedFraction: 0)

/// Horodatages réguliers à 120 i/s pour `count` images.
private func regularTimes(count: Int) -> [Double] {
    (0..<count).map { Double($0) / sourceFPS }
}

/// Verdicts : `flash` pour les indices de `flashed`, `good` partout ailleurs.
private func verdicts(count: Int, flashed: some Sequence<Int>) -> [FrameVerdict] {
    var result = [FrameVerdict](repeating: .good, count: count)
    for index in flashed { result[index] = .flash }
    return result
}

/// Plus longue suite de créneaux consécutifs qui reprennent la même image source.
private func longestRepeat(in indices: [Int]) -> Int {
    var longest = 0
    var current = 0
    var previous: Int?
    for index in indices {
        current = index == previous ? current + 1 : 1
        previous = index
        longest = max(longest, current)
    }
    return longest
}

/// 3 s à 120 i/s où les images `flashed` sont brûlées ; les lumas varient d'une image à l'autre.
private func selectBurstScene(flashed: some Sequence<Int>) -> (indices: [Int], report: SelectionReport) {
    let count = 360
    return FrameSelector.select(
        times: regularTimes(count: count),
        verdicts: verdicts(count: count, flashed: flashed),
        stats: (0..<count).map { FrameStats(meanLuma: 0.3 + Double(($0 * 37) % 11) / 100, saturatedFraction: 0) },
        duration: 3
    )
}

// MARK: - Tests

@Suite("FrameSelector")
struct FrameSelectorTests {
    @Test func noFlashKeepsOneFramePerSlot() {
        let times = regularTimes(count: 240)

        let result = FrameSelector.select(
            times: times,
            verdicts: verdicts(count: 240, flashed: []),
            stats: Array(repeating: plainStats, count: 240),
            duration: 2
        )

        // 120 i/s -> 30 i/s : la première image de chaque créneau est une image sur quatre.
        #expect(result.indices.count == 60)
        #expect(result.indices == Array(stride(from: 0, to: 240, by: 4)))
        #expect(result.report == SelectionReport(slots: 60, heldSlots: 0, fallbackSlots: 0))
    }

    @Test func flashFramesNeverChosenWhenAlternativeExists() {
        let flashed = Set(stride(from: 0, to: 240, by: 4))
        let allVerdicts = verdicts(count: 240, flashed: flashed)

        let result = FrameSelector.select(
            times: regularTimes(count: 240),
            verdicts: allVerdicts,
            stats: Array(repeating: plainStats, count: 240),
            duration: 2
        )

        #expect(result.indices.count == 60)
        #expect(result.indices.allSatisfy { allVerdicts[$0] == .good })
        // Dans chaque créneau, l'image 4k est brûlée : on prend la suivante, 4k + 1.
        #expect(result.indices == Array(stride(from: 1, to: 240, by: 4)))
        #expect(result.report.heldSlots == 0)
        #expect(result.report.fallbackSlots == 0)
    }

    @Test func shortGapHoldsLastGood() {
        // Créneaux 5, 6 et 7 (images 20 à 31) entièrement brûlés : 0,1 s au plus depuis la dernière bonne image.
        let result = FrameSelector.select(
            times: regularTimes(count: 240),
            verdicts: verdicts(count: 240, flashed: 20..<32),
            stats: Array(repeating: plainStats, count: 240),
            duration: 2
        )

        let expected = [0, 4, 8, 12, 16, 16, 16, 16] + Array(stride(from: 32, to: 240, by: 4))
        #expect(result.indices == expected)
        #expect(result.report == SelectionReport(slots: 60, heldSlots: 3, fallbackSlots: 0))
    }

    @Test func longBurstFallsBackToLeastBurnt() {
        // 3 s à 120 i/s ; la seconde du milieu (images 120 à 239, créneaux 30 à 59) est entièrement brûlée,
        // avec des lumas qui varient d'une image à l'autre.
        let count = 360
        let burst = 120..<240
        let stats = (0..<count).map { index in
            FrameStats(
                meanLuma: burst.contains(index) ? 0.5 + 0.4 * Double((index * 37) % 11) / 10 : 0.3,
                saturatedFraction: burst.contains(index) ? 0.6 : 0
            )
        }

        let result = FrameSelector.select(
            times: regularTimes(count: count),
            verdicts: verdicts(count: count, flashed: burst),
            stats: stats,
            duration: 3
        )

        #expect(result.indices.count == 90)
        #expect(result.report.fallbackSlots > 0)

        // La dernière bonne image (116, créneau 29) est répétée sur les créneaux 30 à 34 (moins de 0,2 s),
        // puis chaque créneau prend l'image la moins lumineuse de ses quatre images.
        #expect(result.report.heldSlots == 5)
        #expect(result.report.fallbackSlots == 25)
        #expect(result.indices[30...34].allSatisfy { $0 == 116 })
        for slot in 35...59 {
            let slotFrames = (slot * 4)..<(slot * 4 + 4)
            let dimmest = slotFrames.min { stats[$0].meanLuma < stats[$1].meanLuma }
            #expect(result.indices[slot] == dimmest)
        }
        #expect(result.indices[60...] == ArraySlice(stride(from: 240, to: 360, by: 4)))

        // Aucune image n'est répétée plus de 0,2 × 30 = 6 créneaux d'affilée.
        #expect(longestRepeat(in: result.indices) <= 6)
        // Jamais de retour en arrière.
        #expect(zip(result.indices, result.indices.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func longSceneKeepsExactSlotBoundaries() {
        // 60 s à 120 i/s : (t × 30) n'est pas toujours exact. Pour l'image 492 (t = 492/120 s, début du
        // créneau 123), 492/120 × 30 vaut 122,99999999999999 : sans tolérance elle irait au créneau 122.
        let count = 7200
        let result = FrameSelector.select(
            times: regularTimes(count: count),
            verdicts: verdicts(count: count, flashed: []),
            stats: Array(repeating: plainStats, count: count),
            duration: 60
        )

        #expect(result.indices == Array(stride(from: 0, to: count, by: 4)))
        #expect(result.report == SelectionReport(slots: 1800, heldSlots: 0, fallbackSlots: 0))
    }

    @Test func holdLengthDoesNotDependOnBurstPosition() {
        // Une seconde brûlée (30 créneaux) qui commence à des positions variées : le maintien dure toujours
        // 0,2 × 30 - 1 = 5 créneaux, quelle que soit la position (et l'arrondi des flottants).
        for startSlot in 5..<200 {
            let count = (startSlot + 35) * 4
            let burst = (startSlot * 4)..<((startSlot + 30) * 4)
            let result = FrameSelector.select(
                times: regularTimes(count: count),
                verdicts: verdicts(count: count, flashed: burst),
                stats: (0..<count).map { FrameStats(meanLuma: 0.3 + Double($0 % 7) / 100, saturatedFraction: 0) },
                duration: Double(startSlot + 35) / 30
            )

            #expect(result.report.heldSlots == 5, "burst à partir du créneau \(startSlot)")
            #expect(result.report.fallbackSlots == 25, "burst à partir du créneau \(startSlot)")
            #expect(longestRepeat(in: result.indices) <= 6, "burst à partir du créneau \(startSlot)")
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func holdIsBoundedInSlotsWhateverTheOffsetOfTheLastGoodFrame(offset: Int) {
        // Dans le créneau 29 (images 116 à 119), seule l'image 116 + offset est bonne : plus elle est tardive,
        // plus sa distance en secondes au créneau 35 est courte. Le maintien se compte en créneaux entiers.
        let lastGood = 116 + offset
        let result = selectBurstScene(flashed: Set(116..<lastGood).union(120..<240))

        #expect(result.indices[29] == lastGood)
        #expect(result.indices[30...34].allSatisfy { $0 == lastGood })
        #expect(result.indices[35] != lastGood)
        #expect(result.report == SelectionReport(slots: 90, heldSlots: 5, fallbackSlots: 25))
        #expect(longestRepeat(in: result.indices) <= 6)
    }

    @Test func holdIsBoundedInSlotsWithPeriodicStrobeBeforeBurst() {
        // Stroboscope périodique (première image de chaque créneau brûlée) puis une seconde entièrement brûlée :
        // la dernière bonne image avant la rafale est l'image 117, en position 1 de son créneau.
        let result = selectBurstScene(flashed: Set(stride(from: 0, to: 360, by: 4)).union(120..<240))

        #expect(result.indices[29] == 117)
        #expect(result.indices[30...34].allSatisfy { $0 == 117 })
        #expect(result.report == SelectionReport(slots: 90, heldSlots: 5, fallbackSlots: 25))
        #expect(longestRepeat(in: result.indices) <= 6)
    }

    @Test func holdIsBoundedInSlotsAfterIsolatedFlashBeforeBurst() {
        // Un éclair isolé à l'image 96, puis une rafale d'une seconde dès l'image 100 : la dernière bonne
        // image est la 97 (créneau 24, position 1), répétée sur les créneaux 25 à 29 seulement.
        let result = selectBurstScene(flashed: Set([96]).union(100..<220))

        #expect(result.indices[24] == 97)
        #expect(result.indices[25...29].allSatisfy { $0 == 97 })
        #expect(result.indices[30] != 97)
        #expect(result.report == SelectionReport(slots: 90, heldSlots: 5, fallbackSlots: 25))
        #expect(longestRepeat(in: result.indices) <= 6)
    }

    @Test func irregularTimestamps() {
        // 3 s à 120 i/s, avec des images perdues : un trou de 16 images (de quoi vider plusieurs créneaux
        // entiers), des pertes isolées, et plus rien après 2,5 s (fin de fichier).
        let lost = Set(40..<56).union([3, 17, 90, 91, 130, 200])
        let kept = (0..<300).filter { !lost.contains($0) }
        let times = kept.map { Double($0) / sourceFPS }
        // Quelques éclairs au milieu des images conservées, dont un créneau entier (images 100 à 103).
        let flashed = kept.indices.filter { kept[$0] % 4 == 0 || (100..<104).contains(kept[$0]) }
        let allVerdicts = verdicts(count: kept.count, flashed: flashed)

        let result = FrameSelector.select(
            times: times,
            verdicts: allVerdicts,
            stats: Array(repeating: plainStats, count: kept.count),
            duration: 3
        )

        #expect(result.indices.count == 90)
        #expect(result.indices.allSatisfy { kept.indices.contains($0) })
        #expect(zip(result.indices, result.indices.dropFirst()).allSatisfy { $0 <= $1 })
        // Seuls les créneaux de repli (trou ou fin de fichier longs) peuvent retomber sur une image brûlée.
        let flashedChoices = result.indices.filter { allVerdicts[$0] == .flash }
        #expect(flashedChoices.count <= result.report.fallbackSlots)

        // Numéros d'images sources choisies (les indices portent sur `kept`, qui a des trous).
        let chosen = result.indices.map { kept[$0] }
        // Début : l'image 0 est brûlée, 1 est la première bonne ; dans le créneau 4 la 16 est brûlée, la 17 perdue.
        #expect(chosen[0] == 1)
        #expect(chosen[4] == 18)
        // Autour du trou (images 40 à 55 perdues : créneaux 10 à 13 vides) : la bonne image 37 du créneau 9
        // est maintenue sur les quatre créneaux vides, puis le créneau 14 reprend sa première bonne image.
        #expect(Array(chosen[9...14]) == [37, 37, 37, 37, 37, 57])
        // Créneau 25 (images 100 à 103) entièrement brûlé : on garde la 97 du créneau 24.
        #expect(Array(chosen[24...26]) == [97, 97, 105])
        // Fin de fichier : plus d'image après 2,5 s. La dernière bonne image (297) est maintenue sur les
        // créneaux 75 à 79 puis le choix précédent est prolongé jusqu'au bout.
        #expect(chosen[74...].allSatisfy { $0 == 297 })
        #expect(result.report == SelectionReport(slots: 90, heldSlots: 10, fallbackSlots: 10))
        // Hors prolongement de fin de fichier, aucune image n'est répétée plus de 6 créneaux d'affilée.
        #expect(longestRepeat(in: Array(result.indices[..<75])) <= 6)
    }

    @Test func emptySlotsRepeatPreviousChoice() {
        // Images seulement entre 0 et 1 s ; la seconde suivante n'a plus aucune image.
        let result = FrameSelector.select(
            times: regularTimes(count: 120),
            verdicts: verdicts(count: 120, flashed: []),
            stats: Array(repeating: plainStats, count: 120),
            duration: 2
        )

        #expect(result.indices.count == 60)
        #expect(Array(result.indices[..<30]) == Array(stride(from: 0, to: 120, by: 4)))
        // Créneaux 30 à 34 : maintien de la dernière bonne image (116) tant qu'elle a moins de 0,2 s ;
        // ensuite créneau vide : on garde le choix du créneau précédent.
        #expect(result.indices[30...].allSatisfy { $0 == 116 })
        #expect(result.report == SelectionReport(slots: 60, heldSlots: 5, fallbackSlots: 25))
    }

    @Test func emptyFirstSlotUsesFirstFrame() {
        // Pas d'image avant 0,05 s : le créneau 0 est vide et n'a pas de créneau précédent.
        let times = (6..<126).map { Double($0) / sourceFPS }

        let result = FrameSelector.select(
            times: times,
            verdicts: verdicts(count: times.count, flashed: []),
            stats: Array(repeating: plainStats, count: times.count),
            duration: 1
        )

        #expect(result.indices.count == 30)
        #expect(result.indices.first == 0)
        #expect(zip(result.indices, result.indices.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(result.report.fallbackSlots == 1)
    }

    @Test func slotCountMatchesDuration() {
        // 10,01 s à 120 i/s : 1 201 images, 300,3 créneaux -> 300.
        let count = 1201
        let result = FrameSelector.select(
            times: regularTimes(count: count),
            verdicts: verdicts(count: count, flashed: []),
            stats: Array(repeating: plainStats, count: count),
            duration: 10.01
        )

        #expect(result.indices.count == 300)
        #expect(result.report.slots == 300)
        // L'image 1 200 tombe pile à 10 s : elle appartient au créneau 300, qui n'existe pas.
        #expect(result.indices.last == 1196)
    }

    @Test func emptyInputGivesEmptyResult() {
        let result = FrameSelector.select(times: [], verdicts: [], stats: [], duration: 2)

        #expect(result.indices.isEmpty)
        #expect(result.report == SelectionReport(slots: 0, heldSlots: 0, fallbackSlots: 0))
    }

    @Test func nonPositiveDurationGivesNoSlot() {
        let result = FrameSelector.select(
            times: regularTimes(count: 10),
            verdicts: verdicts(count: 10, flashed: []),
            stats: Array(repeating: plainStats, count: 10),
            duration: 0
        )

        #expect(result.indices.isEmpty)
        #expect(result.report.slots == 0)
    }

    @Test func invalidRateOrDurationGivesNoSlot() {
        // Cadence nulle, négative ou non finie, durée non numérique ou infinie : pas de créneau, pas de plantage.
        // (-2, -30) donnerait 60 créneaux si on ne regardait que le signe du produit.
        let cases: [(duration: Double, fps: Double)] = [
            (2, 0), (2, -30), (-2, -30), (2, .nan), (.nan, 30), (.infinity, 30), (2, .infinity), (-.infinity, -30),
        ]
        for (duration, fps) in cases {
            let result = FrameSelector.select(
                times: regularTimes(count: 10),
                verdicts: verdicts(count: 10, flashed: []),
                stats: Array(repeating: plainStats, count: 10),
                duration: duration,
                outputFPS: fps
            )

            #expect(result.indices.isEmpty, "duration \(duration), fps \(fps)")
            #expect(result.report == SelectionReport(slots: 0, heldSlots: 0, fallbackSlots: 0), "duration \(duration), fps \(fps)")
        }
    }

    @Test func absurdSlotCountGivesNoSlot() {
        // 3·10¹³ créneaux : aucune vidéo réelle, et allouer le tableau de candidats ferait tomber le processus.
        let result = FrameSelector.select(
            times: regularTimes(count: 10),
            verdicts: verdicts(count: 10, flashed: []),
            stats: Array(repeating: plainStats, count: 10),
            duration: 1e12
        )

        #expect(result.indices.isEmpty)
        #expect(result.report == SelectionReport(slots: 0, heldSlots: 0, fallbackSlots: 0))
    }

    @Test func degenerateMaxHoldIsSafe() {
        // Créneaux 5 à 7 entièrement brûlés (voir shortGapHoldsLastGood) : un maintien nul, négatif ou non
        // numérique ne répète rien, un maintien infini répète sur les trois créneaux, sans plantage.
        let cases: [(maxHold: Double, held: Int)] = [(0, 0), (-1, 0), (.nan, 0), (.infinity, 3)]
        for (maxHold, held) in cases {
            let result = FrameSelector.select(
                times: regularTimes(count: 240),
                verdicts: verdicts(count: 240, flashed: 20..<32),
                stats: Array(repeating: plainStats, count: 240),
                duration: 2,
                maxHoldSeconds: maxHold
            )

            #expect(result.indices.count == 60, "maxHold \(maxHold)")
            #expect(result.report.heldSlots == held, "maxHold \(maxHold)")
            #expect(result.report.fallbackSlots == 3 - held, "maxHold \(maxHold)")
        }
    }
}

// MARK: - Plan des créneaux (interpolation)

/// Tolérance sur les phases calculées à la main.
private let phaseTolerance = 1e-9

/// Images sources qu'un créneau planifié référence.
private func referencedFrames(_ slot: SlotPlan) -> [Int] {
    switch slot {
    case .source(let index), .hold(let index), .fallback(let index): [index]
    case .interpolate(let from, let to, _): [from, to]
    }
}

/// Image source du créneau quand il n'interpole pas (`nil` pour une interpolation).
private func singleFrame(_ slot: SlotPlan) -> Int? {
    switch slot {
    case .source(let index), .hold(let index), .fallback(let index): index
    case .interpolate: nil
    }
}

/// Nombre de créneaux de chaque sorte.
private func counts(of slots: [SlotPlan]) -> (source: Int, interpolated: Int, held: Int, fallback: Int) {
    var result = (source: 0, interpolated: 0, held: 0, fallback: 0)
    for slot in slots {
        switch slot {
        case .source: result.source += 1
        case .interpolate: result.interpolated += 1
        case .hold: result.held += 1
        case .fallback: result.fallback += 1
        }
    }
    return result
}

/// Plan sur 3 s à 120 i/s (360 images) où les images `flashed` sont brûlées ; les lumas varient d'une image
/// à l'autre.
private func planScene(
    flashed: some Sequence<Int>,
    maxInterpolationGap: Double = 0.35,
    interpolationAvailable: Bool = true
) -> (slots: [SlotPlan], report: SelectionReport) {
    let count = 360
    return FrameSelector.plan(
        times: regularTimes(count: count),
        verdicts: verdicts(count: count, flashed: flashed),
        stats: (0..<count).map { FrameStats(meanLuma: 0.3 + Double(($0 * 37) % 11) / 100, saturatedFraction: 0) },
        duration: 3,
        maxInterpolationGap: maxInterpolationGap,
        interpolationAvailable: interpolationAvailable
    )
}

/// Stroboscope à 5 Hz, allumé la moitié du temps, sur 3 s à 120 i/s : période de 24 images, dont les images
/// 8 à 19 sont brûlées. Chaque période laisse donc trois créneaux entiers brûlés (2 à 4 modulo 6), entre la
/// bonne image 7 et la bonne image 20 de la période.
private let strobeFlashed = (0..<360).filter { (8..<20).contains($0 % 24) }

/// Générateur pseudo-aléatoire déterministe (SplitMix64) : les scènes aléatoires sont reproductibles.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Scène de 5 s à 120 i/s avec des périodes brûlées de 1 à 70 images, des images perdues isolées et des
/// trous de 1 à 20 images (créneaux vides).
private func randomScene(seed: UInt64) -> (times: [Double], verdicts: [FrameVerdict], stats: [FrameStats]) {
    var generator = SplitMix64(state: seed)
    var times: [Double] = []
    var verdicts: [FrameVerdict] = []
    var stats: [FrameStats] = []
    var flashLeft = 0
    var lostLeft = 0
    for frame in 0..<600 {
        if flashLeft == 0, Int.random(in: 0..<100, using: &generator) < 4 {
            flashLeft = Int.random(in: 1...70, using: &generator)
        }
        if lostLeft == 0, Int.random(in: 0..<100, using: &generator) < 1 {
            lostLeft = Int.random(in: 1...20, using: &generator)
        }
        let isFlash = flashLeft > 0
        flashLeft = max(0, flashLeft - 1)
        let isLost = lostLeft > 0 || Int.random(in: 0..<100, using: &generator) < 3
        lostLeft = max(0, lostLeft - 1)
        if isLost { continue }
        times.append(Double(frame) / sourceFPS)
        verdicts.append(isFlash ? .flash : .good)
        stats.append(FrameStats(meanLuma: Double.random(in: 0.1...0.9, using: &generator), saturatedFraction: 0))
    }
    return (times, verdicts, stats)
}

@Suite("FrameSelector.plan")
struct SlotPlanTests {
    @Test func fiveHertzStrobeIsBridgedByInterpolation() {
        let result = planScene(flashed: strobeFlashed)
        let allVerdicts = verdicts(count: 360, flashed: strobeFlashed)

        #expect(result.slots.count == 90)
        // Aucun créneau ne référence une image brûlée, ni comme source ni comme extrémité d'interpolation.
        #expect(result.slots.allSatisfy { slot in referencedFrames(slot).allSatisfy { allVerdicts[$0] == .good } })

        // 15 périodes de 6 créneaux : 3 créneaux avec une bonne image, puis 3 créneaux interpolés entre les
        // images 24c + 7 et 24c + 20, aux phases 1/13, 5/13 et 9/13.
        for period in 0..<15 {
            let base = 6 * period
            #expect(result.slots[base] == .source(24 * period))
            #expect(result.slots[base + 1] == .source(24 * period + 4))
            #expect(result.slots[base + 5] == .source(24 * period + 20))

            var phases: [Double] = []
            for slot in result.slots[(base + 2)...(base + 4)] {
                guard case .interpolate(let from, let to, let phase) = slot else {
                    Issue.record("créneau de la période \(period) non interpolé : \(slot)")
                    continue
                }
                #expect(from == 24 * period + 7)
                #expect(to == 24 * period + 20)
                phases.append(phase)
            }
            // Phases strictement entre 0 et 1, croissantes dans le trou.
            #expect(phases.count == 3)
            #expect(phases.allSatisfy { $0 > 0 && $0 < 1 })
            #expect(zip(phases, phases.dropFirst()).allSatisfy { $0 < $1 })
            for (phase, expected) in zip(phases, [1.0 / 13, 5.0 / 13, 9.0 / 13]) {
                #expect(abs(phase - expected) < phaseTolerance)
            }
        }
        #expect(result.report == SelectionReport(slots: 90, heldSlots: 0, fallbackSlots: 0, interpolatedSlots: 45))
    }

    @Test func withoutInterpolationThePlanIsTheV1Selection() {
        let scenes: [(name: String, flashed: Set<Int>)] = [
            ("stroboscope 5 Hz", Set(strobeFlashed)),
            ("rafale d'une seconde", Set(120..<240)),
            ("rafale de 0,5 s", Set(120..<180)),
            ("stroboscope périodique puis rafale", Set(stride(from: 0, to: 360, by: 4)).union(120..<240)),
            ("éclair isolé puis rafale", Set([96]).union(100..<220)),
            ("aucun éclair", []),
        ]
        for scene in scenes {
            let v1 = selectBurstScene(flashed: scene.flashed)
            let plan = planScene(flashed: scene.flashed, interpolationAvailable: false)

            #expect(plan.slots.map(singleFrame) == v1.indices.map { Optional($0) }, "\(scene.name)")
            #expect(plan.report == v1.report, "\(scene.name)")
            #expect(plan.report.interpolatedSlots == 0, "\(scene.name)")
        }
    }

    @Test func gapLongerThanTheLimitKeepsTheV1Behaviour() {
        // Images 120 à 179 brûlées : 0,5 s sans bonne image (de 119 à 180, soit 0,508 s) > 0,35 s.
        let flashed = Set(120..<180)
        let result = planScene(flashed: flashed)

        // Créneaux 30 à 44 : cinq maintiens de la dernière bonne image du créneau 29 (116), puis dix replis.
        #expect(result.slots[30...34].allSatisfy { $0 == .hold(116) })
        #expect(result.slots[35...44].allSatisfy { if case .fallback = $0 { true } else { false } })
        #expect(result.slots.allSatisfy { if case .interpolate = $0 { false } else { true } })
        #expect(result.report == SelectionReport(slots: 90, heldSlots: 5, fallbackSlots: 10))
        #expect(result.slots.map(singleFrame) == selectBurstScene(flashed: flashed).indices.map { Optional($0) })
    }

    @Test func gapAtTheLimitIsInterpolatedAndJustAboveIsNot() {
        // Images 11 à 51 brûlées : la dernière bonne image avant les créneaux vides 3 à 12 est la 10 (créneau 2,
        // où la première bonne image, la 8, est la source), la première après est la 52. 52/120 − 10/120 vaut
        // 0,35000000000000003 en flottant : la limite de 0,35 s est acceptée avec une tolérance.
        let atLimit = planScene(flashed: 11..<52)

        #expect(atLimit.slots[2] == .source(8))
        for slot in 3...12 {
            guard case .interpolate(let from, let to, let phase) = atLimit.slots[slot] else {
                Issue.record("créneau \(slot) non interpolé : \(atLimit.slots[slot])")
                continue
            }
            #expect(from == 10)
            #expect(to == 52)
            #expect(abs(phase - Double(4 * slot - 10) / 42) < phaseTolerance)
        }
        #expect(atLimit.slots[13] == .source(52))
        #expect(atLimit.report == SelectionReport(slots: 90, heldSlots: 0, fallbackSlots: 0, interpolatedSlots: 10))

        // Une image de plus brûlée : 43/120 s > 0,35 s, repli sur les règles V1 (cinq maintiens puis cinq replis).
        let aboveLimit = planScene(flashed: 11..<53)
        #expect(aboveLimit.slots[3...7].allSatisfy { $0 == .hold(8) })
        #expect(aboveLimit.slots[8...12].allSatisfy { if case .fallback = $0 { true } else { false } })
        #expect(aboveLimit.report == SelectionReport(slots: 90, heldSlots: 5, fallbackSlots: 5))
    }

    @Test func raisingTheLimitInterpolatesTheLongGap() {
        // La même rafale de 0,5 s, avec une limite de 0,6 s : tous ses créneaux sont interpolés entre 119 et 180.
        let result = planScene(flashed: 120..<180, maxInterpolationGap: 0.6)

        #expect(result.report == SelectionReport(slots: 90, heldSlots: 0, fallbackSlots: 0, interpolatedSlots: 15))
        for slot in 30...44 {
            guard case .interpolate(let from, let to, let phase) = result.slots[slot] else {
                Issue.record("créneau \(slot) non interpolé : \(result.slots[slot])")
                continue
            }
            #expect(from == 119)
            #expect(to == 180)
            #expect(abs(phase - Double(4 * slot - 119) / 61) < phaseTolerance)
        }
    }

    @Test func phaseIsClampedAwayFromTheSourceFrames() {
        // 1 000 créneaux par seconde : deux bonnes images à 0 s et 2 s, 1 999 créneaux vides entre elles.
        // Le premier créneau serait à la phase 0,0005 et le dernier à 0,9995 : bornées à 0,001 et 0,999.
        let result = FrameSelector.plan(
            times: [0, 2],
            verdicts: [.good, .good],
            stats: [plainStats, plainStats],
            duration: 2.001,
            outputFPS: 1000,
            maxInterpolationGap: 5,
            interpolationAvailable: true
        )

        #expect(result.slots.count == 2001)
        #expect(result.slots.first == .source(0))
        #expect(result.slots.last == .source(1))
        #expect(result.slots[1] == .interpolate(from: 0, to: 1, phase: 0.001))
        #expect(result.slots[1999] == .interpolate(from: 0, to: 1, phase: 0.999))
        #expect(result.slots[1000] == .interpolate(from: 0, to: 1, phase: 0.5))
        #expect(result.report == SelectionReport(slots: 2001, heldSlots: 0, fallbackSlots: 0, interpolatedSlots: 1999))
    }

    @Test func interpolationBridgesLostFrames() {
        // Images 40 à 55 perdues (créneaux 10 à 13 sans aucune image) : on interpole entre l'image 39 et la 56
        // (indices 39 et 40 des tableaux) au lieu de répéter l'image 36.
        let lost = Set(40..<56)
        let kept = (0..<120).filter { !lost.contains($0) }

        let result = FrameSelector.plan(
            times: kept.map { Double($0) / sourceFPS },
            verdicts: verdicts(count: kept.count, flashed: []),
            stats: Array(repeating: plainStats, count: kept.count),
            duration: 1,
            interpolationAvailable: true
        )

        #expect(result.slots[9] == .source(36))
        for (slot, expectedPhase) in zip(10...13, [1.0 / 17, 5.0 / 17, 9.0 / 17, 13.0 / 17]) {
            guard case .interpolate(let from, let to, let phase) = result.slots[slot] else {
                Issue.record("créneau \(slot) non interpolé : \(result.slots[slot])")
                continue
            }
            #expect(from == 39)
            #expect(to == 40)
            #expect(abs(phase - expectedPhase) < phaseTolerance)
        }
        #expect(result.slots[14] == .source(40))
        #expect(result.report == SelectionReport(slots: 30, heldSlots: 0, fallbackSlots: 0, interpolatedSlots: 4))
    }

    @Test func framesBeyondTheDurationAreNotInterpolationEnds() {
        // Une bonne image à 0,1 s et la suivante à 0,45 s (créneaux 4 à 12 vides) sont à 0,35 s : dans la limite.
        // L'image à 0,5 s est hors des 15 créneaux : le créneau 14, sans bonne image, ne l'utilise pas comme
        // arrivée d'une interpolation et répète l'image à 0,45 s.
        let times = [0, 0.04, 0.07, 0.1, 0.45, 0.5]
        let result = FrameSelector.plan(
            times: times,
            verdicts: Array(repeating: .good, count: times.count),
            stats: Array(repeating: plainStats, count: times.count),
            duration: 0.5,
            interpolationAvailable: true
        )

        #expect(result.slots.count == 15)
        #expect(result.slots[0...3] == [.source(0), .source(1), .source(2), .source(3)])
        #expect(result.slots[4...12].allSatisfy { if case .interpolate(3, 4, _) = $0 { true } else { false } })
        #expect(result.slots[13] == .source(4))
        // Créneau 14 : plus de bonne image après lui, on répète la dernière.
        #expect(result.slots[14] == .hold(4))
        #expect(result.report == SelectionReport(slots: 15, heldSlots: 1, fallbackSlots: 0, interpolatedSlots: 9))
    }

    @Test func leadingAndTrailingSlotsHoldTheNearestGoodFrameWithinTheLimit() {
        // Images 0 à 19 brûlées (créneaux 0 à 4 avant la première bonne image) et 300 à 359 brûlées (créneaux
        // 75 à 89 après la dernière) : pas de bonne image de part et d'autre, donc pas d'interpolation.
        let result = planScene(flashed: Set(0..<20).union(300..<360))

        // Début : la première bonne image (20, à 0,167 s) est à moins de 0,35 s de chaque créneau : elle est
        // montrée dès le début, au lieu d'une image brûlée.
        #expect(result.slots[0..<5].allSatisfy { $0 == .hold(20) })
        #expect(result.slots[5] == .source(20))
        // Fin, symétrique : la dernière bonne image choisie (296, à 2,467 s, créneau 74) est répétée tant que le
        // créneau commence à moins de 0,35 s d'elle (créneaux 75 à 84, jusqu'à 2,8 s), puis repli.
        #expect(result.slots[74] == .source(296))
        #expect(result.slots[75...84].allSatisfy { $0 == .hold(296) })
        #expect(result.slots[85...89].allSatisfy { if case .fallback = $0 { true } else { false } })
        #expect(result.report == SelectionReport(slots: 90, heldSlots: 15, fallbackSlots: 5))

        // Sans interpolation (V1) : repli au début, cinq maintiens puis repli à la fin.
        let v1 = planScene(flashed: Set(0..<20).union(300..<360), interpolationAvailable: false)
        #expect(v1.slots[0..<5].allSatisfy { if case .fallback = $0 { true } else { false } })
        #expect(v1.slots[75...79].allSatisfy { $0 == .hold(296) })
        #expect(v1.slots[80...89].allSatisfy { if case .fallback = $0 { true } else { false } })
    }

    @Test func lightStillOnAtTheEndShowsTheLastGoodFrame() {
        // Lumière allumée sur les 0,25 dernières secondes (images 330 à 359) : la vidéo finit sur la dernière
        // bonne image (328, créneau 82) au lieu d'images éclairées, quel que soit le maintien de la V1.
        let result = planScene(flashed: 330..<360)

        #expect(result.slots[82] == .source(328))
        #expect(result.slots[83...89].allSatisfy { $0 == .hold(328) })
        #expect(result.report == SelectionReport(slots: 90, heldSlots: 7, fallbackSlots: 0))

        // La V1 (`select`) ne change pas : cinq maintiens (l'image sert six créneaux), puis repli.
        let v1 = selectBurstScene(flashed: 330..<360)
        #expect(v1.indices[83...87].allSatisfy { $0 == 328 })
        #expect(v1.report == SelectionReport(slots: 90, heldSlots: 5, fallbackSlots: 2))
    }

    @Test func trailingHoldNeverReadsBackwards() {
        // Maintien de la V1 plus long que la limite (0,5 s contre 0,1 s) : après le maintien de fin, les règles
        // de la V1 répètent la même image, jamais une plus ancienne.
        let count = 360
        let result = FrameSelector.plan(
            times: regularTimes(count: count),
            verdicts: verdicts(count: count, flashed: 300..<360),
            stats: Array(repeating: plainStats, count: count),
            duration: 3,
            maxHoldSeconds: 0.5,
            maxInterpolationGap: 0.1,
            interpolationAvailable: true
        )

        let frames = result.slots.compactMap(singleFrame)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0 <= $1 })
        // Maintien de fin (créneaux 75 à 77, à 0,1 s au plus), puis de la V1 (jusqu'à 15 créneaux), puis repli.
        #expect(result.slots[75...88].allSatisfy { $0 == .hold(296) })
        #expect(result.slots[89] == .fallback(356))
    }

    @Test func interpolatedPhaseFollowsTheRemovedFrameOfTheSlot() {
        // 100 i/s : un créneau de sortie (1/30 s) contient 3 ou 4 images, rangées à une demi-image près (une image
        // va au créneau qui commence au plus 5 ms après elle). Images 20 à 39 brûlées : créneaux 6 à 11 recréés
        // entre la bonne image 19 (0,19 s) et la 40 (0,40 s). Chaque créneau recréé prend la place de la première
        // image retirée du créneau (20, 23, 27, 30, 33, 37) : sa phase est celle de cette image, comme un créneau
        // source montre sa première image, et non celle du début du créneau.
        let times = (0..<100).map { Double($0) / 100 }
        let result = FrameSelector.plan(
            times: times,
            verdicts: verdicts(count: 100, flashed: 20..<40),
            stats: Array(repeating: plainStats, count: 100),
            duration: 1,
            interpolationAvailable: true
        )

        #expect(result.slots[5] == .source(17))
        #expect(result.slots[12] == .source(40))
        for (slot, removed) in zip(6...11, [20, 23, 27, 30, 33, 37]) {
            guard case .interpolate(let from, let to, let phase) = result.slots[slot] else {
                Issue.record("créneau \(slot) non interpolé : \(result.slots[slot])")
                continue
            }
            #expect(from == 19)
            #expect(to == 40)
            #expect(abs(phase - Double(removed - 19) / 21) < phaseTolerance, "créneau \(slot)")
        }
        #expect(result.report == SelectionReport(slots: 30, heldSlots: 0, fallbackSlots: 0, interpolatedSlots: 6))
    }

    @Test func longLeadingRunHoldsOnlyWithinTheLimit() {
        // Images 0 à 59 brûlées : la première bonne image (60) est à 0,5 s. Les créneaux qui commencent à
        // 0,15 s ou plus tard (5 à 14) sont à 0,35 s au plus d'elle et la montrent ; les créneaux 0 à 4 gardent
        // le repli de la V1.
        let result = planScene(flashed: 0..<60)

        #expect(result.slots[0..<5].allSatisfy { if case .fallback = $0 { true } else { false } })
        #expect(result.slots[5..<15].allSatisfy { $0 == .hold(60) })
        #expect(result.slots[15] == .source(60))
        #expect(result.report == SelectionReport(slots: 90, heldSlots: 10, fallbackSlots: 5))
    }

    @Test func slotWithAGoodFrameIsNeverInterpolated() {
        // Les images 12 et 13 sont brûlées mais pas les 14 et 15 : le créneau 3 prend la première bonne image
        // (14) ; un éclair isolé ne déclenche aucune interpolation.
        let result = planScene(flashed: [12, 13])

        #expect(result.slots[3] == .source(14))
        #expect(result.report == SelectionReport(slots: 90, heldSlots: 0, fallbackSlots: 0))
    }

    @Test func degenerateMaxInterpolationGapIsSafe() {
        // Une limite nulle, négative ou non numérique n'interpole jamais (comportement V1) ; une limite infinie
        // interpole tous les trous.
        let cases: [(gap: Double, interpolated: Int)] = [(0, 0), (-1, 0), (.nan, 0), (.infinity, 45)]
        for (gap, interpolated) in cases {
            let result = planScene(flashed: strobeFlashed, maxInterpolationGap: gap)

            #expect(result.slots.count == 90, "limite \(gap)")
            #expect(result.report.interpolatedSlots == interpolated, "limite \(gap)")
            if interpolated == 0 {
                #expect(result.report == planScene(flashed: strobeFlashed, interpolationAvailable: false).report)
            }
        }
    }

    @Test func emptyOrInvalidInputGivesNoSlot() {
        let empty = FrameSelector.plan(
            times: [], verdicts: [], stats: [], duration: 2, interpolationAvailable: true
        )
        #expect(empty.slots.isEmpty)
        #expect(empty.report == SelectionReport(slots: 0, heldSlots: 0, fallbackSlots: 0))

        let cases: [(duration: Double, fps: Double)] = [(0, 30), (-2, 30), (2, 0), (2, -30), (-2, -30), (.nan, 30), (2, .nan), (.infinity, 30), (1e12, 30)]
        for (duration, fps) in cases {
            let result = FrameSelector.plan(
                times: regularTimes(count: 10),
                verdicts: verdicts(count: 10, flashed: []),
                stats: Array(repeating: plainStats, count: 10),
                duration: duration,
                outputFPS: fps,
                interpolationAvailable: true
            )
            #expect(result.slots.isEmpty, "duration \(duration), fps \(fps)")
            #expect(result.report == SelectionReport(slots: 0, heldSlots: 0, fallbackSlots: 0), "duration \(duration), fps \(fps)")
        }
    }

    @Test func reportCountsMatchThePlan() {
        for flashed in [Set(strobeFlashed), Set(120..<180), Set(120..<240), Set<Int>(), Set(0..<20).union(300..<360)] {
            let result = planScene(flashed: flashed)
            let tally = counts(of: result.slots)

            #expect(result.report.slots == result.slots.count)
            #expect(result.report.slots == tally.source + tally.interpolated + tally.held + tally.fallback)
            #expect(result.report.sourceSlots == tally.source)
            #expect(result.report.interpolatedSlots == tally.interpolated)
            #expect(result.report.heldSlots == tally.held)
            #expect(result.report.fallbackSlots == tally.fallback)
        }
    }

    @Test(arguments: 0..<60)
    func randomScenesRespectThePlanInvariants(seed: Int) {
        let scene = randomScene(seed: UInt64(seed))
        let duration = 5.0
        let maxGap = 0.35
        let plan = FrameSelector.plan(
            times: scene.times, verdicts: scene.verdicts, stats: scene.stats, duration: duration,
            interpolationAvailable: true
        )
        let v1 = FrameSelector.select(
            times: scene.times, verdicts: scene.verdicts, stats: scene.stats, duration: duration
        )
        let label = "scène \(seed)"

        #expect(plan.slots.count == 150, "\(label)")

        // Bilan cohérent avec le plan.
        let tally = counts(of: plan.slots)
        #expect(plan.report.slots == tally.source + tally.interpolated + tally.held + tally.fallback, "\(label)")
        #expect(plan.report.interpolatedSlots == tally.interpolated, "\(label)")
        #expect(plan.report.heldSlots == tally.held, "\(label)")
        #expect(plan.report.fallbackSlots == tally.fallback, "\(label)")

        // Jamais de retour en arrière : la plus petite et la plus grande image référencées ne reculent pas.
        let ranges = plan.slots.map { slot in
            let frames = referencedFrames(slot)
            return (low: frames.min() ?? 0, high: frames.max() ?? 0)
        }
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(previous.low <= next.low, "\(label)")
            #expect(previous.high <= next.high, "\(label)")
        }

        /// Première image (tous verdicts confondus) rangée dans le créneau : les horodatages sont des multiples
        /// de 1/120 s, le créneau k reçoit les images 4k à 4k + 3.
        func firstFrame(inSlot slot: Int) -> Int? {
            scene.times.indices.first { Int((scene.times[$0] * sourceFPS).rounded()) / 4 == slot }
        }
        let isSource = { (entry: SlotPlan) in if case .source = entry { true } else { false } }

        for (slot, entry) in plan.slots.enumerated() {
            let start = Double(slot) / 30
            if case .interpolate(let from, let to, let phase) = entry {
                // Extrémités : dernière bonne image avant le créneau, première après, sans bonne image entre.
                #expect(scene.verdicts[from] == .good && scene.verdicts[to] == .good, "\(label), créneau \(slot)")
                #expect(scene.times[from] < start, "\(label), créneau \(slot)")
                #expect(scene.times[to] >= start, "\(label), créneau \(slot)")
                #expect((from + 1..<to).allSatisfy { scene.verdicts[$0] == .flash }, "\(label), créneau \(slot)")
                let span = scene.times[to] - scene.times[from]
                #expect(span <= maxGap + 1e-6, "\(label), créneau \(slot)")
                // Phase à l'horodatage de l'image retirée que le créneau aurait montrée (sa première), ou à son
                // début s'il est vide.
                let shown = firstFrame(inSlot: slot).map { scene.times[$0] } ?? start
                let expected = min(max((shown - scene.times[from]) / span, 0.001), 0.999)
                #expect(abs(phase - expected) < phaseTolerance, "\(label), créneau \(slot)")
            } else if case .hold(let first) = entry, !plan.slots[..<slot].contains(where: isSource) {
                // Avant la première bonne image : on montre la première bonne image, proche.
                let firstGood = scene.verdicts.firstIndex(of: .good)
                #expect(first == firstGood, "\(label), créneau \(slot)")
                #expect(scene.times[first] - start <= maxGap + 1e-6, "\(label), créneau \(slot)")
            } else if case .hold(let last) = entry, !plan.slots[slot...].contains(where: isSource) {
                // Après la dernière bonne image : on répète la dernière bonne image choisie, proche.
                let lastSource = plan.slots[..<slot].last(where: isSource).flatMap(singleFrame)
                #expect(last == lastSource, "\(label), créneau \(slot)")
                #expect(start - scene.times[last] <= maxGap + 1e-6 || last == v1.indices[slot], "\(label), créneau \(slot)")
            } else if case .fallback(let choice) = entry, firstFrame(inSlot: slot) == nil {
                // Créneau vide : le choix du créneau précédent est prolongé (après un maintien de fin, ce n'est
                // plus celui de la V1).
                let previous = slot > 0 ? referencedFrames(plan.slots[slot - 1]).max() : 0
                #expect(choice == previous, "\(label), créneau \(slot)")
            } else {
                // Ailleurs, hors interpolation, le plan est exactement celui de la V1.
                #expect(singleFrame(entry) == v1.indices[slot], "\(label), créneau \(slot)")
            }
        }
    }
}

// MARK: - Rangement dans les créneaux : horodatages réels

/// Horodatages de `count` images à `fps`, chacun décalé au hasard d'au plus `jitter` secondes, en avance ou en
/// retard, comme ceux d'une caméra (reproductible : `seed`).
private func jitteredTimes(count: Int, fps: Double, jitter: Double, seed: UInt64) -> [Double] {
    var generator = SplitMix64(state: seed)
    return (0..<count).map { Double($0) / fps + Double.random(in: -jitter...jitter, using: &generator) }
}

/// Gigue des horodatages de capture dans ces tests : ±20 µs.
private let captureJitter = 20e-6

@Suite("FrameSelector, rangement dans les créneaux")
struct SlotAssignmentTests {
    /// Sans lumière, à 120, 60 ou 30 i/s avec une gigue de ±20 µs : chaque créneau montre sa première image
    /// (une image sur 4, 2 ou 1), sans trou, sans doublon, sans interpolation ni maintien. À 30 i/s, sans
    /// tolérance, une image en avance de 20 µs tombait dans le créneau précédent et laissait le sien vide.
    @Test(arguments: [120.0, 60.0, 30.0])
    func jitteredCaptureFillsEverySlotWithItsOwnFrame(fps: Double) {
        let stride = Int(fps / 30)
        for seed in 0..<20 {
            let times = jitteredTimes(count: Int(5 * fps), fps: fps, jitter: captureJitter, seed: UInt64(seed))
            for interpolation in [true, false] {
                let result = FrameSelector.plan(
                    times: times,
                    verdicts: verdicts(count: times.count, flashed: []),
                    stats: Array(repeating: plainStats, count: times.count),
                    duration: 5,
                    interpolationAvailable: interpolation
                )

                let label = "\(fps) i/s, tirage \(seed), interpolation \(interpolation)"
                #expect(result.slots == (0..<150).map { .source($0 * stride) }, "\(label)")
                #expect(result.report == SelectionReport(slots: 150, heldSlots: 0, fallbackSlots: 0), "\(label)")
            }
        }
    }

    /// Cadences sans rapport entier avec la sortie (100 → 30 et 60 → 24 i/s), avec gigue : chaque créneau a
    /// une image source, jamais deux fois la même, à moins d'une demi-image (plus la gigue) de son début.
    @Test(arguments: [(source: 100.0, output: 30.0), (source: 60.0, output: 24.0)])
    func nonIntegerRatioFillsEverySlotOnce(source: Double, output: Double) {
        for seed in 0..<20 {
            let times = jitteredTimes(count: Int(5 * source), fps: source, jitter: captureJitter, seed: UInt64(seed))
            let result = FrameSelector.plan(
                times: times,
                verdicts: verdicts(count: times.count, flashed: []),
                stats: Array(repeating: plainStats, count: times.count),
                duration: 5,
                outputFPS: output,
                interpolationAvailable: true
            )

            let label = "\(source) → \(output) i/s, tirage \(seed)"
            let slotCount = Int(5 * output)
            #expect(result.report == SelectionReport(slots: slotCount, heldSlots: 0, fallbackSlots: 0), "\(label)")
            let frames = result.slots.compactMap { slot -> Int? in if case .source(let index) = slot { index } else { nil } }
            #expect(frames.count == slotCount, "\(label) : créneaux sans image source")
            #expect(zip(frames, frames.dropFirst()).allSatisfy { $0 < $1 }, "\(label) : doublon ou recul")
            for (slot, frame) in frames.enumerated() {
                let offset = times[frame] - Double(slot) / output
                #expect(abs(offset) <= 0.5 / source + 2 * captureJitter, "\(label), créneau \(slot) : \(offset) s")
            }
        }
    }

    /// La V1 (`select`) range les images de la même façon.
    @Test func selectUsesTheSameAssignment() {
        let times = jitteredTimes(count: 150, fps: 30, jitter: captureJitter, seed: 7)
        let result = FrameSelector.select(
            times: times,
            verdicts: verdicts(count: 150, flashed: []),
            stats: Array(repeating: plainStats, count: 150),
            duration: 5
        )

        #expect(result.indices == Array(0..<150))
        #expect(result.report == SelectionReport(slots: 150, heldSlots: 0, fallbackSlots: 0))
    }
}
