import Testing
@testable import StrobeCore

// MARK: - Aides

/// Un format 16:9 de la hauteur donnée, sans importance pour le choix hors hauteur et cadence.
private func format(_ index: Int, height: Int, maxFPS: Double) -> CameraFormatInfo {
    CameraFormatInfo(index: index, width: height * 16 / 9, height: height, maxFPS: maxFPS)
}

// MARK: - Tests

@Suite("FormatChooser")
struct FormatChooserTests {
    @Test func prefers1080at120() {
        let formats = [
            format(0, height: 2160, maxFPS: 120),
            format(1, height: 1080, maxFPS: 120),
            format(2, height: 720, maxFPS: 240),
        ]
        let choice = FormatChooser.choose(formats)
        #expect(choice?.index == 1)
        #expect(choice?.fps == 120)
    }

    @Test func fallsBackTo60() {
        let formats = [
            format(0, height: 1080, maxFPS: 60),
            format(1, height: 2160, maxFPS: 30),
        ]
        let choice = FormatChooser.choose(formats)
        #expect(choice?.index == 0)
        #expect(choice?.fps == 60)
    }

    @Test func emptyReturnsNil() {
        #expect(FormatChooser.choose([]) == nil)
    }

    // MARK: Cadence

    @Test func neverUses240EvenWhenOffered() {
        // Un format 1080p240 existe, mais V1 reste à 120 i/s (240 i/s : trop bruité en salle sombre).
        let choice = FormatChooser.choose([format(0, height: 1080, maxFPS: 240)])
        #expect(choice?.index == 0)
        #expect(choice?.fps == 120)
    }

    @Test func takes120EvenInLowerHeightRatherThanFaster60At1080() {
        // Le 120 prime sur la hauteur : 720p120 bat 1080p60.
        let formats = [
            format(0, height: 1080, maxFPS: 60),
            format(1, height: 720, maxFPS: 120),
        ]
        let choice = FormatChooser.choose(formats)
        #expect(choice?.index == 1)
        #expect(choice?.fps == 120)
    }

    @Test func sixtyFallbackReturnsExactly60WhenFormatOffersMore() {
        // 90 i/s disponibles, mais aucun format à 120 : on demande 60, pas 90.
        let choice = FormatChooser.choose([format(0, height: 1080, maxFPS: 90)])
        #expect(choice?.index == 0)
        #expect(choice?.fps == 60)
    }

    @Test func fallsBackTo30WhenNothingReaches60() {
        let formats = [
            format(0, height: 2160, maxFPS: 30),
            format(1, height: 1080, maxFPS: 30),
        ]
        let choice = FormatChooser.choose(formats)
        #expect(choice?.index == 1)
        #expect(choice?.fps == 30)
    }

    @Test func finalFallbackCapsAt30() {
        // Un format à 45 i/s (< 60) ne dépasse pas 30 en dernier recours.
        let choice = FormatChooser.choose([format(0, height: 1080, maxFPS: 45)])
        #expect(choice?.fps == 30)
    }

    @Test func finalFallbackUsesFormatBelow30OnlyIfNothingElse() {
        // Format à 24 i/s : accepté seulement faute d'autre, à sa propre cadence maximale.
        let alone = FormatChooser.choose([format(0, height: 1080, maxFPS: 24)])
        #expect(alone?.index == 0)
        #expect(alone?.fps == 24)

        // Dès qu'un format atteint 30 i/s, il passe devant, même plus petit.
        let withAlternative = FormatChooser.choose([
            format(0, height: 1080, maxFPS: 24),
            format(1, height: 720, maxFPS: 30),
        ])
        #expect(withAlternative?.index == 1)
        #expect(withAlternative?.fps == 30)
    }

    // MARK: Hauteur

    @Test func prefersLargestHeightBelow1080WhenNo1080() {
        let formats = [
            format(0, height: 2160, maxFPS: 120),
            format(1, height: 480, maxFPS: 120),
            format(2, height: 720, maxFPS: 120),
        ]
        // 720 est la plus grande hauteur ≤ 1080 ; elle bat la 4K, même plus grande.
        #expect(FormatChooser.choose(formats)?.index == 2)
    }

    @Test func prefersSmallestHeightAbove1080WhenNothingAtOrBelow() {
        let formats = [
            format(0, height: 2160, maxFPS: 120),
            format(1, height: 1440, maxFPS: 120),
        ]
        #expect(FormatChooser.choose(formats)?.index == 1)
    }

    @Test func heightRuleAlsoAppliesInSixtyFallback() {
        let formats = [
            format(0, height: 2160, maxFPS: 60),
            format(1, height: 720, maxFPS: 60),
            format(2, height: 1080, maxFPS: 60),
        ]
        #expect(FormatChooser.choose(formats)?.index == 2)
    }

    @Test func heightRuleAlsoAppliesInFinalFallback() {
        let formats = [
            format(0, height: 2160, maxFPS: 30),
            format(1, height: 720, maxFPS: 30),
        ]
        #expect(FormatChooser.choose(formats)?.index == 1)
    }

    @Test func formatsBelowTheTargetFPSAreIgnoredWhenOneReachesIt() {
        // Le 1080p60 n'entre pas en lice quand un 120 existe, même à la même hauteur.
        let formats = [
            format(0, height: 1080, maxFPS: 60),
            format(1, height: 1080, maxFPS: 120),
        ]
        let choice = FormatChooser.choose(formats)
        #expect(choice?.index == 1)
        #expect(choice?.fps == 120)
    }

    // MARK: Départage

    @Test func tieGoesToLowestIndex() {
        // Même hauteur, tous deux ≥ 120 i/s : l'indice le plus bas gagne, quel que soit l'ordre de la liste.
        let formats = [
            format(7, height: 1080, maxFPS: 240),
            format(3, height: 1080, maxFPS: 120),
            format(5, height: 1080, maxFPS: 120),
        ]
        #expect(FormatChooser.choose(formats)?.index == 3)
        #expect(FormatChooser.choose(formats.reversed())?.index == 3)
    }

    @Test func prefersWiderFormatAtSameHeight() {
        // Les iPhone listent un 1440×1080 (4:3) avant le 1920×1080 : à hauteur égale, le plus large gagne,
        // même avec un indice plus haut, quel que soit l'ordre de la liste.
        let formats = [
            CameraFormatInfo(index: 0, width: 1440, height: 1080, maxFPS: 120),
            CameraFormatInfo(index: 1, width: 1920, height: 1080, maxFPS: 120),
            CameraFormatInfo(index: 2, width: 1920, height: 1080, maxFPS: 240),
        ]
        #expect(FormatChooser.choose(formats)?.index == 1)
        #expect(FormatChooser.choose(formats.reversed())?.index == 1)
    }

    @Test func returnedIndexIsTheFormatIndexNotTheArrayPosition() {
        let formats = [
            format(40, height: 720, maxFPS: 120),
            format(12, height: 1080, maxFPS: 120),
        ]
        #expect(FormatChooser.choose(formats)?.index == 12)
    }

    // MARK: Formats inutilisables

    @Test func unusableFormatsAreSkipped() {
        let formats = [
            format(0, height: 0, maxFPS: 120),
            format(1, height: 1080, maxFPS: .nan),
            format(2, height: 1080, maxFPS: 0),
            format(3, height: 1080, maxFPS: -30),
            format(4, height: 1080, maxFPS: .infinity),
            format(5, height: 720, maxFPS: 120),
        ]
        let choice = FormatChooser.choose(formats)
        #expect(choice?.index == 5)
        #expect(choice?.fps == 120)
    }

    @Test func onlyUnusableFormatsReturnNil() {
        let formats = [
            format(0, height: 1080, maxFPS: .nan),
            format(1, height: -1, maxFPS: 120),
        ]
        #expect(FormatChooser.choose(formats) == nil)
    }

    // MARK: Cadences permises

    @Test func cadenceStepsAre120Then60Then30() {
        #expect(FormatChooser.cadenceSteps == [120, 60, 30])
    }

    @Test func usualIPhoneRangeAllowsAllCadences() {
        // Un format 1080p120 d'iPhone : une seule plage, de 1 à 120 i/s.
        let ranges = [FrameRateRange(minFPS: 1, maxFPS: 120)]
        #expect(FormatChooser.availableCadences(in: ranges) == [120, 60, 30])
    }

    @Test func boundsAreRounded() {
        // 119,88 et 59,94 i/s comptent comme 120 et 60 ; 29,97 comme 30.
        #expect(FormatChooser.availableCadences(in: [FrameRateRange(minFPS: 1, maxFPS: 119.88)]) == [120, 60, 30])
        #expect(FormatChooser.availableCadences(in: [FrameRateRange(minFPS: 29.97, maxFPS: 59.94)]) == [60, 30])
        // 30,4 s'arrondit à 30 : la plage permet 30 ; 30,6 s'arrondit à 31 : elle ne le permet plus.
        #expect(FormatChooser.availableCadences(in: [FrameRateRange(minFPS: 30.4, maxFPS: 120)]) == [120, 60, 30])
        #expect(FormatChooser.availableCadences(in: [FrameRateRange(minFPS: 30.6, maxFPS: 120)]) == [120, 60])
    }

    @Test func rangeWithoutLowCadencesOffersOnlyTheHighOnes() {
        #expect(FormatChooser.availableCadences(in: [FrameRateRange(minFPS: 60, maxFPS: 240)]) == [120, 60])
        #expect(FormatChooser.availableCadences(in: [FrameRateRange(minFPS: 100, maxFPS: 240)]) == [120])
    }

    @Test func rangeBelow120OffersOnlyTheLowOnes() {
        #expect(FormatChooser.availableCadences(in: [FrameRateRange(minFPS: 1, maxFPS: 60)]) == [60, 30])
        #expect(FormatChooser.availableCadences(in: [FrameRateRange(minFPS: 1, maxFPS: 45)]) == [30])
    }

    @Test func severalRangesAddUpHighestFirst() {
        // Plages disjointes (ou de plusieurs formats de même résolution) : une cadence permise par l'une suffit,
        // et l'ordre reste du plus haut au plus bas, quel que soit l'ordre des plages.
        let ranges = [
            FrameRateRange(minFPS: 100, maxFPS: 120),
            FrameRateRange(minFPS: 1, maxFPS: 30),
        ]
        #expect(FormatChooser.availableCadences(in: ranges) == [120, 30])
        #expect(FormatChooser.availableCadences(in: ranges.reversed()) == [120, 30])
    }

    @Test func noUsableRangeOffersNothing() {
        #expect(FormatChooser.availableCadences(in: []) == [])
        #expect(FormatChooser.availableCadences(in: [FrameRateRange(minFPS: 1, maxFPS: 24)]) == [])
        #expect(FormatChooser.availableCadences(in: [FrameRateRange(minFPS: .nan, maxFPS: 120)]) == [])
        #expect(FormatChooser.availableCadences(in: [FrameRateRange(minFPS: 1, maxFPS: .nan)]) == [])
        // À l'envers : ne permet rien.
        #expect(FormatChooser.availableCadences(in: [FrameRateRange(minFPS: 120, maxFPS: 30)]) == [])
    }

    // MARK: Format d'une nouvelle cadence

    /// Formats 1080p 8 bits de l'iPhone 17 Pro Max de test (relevé du 7 novembre, `-logCameraFormats`), plus un
    /// 1440×1080 plus sensible qui n'a pas la bonne taille.
    private static let iPhoneFormats = [
        CadenceFormat(index: 26, width: 1440, height: 1080, isFullRange: false, frameRates: upTo(60), maxISO: 6000),
        CadenceFormat(index: 28, width: 1920, height: 1080, isFullRange: false, frameRates: upTo(30), maxISO: 5184),
        CadenceFormat(index: 29, width: 1920, height: 1080, isFullRange: true, frameRates: upTo(30), maxISO: 5184),
        CadenceFormat(index: 32, width: 1920, height: 1080, isFullRange: false, frameRates: upTo(60), maxISO: 5184),
        CadenceFormat(index: 33, width: 1920, height: 1080, isFullRange: true, frameRates: upTo(60), maxISO: 5184),
        CadenceFormat(index: 37, width: 1920, height: 1080, isFullRange: true, frameRates: upTo(60), maxISO: 5184),
        CadenceFormat(index: 38, width: 1920, height: 1080, isFullRange: false, frameRates: upTo(120), maxISO: 3456),
        CadenceFormat(index: 39, width: 1920, height: 1080, isFullRange: true, frameRates: upTo(120), maxISO: 3456),
    ]

    /// Une seule plage, de 1 i/s à `fps`, comme sur l'iPhone.
    private static func upTo(_ fps: Double) -> [FrameRateRange] { [FrameRateRange(minFPS: 1, maxFPS: fps)] }

    private static func iPhoneFormat(_ index: Int) -> CadenceFormat {
        iPhoneFormats.first { $0.index == index }!
    }

    @Test func lowerCadenceTakesTheMostSensitiveFormat() {
        // Essai du 7 novembre en pièce noire : à 60 i/s, le format #39 (jusqu'à 120 i/s) plafonne à ISO 3456, les
        // formats 1080p jusqu'à 60 i/s montent à 5184 ; à égalité, la pleine plage puis l'index le plus bas.
        let chosen = FormatChooser.formatForCadence(60, current: Self.iPhoneFormat(39), among: Self.iPhoneFormats)
        #expect(chosen == 33)
    }

    @Test func equallySensitiveCurrentFormatIsKept() {
        // De 60 à 30 i/s depuis le #33 : le #29 (jusqu'à 30 i/s) n'est pas plus sensible, on ne reconfigure pas.
        let chosen = FormatChooser.formatForCadence(30, current: Self.iPhoneFormat(33), among: Self.iPhoneFormats)
        #expect(chosen == 33)
    }

    @Test func backToTheStartingCadenceKeepsTheStartingFormat() {
        let chosen = FormatChooser.formatForCadence(120, current: Self.iPhoneFormat(39), among: Self.iPhoneFormats)
        #expect(chosen == 39)
    }

    @Test func noFormatForTheCadenceGivesNil() {
        let chosen = FormatChooser.formatForCadence(240, current: Self.iPhoneFormat(39), among: Self.iPhoneFormats)
        #expect(chosen == nil)
    }

    @Test func videoRangeIsTakenWhenItIsTheMostSensitive() {
        let formats = [
            CadenceFormat(index: 0, width: 1920, height: 1080, isFullRange: true, frameRates: Self.upTo(120), maxISO: 3456),
            CadenceFormat(index: 1, width: 1920, height: 1080, isFullRange: false, frameRates: Self.upTo(60), maxISO: 5184),
        ]
        #expect(FormatChooser.formatForCadence(60, current: formats[0], among: formats) == 1)
    }

    @Test func rangeAllowsRoundedCadence() {
        let range = FrameRateRange(minFPS: 1, maxFPS: 119.88)
        #expect(range.allows(120))
        #expect(range.allows(119.88))
        #expect(range.allows(1))
        #expect(!range.allows(240))
        #expect(!range.allows(.nan))
    }
}
