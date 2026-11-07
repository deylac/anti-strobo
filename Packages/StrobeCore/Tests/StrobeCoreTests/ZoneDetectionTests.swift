import CoreVideo
import Foundation
import Testing
@testable import StrobeCore

// MARK: - Aides

/// Cadence des scènes de test : 120 images par seconde.
private func time(_ index: Int) -> Double { Double(index) / 120 }

private func timestamps(count: Int) -> [Double] { (0..<count).map(time) }

/// Bruit déterministe dans [-amplitude, +amplitude], différent d'une zone à l'autre.
private func noise(_ index: Int, zone: Int, amplitude: Double) -> Double {
    Double(((index + 31 * zone) * 7919) % 21 - 10) / 10 * amplitude
}

private func byte(_ luma: Double) -> UInt8 { UInt8((min(1, max(0, luma)) * 255).rounded()) }

/// Luma de fond de chaque zone : de 0,1 (coin sombre) à 0,95 (fenêtre en plein jour), répartie sans ordre.
private func background(zone: Int) -> Double { 0.1 + 0.85 * Double((zone * 37) % 64) / 63 }

/// Zone de la petite lampe (colonne 3, rangée 3).
private let lampZone = 27

/// Pièce en plein jour où une petite lampe clignote dans `lampZone` : la luma moyenne de l'image bouge à peine
/// (0,51 → 0,54, rapport 1,06, comme l'essai sur iPhone du 7 novembre), la zone de la lampe passe de 0,3 à 0,9.
private func roomWithLamp(_ index: Int, lit: Bool) -> FrameStats {
    let zones = (0..<64).map { zone in
        zone == lampZone
            ? byte((lit ? 0.9 : 0.3) + noise(index, zone: zone, amplitude: 0.01))
            : byte(background(zone: zone) + noise(index, zone: zone, amplitude: 0.01))
    }
    return FrameStats(meanLuma: lit ? 0.54 : 0.51, saturatedFraction: 0.14, zoneLumas: zones)
}

/// Lampe à 5 Hz allumée la moitié du temps : 12 images éteintes, puis 12 allumées.
private func lampIsLit(_ index: Int) -> Bool { !(index / 12).isMultiple(of: 2) }

private func onlineVerdicts(_ stats: [FrameStats], config: FlashDetectorConfig = .init()) -> [FrameVerdict] {
    var detector = OnlineFlashDetector(config: config)
    return stats.indices.map { detector.classify(stats[$0], at: time($0)) }
}

private extension Array where Element == FrameVerdict {
    var flashIndices: [Int] { indices.filter { self[$0] == .flash } }
}

/// Image 64×64 plein écart dont la luma du pixel (x, y) vaut `luma(x, y)`.
private func makeBuffer(width: Int = 64, height: Int = 64, luma: (Int, Int) -> UInt8) -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &created
    )
    precondition(status == kCVReturnSuccess, "CVPixelBufferCreate a échoué (\(status))")
    let buffer = created!
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    for y in 0..<height {
        for x in 0..<width { plane[y * rowBytes + x] = luma(x, y) }
    }
    return buffer
}

// MARK: - Tests

@Suite("Détection par zones")
struct ZoneDetectionTests {
    // MARK: Mesure

    @Test func samplerMeasuresAnEightByEightGrid() {
        // Un carré blanc qui couvre exactement la zone (colonne 5, rangée 2) d'une image grise.
        let buffer = makeBuffer { x, y in (40..<48).contains(x) && (16..<24).contains(y) ? 255 : 51 }
        let stats = LumaSampler.stats(of: buffer, step: 1)

        #expect(LumaSampler.zoneColumns == 8 && LumaSampler.zoneRows == 8)
        #expect(stats.zoneLumas.count == 64)
        #expect(stats.zoneLumas[2 * 8 + 5] == 255)
        #expect(stats.zoneLumas.enumerated().allSatisfy { $0.offset == 21 || $0.element == 51 })
    }

    @Test func zonesAverageEveryPixelOfTheSampledRows() {
        // Colonnes alternées noir / blanc : les points de la luma moyenne (x = 0, 8, 16…) tombent tous sur du noir,
        // mais une zone voit autant de blanc que de noir. Pris point par point, un motif fin (stores, écran à LED)
        // ferait sauter la luma d'une zone d'une image à l'autre sans qu'aucune lumière ne change.
        let stats = LumaSampler.stats(of: makeBuffer { x, _ in x.isMultiple(of: 2) ? 0 : 255 })

        #expect(stats.meanLuma == 0)
        #expect(stats.zoneLumas.allSatisfy { (127...128).contains($0) })
    }

    @Test(arguments: [2, 8])
    func zonesAverageEveryRowPhase(period: Int) {
        // Rayures horizontales (stores, rangées d'un écran à LED) : les lignes 0, 8, 16… tombent toutes sur du noir.
        // Les lignes des zones changent de phase d'une ligne mesurée à l'autre : chaque zone (64 lignes, 8 mesurées)
        // voit autant de blanc que de noir, et un tremblement d'une ligne ne la fait pas clignoter.
        let buffer = makeBuffer(width: 512, height: 512) { _, y in y % period < period / 2 ? 0 : 255 }
        let stats = LumaSampler.stats(of: buffer)

        #expect(stats.meanLuma == 0)
        #expect(stats.zoneLumas.allSatisfy { (127...128).contains($0) }, "\(Set(stats.zoneLumas))")
    }

    @Test func samplerZonesFollowThePixelFormat() {
        // Plage vidéo : Y = 235 est le blanc, comme pour la luma moyenne.
        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &created)
        let buffer = created!
        CVPixelBufferLockBaseAddress(buffer, [])
        let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        memset(plane, 235, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 64)
        CVPixelBufferUnlockBaseAddress(buffer, [])

        #expect(LumaSampler.stats(of: buffer).zoneLumas == [UInt8](repeating: 255, count: 64))
    }

    @Test func imageTooSmallForTheGridHasNoZones() {
        // 32×32 au pas de 8 : 4 × 4 points, certaines zones n'en auraient aucun.
        let stats = LumaSampler.stats(of: makeBuffer(width: 32, height: 32) { _, _ in 128 })
        #expect(stats.zoneLumas.isEmpty)
        #expect(abs(stats.meanLuma - 128.0 / 255) <= 0.005)
    }

    @Test func zonesSurviveCoding() throws {
        let stats = FrameStats(meanLuma: 0.5, saturatedFraction: 0.1, zoneLumas: [1, 2, 3])
        let decoded = try JSONDecoder().decode(FrameStats.self, from: JSONEncoder().encode(stats))
        #expect(decoded == stats)

        // Statistiques écrites avant les zones : lues sans zones.
        let old = Data(#"{"meanLuma":0.5,"saturatedFraction":0.1}"#.utf8)
        #expect(try JSONDecoder().decode(FrameStats.self, from: old).zoneLumas == [])
    }

    // MARK: Petite lampe dans une pièce claire

    @Test func smallLampInBrightRoomIsLight() {
        // Essai sur iPhone du 7 novembre : la lampe ne change la luma moyenne que de 6 %, loin du rapport 1,6. Sa
        // zone, elle, triple : chaque image allumée doit partir, et aucune autre.
        let count = 240
        let stats = (0..<count).map { roomWithLamp($0, lit: lampIsLit($0)) }
        let lit = (0..<count).filter(lampIsLit)

        let offline = OfflineFlashDetector.classify(stats, times: timestamps(count: count))
        #expect(offline.flashIndices == lit)
        // En ligne, la fenêtre doit d'abord voir la lampe éteinte puis allumée : jugé dès la deuxième période.
        #expect(onlineVerdicts(stats).flashIndices.filter { $0 >= 24 } == lit.filter { $0 >= 24 })
    }

    @Test func lampCoveringPartOfItsZoneIsLight() {
        // La lampe ne couvre qu'une partie de sa zone : 0,35 éteinte, 0,55 allumée (rapport 1,57). Sous le rapport
        // des deux niveaux (1,6 et la marge) : au nettoyage, ses sauts la trahissent ; en ligne (mesure avant
        // l'enregistrement, sans les sauts), elle n'est pas écartée.
        let count = 240
        let stats = (0..<count).map { index in
            var stats = roomWithLamp(index, lit: lampIsLit(index))
            stats.zoneLumas[lampZone] = byte(lampIsLit(index) ? 0.55 : 0.35)
            return stats
        }
        let lit = (0..<count).filter(lampIsLit)

        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count)).flashIndices == lit)
        #expect(onlineVerdicts(stats).flashIndices == [])

        // Par la règle des deux niveaux (sans les sauts), un rapport de 1,6 la laisse passer.
        var strict = FlashDetectorConfig()
        strict.watchesZoneSteps = false
        strict.zoneRelativeJump = 1.6
        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count), config: strict).flashIndices == [])
    }

    @Test func edgeFramesOfAMovingLampGoWithTheLight() {
        // Lumas réelles (en 255es) de zones de l'essai du 7 novembre, filmé à la main en s'approchant de la lampe.
        // Images 270 à 344, zone 27 : phase allumée 294…304, puis l'image 305 à moitié allumée (136) ; ensuite le
        // niveau éteint de la zone remonte avec le mouvement (99 → 140). Mesurée depuis l'image 305, la lumière
        // semblait durer 73 images (les images éteintes n'en sont pas nettement plus sombres) : 305 restait, et
        // les images recréées à côté d'elle montraient la lampe qui s'allume.
        let zone27: [UInt8] = [
            152, 152, 152, 152, 152, 152, 152, 152, 152, 152, 152, 146, 64, 65, 65, 66, 67, 68, 69, 70, 71, 72, 74,
            76, 163, 164, 164, 164, 165, 165, 166, 167, 168, 168, 169, 136, 99, 101, 104, 107, 110, 113, 119, 124,
            129, 134, 140, 177, 186, 186, 187, 190, 191, 192, 192, 194, 195, 196, 196, 191, 186, 184, 182, 178, 175,
            172, 170, 168, 166, 163, 161, 164, 171, 170, 168,
        ]
        let first = OfflineFlashDetector.classify(
            zone27.map { FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [$0]) },
            times: timestamps(count: zone27.count)
        )
        // La phase allumée et son bord partent ; l'image éteinte qui suit le bord reste (pas de chaîne).
        #expect((24...35).allSatisfy { first[$0] == .flash }, "\(first.flashIndices)")
        #expect(first[36] == .good, "\(first.flashIndices)")

        // Images 415 à 469, zones 18 et 19 : la lampe passe de l'une à l'autre. L'image 438 (zone 19 à 97, entre
        // 75 éteinte et 172 allumée) ouvre la phase allumée 439…450, l'image 451 (zone 18 à 114) la ferme. (La
        // suite, coupée à 469, ne dit pas assez combien dure le niveau qu'atteint ensuite la zone 19 : rien n'est
        // attendu après 451.)
        let zone19: [UInt8] = [
            205, 205, 205, 204, 203, 202, 201, 199, 197, 195, 194, 185, 64, 66, 68, 72, 73, 74, 73, 73, 73, 76, 79,
            97, 172, 170, 166, 163, 159, 155, 151, 149, 146, 144, 142, 141, 121, 119, 122, 124, 126, 128, 129, 130,
            131, 132, 133, 134, 142, 147, 147, 146, 145, 145, 145,
        ]
        let zone18: [UInt8] = [
            151, 151, 151, 150, 149, 148, 147, 145, 142, 140, 138, 130, 93, 91, 90, 90, 89, 91, 92, 95, 95, 93, 90,
            92, 139, 141, 142, 142, 146, 148, 150, 152, 156, 158, 161, 162, 114, 75, 76, 78, 79, 79, 77, 77, 75, 74,
            73, 75, 150, 158, 155, 153, 152, 149, 147,
        ]
        let second = OfflineFlashDetector.classify(
            zip(zone18, zone19).map { FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [$0, $1]) },
            times: timestamps(count: zone18.count)
        )
        #expect((23...36).allSatisfy { second[$0] == .flash }, "\(second.flashIndices)")
        #expect(second[22] == .good, "\(second.flashIndices)")
    }

    @Test func edgeSeenInAnotherZoneGoesWithTheLight() {
        // L'image 438 de l'essai : la lampe s'allume pendant sa pose. Sa zone B la voit à moitié éclairée (0,4 entre
        // 0,27 éteinte et 0,63 allumée), mais n'y confirme pas la lumière : le mouvement y laisse ensuite un niveau
        // de 0,5 qui dure. La zone A, elle, confirme la phase allumée 120…131. Le bord 119 part avec elle ; l'image
        // 132, au niveau de sa voisine dans la zone B, reste.
        let stats = (0..<240).map { index in
            let zoneA = (120...131).contains(index) ? 0.6 : 0.35
            let zoneB = index < 119 ? 0.27 : index == 119 ? 0.4 : index <= 131 ? 0.63 : 0.5
            return FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [byte(zoneA), byte(zoneB)])
        }

        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: 240)).flashIndices == Array(119...131))
    }

    @Test(arguments: 1...6)
    func steadyWindowShortcutChangesNoVerdict(seed: Int) {
        // Une zone jugée par deux niveaux de lumière l'est sans trier ses fenêtres calmes. Série pseudo-aléatoire de
        // paliers, lumières courtes, rampes et bruit fort : jugée comme zone (avec le raccourci) ou comme image
        // entière sans part saturée, au même rapport (sans raccourci), les verdicts doivent être identiques.
        var state = UInt64(seed)
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var lumas: [Double] = []
        var level = 0.3
        while lumas.count < 600 {
            let kind = random()
            let length = 1 + Int(random() * 40)
            if kind < 0.3 {
                level = 0.05 + random() * 0.8
                for _ in 0..<length { lumas.append(level + (random() - 0.5) * 0.02) }
            } else if kind < 0.6 {
                let peak = level * (1.2 + random()) + random() * 0.2
                for _ in 0..<min(length, 12) { lumas.append(peak) }
            } else if kind < 0.8 {
                let target = 0.05 + random() * 0.8
                for step in 1...length { lumas.append(level + (target - level) * Double(step) / Double(length)) }
                level = target
            } else {
                for _ in 0..<length { lumas.append(level + (random() - 0.5) * 0.1) }
            }
        }
        let bytes = lumas.prefix(600).map(byte)
        let times = timestamps(count: 600)

        var levelZones = FlashDetectorConfig()
        levelZones.watchesZoneSteps = false
        let asZone = OfflineFlashDetector.classify(
            bytes.map { FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [$0]) }, times: times,
            config: levelZones
        )
        var wholeImage = FlashDetectorConfig()
        wholeImage.relativeJump = wholeImage.zoneRelativeJump
        wholeImage.watchesZones = false
        let asWholeImage = OfflineFlashDetector.classify(
            bytes.map { FrameStats(meanLuma: Double($0) / 255, saturatedFraction: 0) }, times: times, config: wholeImage
        )

        #expect(asZone == asWholeImage)
        #expect(asZone.contains(.flash) && asZone.contains(.good))
    }

    @Test func zoneJudgingReportsEachZoneAndCanBeStopped() {
        let stats = (0..<120).map { roomWithLamp($0, lit: lampIsLit($0)) }
        var finished: [Int] = []
        // 64 zones, puis les 49 blocs de 2 × 2 zones.
        _ = OfflineFlashDetector.classify(stats, times: timestamps(count: 120)) { done, total in
            #expect(total == 113)
            finished.append(done)
        }
        #expect(finished == Array(1...113))

        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try OfflineFlashDetector.classify(stats, times: timestamps(count: 120)) { done, _ in
                if done == 3 { throw Stop() }
            }
        }
    }

    // MARK: Paires de sauts

    /// Une zone qui bouge avec la main : rampe de 120 à 160 en 2 s et ondulation lente (±15, période 1,3 s), plus
    /// `lamp` (en 255es) quand la lampe est allumée, et un léger bruit.
    private func movingZone(_ index: Int, lamp: Double) -> UInt8 {
        let t = Double(index) / 120
        let base = 120 + 20 * t + 15 * sin(2 * .pi * t / 1.3)
        return UInt8((base + (lampIsLit(index) ? lamp : 0) + noise(index, zone: 9, amplitude: 1)).rounded())
    }

    @Test func faintLampInAMovingZoneIsFoundByItsSteps() {
        // Essai sur iPhone du 7 novembre à 11 h : la lampe n'ajoute que 12 / 255 à sa zone, qui vaut 120 à 160 et bouge
        // avec la main (rapport 1,1). La règle des deux niveaux n'y voit rien ; la lampe, elle, monte et redescend
        // d'un coup, d'une image à l'autre, alors que le mouvement fait varier la zone peu à peu.
        let count = 240
        let stats = (0..<count).map { index in
            FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [movingZone(index, lamp: 12)])
        }
        let lit = (0..<count).filter(lampIsLit)

        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count)).flashIndices == lit)

        var levelsOnly = FlashDetectorConfig()
        levelsOnly.watchesZoneSteps = false
        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count), config: levelsOnly).flashIndices == [])
    }

    @Test func movingZoneWithoutLampHasNoLight() {
        let count = 480
        let stats = (0..<count).map { index in
            FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [movingZone(index, lamp: 0)])
        }
        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count)).flashIndices == [])
    }

    @Test func handShakeAcrossAnEdgeIsNotLight() {
        // Main qui tremble (8 Hz) devant un bord net : la zone oscille de 90 à 150, assez pour faire deux niveaux
        // à 1,4, et chaque bosse dure moins de 0,3 s. Mais elle monte et descend en douceur : pas de saut.
        let count = 480
        let stats = (0..<count).map { index in
            let luma = 120 + 30 * sin(2 * .pi * 8 * Double(index) / 120) + noise(index, zone: 3, amplitude: 1)
            return FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [UInt8(luma.rounded())])
        }
        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count)).flashIndices == [])
    }

    @Test func offPhaseHiddenByMotionIsNotJoined() {
        // Le mouvement fond l'extinction d'une phase et l'allumage de la suivante dans cette zone : un saut vers le
        // haut (image 100), un creux en pente douce jusqu'à 100 entre 112 et 123, puis un saut vers le bas (image
        // 130), 0,25 s après le premier. Entre les deux sauts, la zone retombe sous la moitié du saut : ce n'est pas
        // une seule lumière, le creux reste.
        var lumas = [UInt8](repeating: 80, count: 240)
        for index in 100..<130 { lumas[index] = 130 }
        for index in 112..<124 { lumas[index] = UInt8(130 - 5 * min(index - 111, 124 - index)) }
        let stats = lumas.map { FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [$0]) }

        let flashes = OfflineFlashDetector.classify(stats, times: timestamps(count: 240)).flashIndices
        #expect(!flashes.contains { (113...122).contains($0) }, "\(flashes)")
    }

    @Test func darkMomentRaisedByMotionInADarkRoomStaysGood() {
        // Essai sur iPhone du 7 novembre à 13 h 14 : pièce noire, la lampe (5 Hz, 7 images allumées sur 12 à 60 i/s) est
        // la seule lumière et donne deux niveaux à toutes les zones. Dans la zone 59, le mouvement fait remonter le
        // niveau éteint de 9 à 24…32 / 255 pendant un moment sans lumière (images 67 à 71), au-delà du bas + 20 % de
        // l'écart : ces images ne sont pas allumées pour autant, la zone y est descendue d'un coup et en remonte d'un
        // coup quand la lampe se rallume.
        let count = 240
        // Images 79 à 83 (zone 51 de l'essai) : la zone passe un instant sous le bas + 20 % de l'écart, puis remonte
        // peu à peu au-dessus.
        let lit = { (index: Int) in index % 12 < 7 }
        let dip: [Int: UInt8] = [67: 24, 68: 28, 69: 30, 70: 31, 71: 32, 79: 16, 80: 19, 81: 21, 82: 23, 83: 24]
        let stats = (0..<count).map { index in
            FrameStats(
                meanLuma: lit(index) ? 0.25 : 0.035,
                saturatedFraction: 0,
                zoneLumas: [dip[index] ?? (lit(index) ? 53 : 9)]
            )
        }
        let times = (0..<count).map { Double($0) / 60 }

        let flashes = OfflineFlashDetector.classify(stats, times: times).flashIndices
        #expect(flashes == (0..<count).filter(lit), "en trop : \(flashes.filter { !lit($0) })")
    }

    @Test func zoneFollowingTheRoomLampIsOffWhenTheRoomIsOff() {
        // Essai sur iPhone du 7 novembre à 15 h (images 700 à 799, 60 i/s) : pièce à moitié éclairée, la lampe éclaire
        // toute la pièce (image entière 0,17 éteinte, 0,43 allumée) et le vidéaste marche. Dans les zones 16 et 60, le
        // mouvement fait les deux niveaux et la lampe n'ajoute qu'une marche : allumé, éteint, rallumé y dure 0,3 s
        // et passait pour une seule lumière ; les moments éteints entiers partaient, et le repli montrait la lampe.
        let whole = [
            0.328, 0.176, 0.184, 0.19, 0.197, 0.202, 0.306, 0.429, 0.418, 0.41, 0.409, 0.395, 0.354, 0.168, 0.17, 0.186,
            0.194, 0.198, 0.261, 0.429, 0.421, 0.413, 0.405, 0.406, 0.383, 0.17, 0.18, 0.18, 0.193, 0.2, 0.218, 0.434,
            0.43, 0.422, 0.415, 0.415, 0.401, 0.195, 0.173, 0.173, 0.19, 0.196, 0.2, 0.43, 0.448, 0.436, 0.436, 0.422,
            0.416, 0.235, 0.147, 0.161, 0.168, 0.174, 0.179, 0.409, 0.458, 0.447, 0.447, 0.431, 0.423, 0.286, 0.145,
            0.156, 0.164, 0.17, 0.175, 0.378, 0.463, 0.452, 0.452, 0.436, 0.428, 0.328, 0.145, 0.154, 0.163, 0.168,
            0.173, 0.338, 0.463, 0.452, 0.453, 0.437, 0.43, 0.364, 0.146, 0.153, 0.162, 0.167, 0.166, 0.296, 0.468,
            0.459, 0.451, 0.452, 0.438, 0.402, 0.139, 0.146,
        ]
        let zone16: [UInt8] = [
            70, 34, 36, 38, 39, 40, 59, 91, 87, 85, 84, 80, 71, 28, 27, 32, 34, 35, 45, 86, 83, 81, 79, 79, 75, 29, 33, 34,
            39, 42, 47, 90, 91, 93, 94, 96, 95, 74, 75, 75, 81, 83, 75, 88, 85, 76, 68, 59, 52, 21, 10, 11, 12, 14, 15,
            52, 67, 64, 64, 61, 59, 32, 9, 12, 14, 16, 18, 51, 73, 70, 70, 66, 64, 43, 11, 14, 16, 17, 19, 44, 74, 71, 71,
            66, 64, 50, 11, 13, 14, 15, 15, 35, 76, 73, 71, 72, 69, 62, 10, 11,
        ]
        let zone60: [UInt8] = [
            84, 57, 57, 58, 59, 59, 84, 108, 106, 103, 103, 100, 84, 47, 47, 51, 52, 53, 72, 106, 104, 103, 101, 101, 91,
            46, 48, 49, 53, 55, 66, 113, 116, 120, 125, 132, 135, 102, 113, 123, 134, 141, 146, 172, 169, 158, 146, 132,
            121, 54, 34, 37, 38, 38, 39, 123, 132, 130, 131, 128, 126, 68, 24, 27, 30, 32, 34, 123, 141, 137, 137, 132,
            129, 87, 24, 27, 30, 32, 34, 110, 139, 135, 134, 128, 124, 95, 23, 26, 28, 30, 31, 85, 126, 121, 115, 112,
            104, 84, 23, 27,
        ]
        let stats = whole.indices.map { index in
            FrameStats(meanLuma: whole[index], saturatedFraction: 0, zoneLumas: [zone16[index], zone60[index]])
        }
        let times = whole.indices.map { Double($0) / 60 }

        let flashes = Set(OfflineFlashDetector.classify(stats, times: times).flashIndices)
        let off = whole.indices.filter { whole[$0] < 0.21 }
        let lit = whole.indices.filter { whole[$0] > 0.3 }
        #expect(off.filter(flashes.contains) == [], "éteintes retirées")
        #expect(lit.filter { !flashes.contains($0) } == [], "allumées gardées")
    }

    @Test func motionSwellWhileTheRoomIsOffIsNotLight() {
        // Essai sur iPhone du 7 novembre à 15 h, dos à la lampe (images 840 à 960) : la lampe n'éclaircit la pièce que de
        // 1,5 fois, l'image entière n'y voit pas deux niveaux, mais toutes les zones montent et descendent ensemble
        // avec elle. Dans la zone 10, la marche du vidéaste fait gonfler le fond au moment même où la pièce s'éteint
        // (images 103 à 107) : la zone n'y descend pas, elle monte encore, peu à peu ; ce n'est pas une lumière.
        let count = 240
        let lit = { (index: Int) in index % 12 < 7 }
        func zone(_ zone: Int, at index: Int) -> UInt8 {
            let swell = exp(-pow(Double(index - 105) / 5, 2))
            let base = zone == 0 ? 50 + 110 * swell : 50 + 8 * Double(zone)
            return byte((base * (lit(index) ? 1.5 : 1) + noise(index, zone: zone, amplitude: 1)) / 255)
        }
        let stats = (0..<count).map { index in
            let zones = (0..<12).map { zone($0, at: index) }
            let mean = zones.reduce(0) { $0 + Double($1) } / Double(zones.count) / 255
            return FrameStats(meanLuma: mean, saturatedFraction: 0, zoneLumas: zones)
        }
        let times = (0..<count).map { Double($0) / 60 }

        let flashes = Set(OfflineFlashDetector.classify(stats, times: times).flashIndices)
        #expect((0..<count).filter { !lit($0) && flashes.contains($0) } == [], "éteintes retirées")
        #expect((0..<count).filter { lit($0) && !flashes.contains($0) } == [], "allumées gardées")
    }

    @Test func brightThingMovingInWhileTheRoomIsOffIsNotLight() {
        // Essai sur iPhone du 7 novembre à 15 h, dos à la lampe (images 883 à 888, 60 i/s) : il marche et la caméra bouge.
        // Pendant que la pièce est éteinte, la zone 29 passe de 32 à 50, 77 puis 97 / 255 d'une image à l'autre : un
        // fond clair y entre, à plus de 1,25 fois par image. Ce n'est pas une lumière : il vient d'à côté, où la lampe
        // le rendait plus clair encore (zone 21 voisine : 111 au rallumage). Ici, une colonne claire passe d'une
        // colonne de zones à la voisine au milieu de chaque moment éteint. Une autre lumière, dans un coin où rien
        // de clair n'arrive, reste vue (zone 56, images 127 à 131).
        let count = 235 // finit sur un éclair : le dernier moment éteint est encadré
        let lit = { (index: Int) in index % 12 < 7 }
        let other = 127...131
        /// Colonne de zones de la colonne claire : elle change aux images 9 de chaque cycle, d'un bord à l'autre et
        /// retour.
        func column(at index: Int) -> Int {
            let step = (index + 3) / 12 % 14
            return step < 8 ? step : 14 - step
        }
        let stats = (0..<count).map { index in
            let zones = (0..<64).map { zone -> UInt8 in
                if zone == 56, other.contains(index) { return 200 }
                let base = zone % 8 == column(at: index) ? 110.0 : 50
                return UInt8((base * (lit(index) ? 1.5 : 1) + noise(index, zone: zone, amplitude: 1)).rounded())
            }
            let mean = zones.reduce(0) { $0 + Double($1) } / Double(zones.count) / 255
            return FrameStats(meanLuma: mean, saturatedFraction: 0, zoneLumas: zones)
        }
        let times = (0..<count).map { Double($0) / 60 }

        let flashes = Set(OfflineFlashDetector.classify(stats, times: times).flashIndices)
        let light = (0..<count).filter { lit($0) || other.contains($0) }
        #expect(flashes.subtracting(light).sorted() == [], "éteintes retirées")
        #expect(light.filter { !flashes.contains($0) } == [], "allumées gardées")
    }

    @Test func steadyHighlightGatheringInOneZoneWhileTheRoomIsOffIsNotLight() {
        // Même essai (images 895 à 900) : un reflet clair et fixe, sur le haut d'une étagère, que la lampe n'éclaire
        // pas. Aux éclairs, il est à cheval sur deux zones ; pendant que la pièce est éteinte, le mouvement le ramène
        // dans une seule (zone 12 : 138 à 156 / 255, quand elle et ses voisines valaient au plus 126 aux éclairs). Une
        // zone y gagne ce que l'autre perd : elle n'est pas nettement plus claire que la lampe ne rendait ses
        // alentours, ce n'est pas une lumière.
        let count = 235
        let lit = { (index: Int) in index % 12 < 7 }
        let stats = (0..<count).map { index in
            let zones = (0..<64).map { zone -> UInt8 in
                let highlight = switch zone {
                case 11: lit(index) ? 60.0 : 0
                case 12: lit(index) ? 60.0 : 120
                default: 0.0
                }
                return UInt8((50 * (lit(index) ? 1.5 : 1) + highlight + noise(index, zone: zone, amplitude: 1)).rounded())
            }
            let mean = zones.reduce(0) { $0 + Double($1) } / Double(zones.count) / 255
            return FrameStats(meanLuma: mean, saturatedFraction: 0, zoneLumas: zones)
        }
        let times = (0..<count).map { Double($0) / 60 }

        let flashes = Set(OfflineFlashDetector.classify(stats, times: times).flashIndices)
        let light = (0..<count).filter(lit)
        #expect(flashes.subtracting(light).sorted() == [], "éteintes retirées")
        #expect(light.filter { !flashes.contains($0) } == [], "allumées gardées")
    }

    @Test func framesBrighterThanTheRoomLightsAroundThemAreNotARoomOffMoment() {
        // Essai sur iPhone du 7 novembre à 15 h, images 906 à 943 : `RoomLight` voit les éclairs 913 à 919 et 937 à 943,
        // pas celui de 925 à 931 (image entière de 0,23 à 0,32, rapport 1,4). Ses images, plus claires que les éclairs
        // vus autour d'elles, ne sont pas un moment où la pièce est éteinte : leurs zones restent jugées.
        let lumas = [
            0.284, 0.227, 0.218, 0.216, 0.221, 0.222, 0.223, 0.287, 0.304, 0.298, 0.298, 0.296, 0.296, 0.24, 0.215,
            0.22, 0.223, 0.229, 0.232, 0.29, 0.322, 0.324, 0.322, 0.321, 0.317, 0.263, 0.204, 0.203, 0.202, 0.205,
            0.206, 0.274, 0.339, 0.335, 0.329, 0.329, 0.33, 0.286,
        ]
        let lights = lumas.indices.map { (0...0).contains($0) || (7...13).contains($0) || (31...37).contains($0) }
        let moments = OfflineFlashDetector.roomOffMoments(
            lights: lights,
            halfLit: lumas.map { _ in false },
            lumas: lumas,
            times: lumas.indices.map { Double($0) / 60 },
            config: FlashDetectorConfig()
        )
        let off = lumas.indices.filter { moments[$0] != nil }
        #expect(off == Array(1...6) + Array(14...18) + Array(26...30))
        #expect(moments[14]! == (before: 13, after: 31))
    }

    @Test func lampGlowRightAfterTheRoomGoesOffIsStillAnEdge() {
        // Essais sur iPhone du 7 novembre à 15 h 45 : la lampe éclaire la pièce (7 images sur 12 à 60 i/s) ; à l'image
        // qui suit chaque éclair, la pièce est déjà éteinte mais les diodes de la lampe brillent encore (extinction
        // pendant la pose). Sa zone y est à moitié éclairée : c'est un bord de la lumière, qui part avec elle, même si
        // la pièce est éteinte.
        let count = 240
        let lit = { (index: Int) in index % 12 < 7 }
        let glow = { (index: Int) in index % 12 == 7 }
        let stats = (0..<count).map { index in
            let lamp: UInt8 = lit(index) ? 250 : glow(index) ? 120 : 20
            let room: [UInt8] = (0..<6).map { zone in UInt8(lit(index) ? 110 + 5 * zone : 40 + 2 * zone) }
            return FrameStats(meanLuma: lit(index) ? 0.43 : 0.18, saturatedFraction: 0, zoneLumas: [lamp] + room)
        }
        let times = (0..<count).map { Double($0) / 60 }

        let flashes = OfflineFlashDetector.classify(stats, times: times).flashIndices
        #expect(flashes == (0..<count).filter { lit($0) || glow($0) })
    }

    @Test func roomLightIsSeenByAllZonesTogether() {
        // La lampe éclaircit la pièce de 1,3 fois (7 images sur 12 à 60 i/s), sous le seuil de l'image entière ; une
        // zone sur trois bouge fort (ondulation de ±60 en 0,8 s). La médiane des sauts des zones suit la lampe. Avec
        // moins de trois zones, pas de lumière de la pièce.
        let count = 240
        let lit = { (index: Int) in index % 12 < 7 }
        let stats = (0..<count).map { index in
            let zones = (0..<12).map { zone -> UInt8 in
                let motion = zone % 3 == 0 ? 60 * sin(2 * .pi * Double(index) / 48 + Double(zone)) : 0
                let base = 80 + 10 * Double(zone) + motion
                return byte((base * (lit(index) ? 1.3 : 1) + noise(index, zone: zone, amplitude: 1)) / 255)
            }
            return FrameStats(meanLuma: 0.3, saturatedFraction: 0, zoneLumas: zones)
        }
        let times = (0..<count).map { Double($0) / 60 }
        let config = FlashDetectorConfig().forZone

        let roomLit = RoomLight.litFrames(stats, times: times, config: config)
        #expect(roomLit.indices.filter { roomLit[$0] } == (0..<count).filter(lit))
        let twoZones = stats.map { FrameStats(meanLuma: 0.3, saturatedFraction: 0, zoneLumas: Array($0.zoneLumas.prefix(2))) }
        #expect(!RoomLight.litFrames(twoZones, times: times, config: config).contains(true))
    }

    @Test func otherLightOnWhileTheRoomIsOffIsStillLight() {
        // La lampe éclaire la pièce (7 images sur 12 à 60 i/s) ; dans une zone, une autre lumière s'allume pendant
        // deux moments où la pièce est éteinte (images 67 à 71 et 127 à 131) : la zone y est plus claire qu'aux
        // éclairs de la pièce, ce n'est pas la lampe de la pièce qui l'éclaire.
        let count = 240
        let roomLit = { (index: Int) in index % 12 < 7 }
        let other = Set(Array(67...71) + Array(127...131))
        let stats = (0..<count).map { index in
            let zone: UInt8 = other.contains(index) ? 200 : roomLit(index) ? 80 : 40
            return FrameStats(meanLuma: roomLit(index) ? 0.43 : 0.18, saturatedFraction: 0, zoneLumas: [zone])
        }
        let times = (0..<count).map { Double($0) / 60 }

        let flashes = OfflineFlashDetector.classify(stats, times: times).flashIndices
        #expect(flashes == (0..<count).filter { roomLit($0) || other.contains($0) })
    }

    @Test func dimFrameBetweenTwoLitFramesIsStillLight() {
        // Ce n'est pas un moment éteint (relecture du 7 novembre) : une image à 70 % de l'écart entre deux images
        // allumées (lumière qui vacille, deux projecteurs qui se relaient), et une seule image à moitié allumée
        // entre les deux éclairs d'un double éclair. Les deux sauts qui l'entourent sont francs, mais la lumière
        // n'y est pas éteinte : la descente n'atteint pas la moitié de l'écart, ou le creux ne dure qu'une image.
        let count = 240
        var lumas = [Double](repeating: 0.1, count: count)
        for (index, luma) in [(60, 0.6), (61, 0.45), (62, 0.6), (120, 0.6), (121, 0.25), (122, 0.6)] {
            lumas[index] = luma
        }
        let stats = lumas.map { FrameStats(meanLuma: $0, saturatedFraction: 0) }
        let times = (0..<count).map { Double($0) / 60 }

        let flashes = OfflineFlashDetector.classify(stats, times: times).flashIndices
        #expect(flashes == [60, 61, 62, 120, 121, 122])
    }

    @Test func fastLocalStrobeIsFoundByItsSteps() {
        // Stroboscope rapide dans un coin de l'image : 15 Hz filmé à 60 i/s, 2 images allumées puis 2 éteintes. La
        // moitié des voisins d'un saut sont eux-mêmes des sauts : ils ne doivent pas passer pour du mouvement.
        let count = 240
        let on = { (index: Int) in index % 4 >= 2 }
        let stats = (0..<count).map { index in
            let luma = 100 + (on(index) ? 30 : 0) + noise(index, zone: 5, amplitude: 1)
            return FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [UInt8(luma.rounded())])
        }
        let times = (0..<count).map { Double($0) / 60 }

        #expect(OfflineFlashDetector.classify(stats, times: times).flashIndices == (0..<count).filter(on))
    }

    @Test(arguments: [20.0, 30.0])
    func fullSpeedStrobeInACornerIsLight(hertz: Double) {
        // Un stroboscope à pleine vitesse dans un coin, filmé à 60 i/s : un éclair d'une image toutes les 3 (20 Hz)
        // ou toutes les 2 (30 Hz). Presque tous les voisins d'un saut sont des sauts : les paires n'y suffisent pas,
        // la règle des deux niveaux, si (l'éclair est vif).
        let count = 240
        let period = Int((60 / hertz).rounded())
        let on = { (index: Int) in index % period == period - 1 }
        let stats = (0..<count).map { index in
            let luma = (on(index) ? 200 : 80) + noise(index, zone: 4, amplitude: 1)
            return FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [UInt8(luma.rounded())])
        }
        let times = (0..<count).map { Double($0) / 60 }

        #expect(OfflineFlashDetector.classify(stats, times: times).flashIndices == (0..<count).filter(on))
    }

    @Test func faintLampFilmedAt30fpsIsFound() {
        // La lampe de test (5 Hz, allumée la moitié du temps) filmée à 30 i/s : 3 images allumées, 3 éteintes, sur
        // une zone qui bouge. Les 6 voisins de chaque côté couvrent alors 0,2 s.
        let count = 120
        let lit = { (index: Int) in (index / 3) % 2 == 1 }
        let stats = (0..<count).map { index in
            let t = Double(index) / 30
            let luma = 120 + 20 * t + 15 * sin(2 * .pi * t / 1.3) + (lit(index) ? 14 : 0) + noise(index, zone: 2, amplitude: 1)
            return FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [UInt8(luma.rounded())])
        }
        let times = (0..<count).map { Double($0) / 30 }

        #expect(OfflineFlashDetector.classify(stats, times: times).flashIndices == (0..<count).filter(lit))
    }

    @Test func lampMovingBetweenTwoZonesIsFoundByTheirBlock() {
        // Pendant chaque phase allumée, la lampe glisse de la zone 27 à la zone 28 : la zone 27 monte d'un coup puis
        // s'éteint peu à peu, la zone 28 s'allume peu à peu puis descend d'un coup. Aucune des deux ne voit une paire,
        // ni deux niveaux (+40 sur 100) ; le bloc 2 × 2 qui les couvre voit +10 tout le long de la phase.
        let count = 240
        let stats = (0..<count).map { index in
            let step = Double(index % 24 - 12)
            let share = lampIsLit(index) ? step / 11 : 0
            let zones = (0..<64).map { zone -> UInt8 in
                var luma = 100 + noise(index, zone: zone, amplitude: 1)
                if lampIsLit(index), zone == 27 { luma += 40 * (1 - share) }
                if lampIsLit(index), zone == 28 { luma += 40 * share }
                return UInt8(luma.rounded())
            }
            return FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: zones)
        }

        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count)).flashIndices == (0..<count).filter(lampIsLit))
    }

    @Test func spotCrossingTheZonesOnceIsNotLight() {
        // Un faisceau qui balaie la salle passe une seule fois sur chaque zone d'une rangée : +40 sur 100 pendant 10
        // images, zone après zone. Chaque zone voit une paire de sauts, mais une seule : pas le rythme d'une lumière
        // qui clignote, rien n'est retiré.
        let count = 240
        let stats = (0..<count).map { index in
            let zones = (0..<64).map { zone -> UInt8 in
                var luma = 100 + noise(index, zone: zone, amplitude: 1)
                if zone / 8 == 3, index / 10 == 6 + zone % 8 { luma += 40 }
                return UInt8(luma.rounded())
            }
            return FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: zones)
        }

        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count)).flashIndices == [])
    }

    @Test func loneRiseAtTheEndIsNotLight() {
        // On abaisse l'iPhone vers une lumière en arrêtant : la zone monte d'un coup dans les 0,2 dernières secondes et
        // y reste. Sans autre lumière de même ampleur dans la zone, la fin reste.
        var lumas = [UInt8](repeating: 100, count: 240)
        for index in 216..<240 { lumas[index] = 140 }
        let stats = lumas.map { FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [$0]) }

        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: 240)).flashIndices == [])
    }

    @Test func videoStartingLampLitLosesItsFirstLight() {
        // Essai sur iPhone du 7 novembre à 11 h : la vidéo commence lampe allumée. Pas de saut vers le haut pour
        // ouvrir cette première lumière, mais la zone clignote ensuite au même rythme, de la même ampleur.
        let count = 240
        let stats = (0..<count).map { index in
            FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [movingZone(index + 12, lamp: 12)])
        }
        let lit = (0..<count).filter { lampIsLit($0 + 12) }
        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count)).flashIndices == lit)

        // Une seule baisse brusque au début, sans lumière ailleurs dans la zone : rien n'est retiré.
        var lumas = [UInt8](repeating: 120, count: count)
        for index in 0..<20 { lumas[index] = 140 }
        let single = lumas.map { FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: [$0]) }
        #expect(OfflineFlashDetector.classify(single, times: timestamps(count: count)).flashIndices == [])
    }

    @Test func zoneSettingsDefaultsAndCoding() throws {
        let config = FlashDetectorConfig()
        #expect(config.watchesZones)
        #expect(config.zoneRelativeJump == 1.6)
        #expect(config.watchesZoneSteps)
        #expect(config.stepMotionFactor == 4)
        #expect(config.stepRhythmSeconds == 2)

        var tuned = config
        tuned.watchesZones = false
        tuned.zoneRelativeJump = 1.3
        #expect(try JSONDecoder().decode(FlashDetectorConfig.self, from: JSONEncoder().encode(tuned)) == tuned)
    }

    @Test func withoutZonesTheSmallLampIsMissed() {
        // Le comportement de la V2 avant les zones (option `strobe-tune --no-zones`).
        var config = FlashDetectorConfig()
        config.watchesZones = false
        let count = 240
        let stats = (0..<count).map { roomWithLamp($0, lit: lampIsLit($0)) }

        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count), config: config).flashIndices == [])
        #expect(onlineVerdicts(stats, config: config).flashIndices == [])
    }

    @Test func bigFlashIsStillSeenByTheWholeImage() {
        // Sans zones (image trop petite, ou statistiques sans grille) : la règle de toute l'image reste seule.
        let count = 240
        let stats = (0..<count).map { index in
            FrameStats(meanLuma: lampIsLit(index) ? 0.6 : 0.1, saturatedFraction: 0)
        }
        let lit = (0..<count).filter(lampIsLit)
        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count)).flashIndices == lit)
    }

    // MARK: Garde-fous

    @Test func quietRoomWithNoisyDarkZonesHasNoLight() {
        // Toutes les zones bruitent (± 0,02), dont des zones presque noires (0,02) où le bruit double la luma.
        let count = 240
        let stats = (0..<count).map { index in
            let zones = (0..<64).map { zone in
                byte((zone < 8 ? 0.02 : background(zone: zone)) + noise(index, zone: zone, amplitude: 0.02))
            }
            return FrameStats(meanLuma: 0.5, saturatedFraction: 0, zoneLumas: zones)
        }

        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count)).flashIndices == [])
        #expect(onlineVerdicts(stats).flashIndices == [])
    }

    @Test func panAcrossABrightWindowIsNotLight() {
        // Panoramique : une fenêtre claire (0,95) entre dans chaque zone d'une rangée en 0,5 s, y reste 1 s, puis
        // en sort en 0,5 s ; les zones voisines la reçoivent l'une après l'autre. Rien n'y clignote.
        let count = 480
        func zoneLuma(_ zone: Int, at index: Int) -> Double {
            guard zone / 8 == 4 else { return background(zone: zone) }
            let start = Double(zone % 8) * 30
            let t = Double(index) - start
            let rise = min(1, max(0, t / 60))
            let fall = min(1, max(0, (t - 180) / 60))
            return 0.3 + 0.65 * (rise - fall)
        }
        let stats = (0..<count).map { index in
            FrameStats(
                meanLuma: 0.5,
                saturatedFraction: 0,
                zoneLumas: (0..<64).map { byte(zoneLuma($0, at: index) + noise(index, zone: $0, amplitude: 0.01)) }
            )
        }

        #expect(OfflineFlashDetector.classify(stats, times: timestamps(count: count)).flashIndices == [])
        let online = onlineVerdicts(stats)
        #expect(online.flashIndices == [], "\(online.flashIndices)")
    }

    @Test func rescaleAlsoMovesTheZones() {
        // L'exposition double pendant la mesure : toutes les zones doublent avec elle. Ramenées à la nouvelle
        // exposition, les zones déjà vues ne prennent pas ce saut volontaire pour une lumière qui s'allume.
        var detector = OnlineFlashDetector()
        func frame(_ index: Int, scale: Double) -> FrameStats {
            FrameStats(
                meanLuma: 0.2 * scale,
                saturatedFraction: 0,
                zoneLumas: (0..<64).map { byte((0.1 + 0.3 * Double($0) / 63) * scale + noise(index, zone: $0, amplitude: 0.005)) }
            )
        }
        for index in 0..<60 {
            #expect(detector.classify(frame(index, scale: 1), at: time(index)) == .good)
        }
        detector.rescale(by: 2)
        for index in 60..<120 {
            #expect(detector.classify(frame(index, scale: 2), at: time(index)) == .good)
        }
    }

    @Test func resetAlsoForgetsTheZones() {
        // Après `reset()`, une lampe déjà vue doit être réapprise : la première image allumée qui suit ne peut
        // pas être jugée (fenêtre trop courte).
        var detector = OnlineFlashDetector()
        for index in 0..<120 { _ = detector.classify(roomWithLamp(index, lit: lampIsLit(index)), at: time(index)) }
        detector.reset()
        #expect(detector.classify(roomWithLamp(120, lit: true), at: time(120)) == .good)
    }

    @Test func meterSeesTheRhythmOfASmallLamp() {
        // Le choix de la cadence de prise de vue repose sur le rythme vu pendant la mesure : la petite lampe doit
        // y apparaître comme un stroboscope, avec des moments sans lumière de 0,1 s.
        // Scène déjà à la bonne exposition (pas de correction) et mesure prolongée sur les 2 s de la scène.
        var config = ExposureMeterConfig()
        config.targetLuma = 0.51
        config.requiredStableSteps = 1_000
        config.timeoutSeconds = 10
        var meter = ExposureMeter(
            limits: ExposureLimits(minDuration: 1.0 / 8000, maxDuration: 1.0 / 120, minISO: 50, maxISO: 3200),
            initial: Exposure(durationSeconds: 1.0 / 240, iso: 200),
            config: config
        )
        for index in 0..<240 {
            meter.ingest(roomWithLamp(index, lit: lampIsLit(index)), at: time(index), appliedExposure: meter.target)
        }
        #expect(meter.rhythm.hasStrobe)
    }
}
