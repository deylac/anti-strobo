import Testing
@testable import StrobeCore

// MARK: - Aides

/// Les cadences que l'iPhone sait filmer dans ces tests.
private let allCadences: [Double] = [120, 60, 30]

/// Un strobe mesuré dont le moment sans lumière le plus court dure `gap` secondes.
private func strobe(gap: Double) -> StrobeRhythm {
    StrobeRhythm(hasStrobe: true, shortestDarkGap: gap, lightFraction: 0.5)
}

/// Aucun strobe vu (donc aucun moment sans lumière mesuré).
private let noStrobe = StrobeRhythm(hasStrobe: false, shortestDarkGap: .infinity, lightFraction: 0)

/// La cadence choisie pour une scène trop sombre (`reachedMaximum` vrai) sauf mention contraire.
private func next(
    from current: Double,
    among available: [Double] = allCadences,
    reachedMaximum: Bool = true,
    rhythm: StrobeRhythm
) -> Double? {
    CadencePlanner.nextCadence(
        current: current,
        available: available,
        reachedMaximum: reachedMaximum,
        rhythm: rhythm
    )
}

// MARK: - Tests

@Suite("CadencePlanner")
struct CadencePlannerTests {
    @Test func halfDutyStrobeAt5HzDropsTo60ButNotTo30() {
        // Moments sans lumière de 0,1 s : 6 images à 60 i/s (assez : 6 ≥ 4 + 1), 3 à 30 i/s (trop peu).
        #expect(next(from: 120, rhythm: strobe(gap: 0.1)) == 60)
        #expect(next(from: 60, rhythm: strobe(gap: 0.1)) == nil)
    }

    @Test func noStrobeDropsTo60() {
        #expect(next(from: 120, rhythm: noStrobe) == 60)
    }

    @Test func noStrobeNeverGoesBelow60() {
        // Un strobe qui démarrerait pendant l'enregistrement doit rester retirable.
        #expect(next(from: 60, rhythm: noStrobe) == nil)
        #expect(next(from: 120, among: [120, 30], rhythm: noStrobe) == nil)
    }

    @Test func brightSceneStays() {
        #expect(next(from: 120, reachedMaximum: false, rhythm: noStrobe) == nil)
        #expect(next(from: 120, reachedMaximum: false, rhythm: strobe(gap: 1)) == nil)
    }

    @Test func slowStrobeDropsStraightTo30() {
        // 0,2 s × 30 i/s = 6 images par moment sans lumière : la plus basse cadence convient (le plus de lumière).
        #expect(next(from: 120, rhythm: strobe(gap: 0.2)) == 30)
        #expect(next(from: 60, rhythm: strobe(gap: 0.2)) == 30)
    }

    @Test func veryFastStrobeStays() {
        // 0,03 s × 60 i/s = 1,8 image : même 60 i/s ne laisse pas assez d'images.
        #expect(next(from: 120, rhythm: strobe(gap: 0.03)) == nil)
    }

    @Test func strobeDoesNotNeedTheNoStrobeFloor() {
        // Avec un strobe mesuré, seul le nombre d'images par moment sans lumière compte : 30 i/s est permis
        // alors que sans strobe il ne le serait pas.
        #expect(next(from: 60, rhythm: strobe(gap: 0.2)) == 30)
        #expect(next(from: 60, rhythm: noStrobe) == nil)
    }

    @Test func skipsCadencesTheDeviceDoesNotOffer() {
        // Sans 60 i/s : on saute aux cadences permises seulement.
        #expect(next(from: 120, among: [120, 30], rhythm: strobe(gap: 0.2)) == 30)
        #expect(next(from: 120, among: [120, 30], rhythm: strobe(gap: 0.1)) == nil)
        // 0,1 s × 45 i/s = 4,5 images, moins que 4 + 1 : 90 i/s.
        #expect(next(from: 120, among: [120, 90, 45, 30], rhythm: strobe(gap: 0.1)) == 90)
        #expect(next(from: 120, among: [120, 90, 50, 30], rhythm: strobe(gap: 0.1)) == 50)
        #expect(next(from: 120, among: [120, 90, 45, 30], rhythm: noStrobe) == 90)
    }

    @Test func ignoresDuplicatesUnsortedAndHigherOrEqualCadences() {
        let messy: [Double] = [30, 240, 60, 120, 60, 30, 120]
        #expect(next(from: 120, among: messy, rhythm: strobe(gap: 0.1)) == 60)
        #expect(next(from: 120, among: messy, rhythm: strobe(gap: 0.2)) == 30)
        #expect(next(from: 60, among: messy, rhythm: strobe(gap: 0.2)) == 30)
        // Ni la cadence actuelle ni les plus hautes ne sont des candidates.
        #expect(next(from: 30, among: messy, rhythm: strobe(gap: 10)) == nil)
        #expect(next(from: 60, among: messy, rhythm: noStrobe) == nil)
    }

    @Test func nothingToChooseFrom() {
        #expect(next(from: 120, among: [], rhythm: noStrobe) == nil)
        #expect(next(from: 120, among: [120], rhythm: noStrobe) == nil)
        #expect(next(from: 120, among: [240, 120], rhythm: strobe(gap: 1)) == nil)
    }

    @Test func darkGapKeepsOneExtraFrameForThePhase() {
        // Règle V2-R7 : on compte les images propres. Selon la phase du strobe, la première et la dernière image
        // d'un moment sans lumière peuvent être à moitié éclairées ; il en faut donc 4 + 1. Exactement 5 images
        // par moment sans lumière à 30 i/s : permis (borne comprise).
        #expect(next(from: 120, rhythm: strobe(gap: 5.0 / 30)) == 30)
        // 4 images (permis avant la règle) ou un peu moins de 5 : refusé, 60 i/s reste permis.
        #expect(next(from: 120, rhythm: strobe(gap: 4.0 / 30)) == 60)
        #expect(next(from: 120, rhythm: strobe(gap: 4.9 / 30)) == 60)
    }

    @Test func noStrobeFloorIsInclusive() {
        #expect(next(from: 120, among: [120, 60], rhythm: noStrobe) == 60)
        #expect(next(from: 120, among: [120, 59], rhythm: noStrobe) == nil)
    }

    @Test func customThresholds() {
        // Au moins 8 images (plus une) par moment sans lumière : 0,1 s × 60 i/s = 6, refusé ; 0,2 s × 60 = 12
        // mais 0,2 s × 30 = 6, refusé aussi.
        #expect(CadencePlanner.nextCadence(
            current: 120, available: allCadences, reachedMaximum: true,
            rhythm: strobe(gap: 0.1), minimumFramesPerDarkGap: 8
        ) == nil)
        #expect(CadencePlanner.nextCadence(
            current: 120, available: allCadences, reachedMaximum: true,
            rhythm: strobe(gap: 0.2), minimumFramesPerDarkGap: 8
        ) == 60)
        // Sans strobe, le plancher passe à 30 i/s.
        #expect(CadencePlanner.nextCadence(
            current: 120, available: allCadences, reachedMaximum: true,
            rhythm: noStrobe, minimumWithoutStrobe: 30
        ) == 30)
    }
}
