import AVFoundation
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import StrobeCore

// MARK: - Aides

/// Cadence des vidéos de test : 120 images par seconde, comme à la capture.
private let sourceFPS = 120.0

/// Taille des vidéos de test (petite, pour des tests rapides).
private let testSize = CGSize(width: 320, height: 180)

/// Luma de la scène hors éclairs.
private let baseLuma = 0.3

/// L'appareil sait recréer des images, et débruiter, à la taille des vidéos de test : sinon les tests qui en
/// ont besoin sont sautés.
private let canSynthesize = FrameSynthesizer.isSupported(width: Int(testSize.width), height: Int(testSize.height))
private let canDenoise = NoiseReducer.isSupported(width: Int(testSize.width), height: Int(testSize.height))

/// Crée un dossier de travail vide propre au test (à supprimer par l'appelant).
private func makeWorkDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "VideoCleanerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Fichier intermédiaire que `clean` écrit avant de le renommer en `output`.
private func partialURL(for output: URL) -> URL {
    URL(fileURLWithPath: output.path + ".partial")
}

/// Racine du dépôt, déduite de l'emplacement de ce fichier
/// (`<dépôt>/Packages/StrobeCore/Tests/StrobeCoreTests/VideoCleanerTests.swift`).
private func repositoryRoot(filePath: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
}

/// Chaque image de `url`, dans l'ordre d'affichage : indice source relu dans sa bande (`nil` si illisible)
/// et luma moyenne.
private func decodedFrames(in url: URL) async throws -> [(index: Int?, luma: Double)] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ])
    reader.add(output)
    #expect(reader.startReading())

    var frames: [(index: Int?, luma: Double)] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
        frames.append((SyntheticVideo.decodeIndex(from: image), LumaSampler.stats(of: image).meanLuma))
    }
    #expect(reader.status == .completed)
    return frames
}

/// Indice source relu dans la bande de chaque image de `url`, dans l'ordre d'affichage (`nil` si illisible).
private func sourceIndices(in url: URL) async throws -> [Int?] {
    try await decodedFrames(in: url).map(\.index)
}

/// Vrai pour un créneau dont l'image est recréée (elle ne porte pas de bande lisible).
private func isInterpolated(_ slot: SlotPlan) -> Bool {
    if case .interpolate = slot { true } else { false }
}

/// Lampe du premier essai sur iPhone, à 120 i/s pendant 3 s : allumée la moitié du temps, 5 fois par seconde.
private let halfDutyLit = SyntheticVideo.squareWave(fps: sourceFPS, seconds: 3, frequency: 5, litFraction: 0.5)
/// Luma de la scène sans lumière (pièce sombre) et avec la lampe.
private let darkLuma = 0.1
private let lampLuma = 0.6
/// Luma moyenne (bande comprise) au-dessus de laquelle une image de sortie montre la lampe : entre les images
/// sans lumière (≈ 0,17) et les images éclairées (≈ 0,58).
private let litOutputLuma = 0.3

/// Écrit à `url` la vidéo de la lampe (`halfDutyLit`), avec audio.
private func makeHalfDutyVideo(at url: URL) async throws {
    try await SyntheticVideo.make(
        at: url, fps: sourceFPS, seconds: 3, size: testSize,
        flashIndices: halfDutyLit, baseLuma: darkLuma, withAudio: true, flashLuma: lampLuma
    )
}

/// Petite lampe dans une pièce claire (essai sur iPhone du 7 novembre) : elle occupe exactement la zone (colonne 3,
/// rangée 4) de la grille 8 × 8, soit 1/64 de l'image, et passe de la luma de la pièce (0,5) au blanc.
private let smallLampRect = CGRect(x: 3.0 / 8, y: 4.0 / 8, width: 1.0 / 8, height: 1.0 / 8)
private let smallLampZone = 4 * 8 + 3

/// Luma de la zone de la petite lampe dans chaque image de `url`, dans l'ordre d'affichage.
private func smallLampZoneLumas(in url: URL) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ])
    reader.add(output)
    #expect(reader.startReading())
    var lumas: [Double] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
        let zones = LumaSampler.stats(of: image).zoneLumas
        lumas.append(zones.isEmpty ? .nan : Double(zones[smallLampZone]) / 255)
    }
    #expect(reader.status == .completed)
    return lumas
}

/// Synthèse qui échoue toujours, comme un processeur qui lâche en plein fichier.
private final class FailingInterpolator: FrameInterpolator {
    struct Failure: Error {}
    private(set) var calls = 0

    func frames(between a: CVPixelBuffer, and b: CVPixelBuffer, phases: [Float]) async throws -> [CVPixelBuffer] {
        calls += 1
        throw Failure()
    }

    func finish() {}
}

/// Synthèse qui « réussit » en rendant des images noires : la recréation d'images d'Apple quand l'iPhone, verrouillé
/// pendant le nettoyage, ne lui prête plus le GPU (essai sur iPhone du 7 novembre à 15 h).
private final class BlackInterpolator: FrameInterpolator {
    private(set) var calls = 0

    func frames(between a: CVPixelBuffer, and b: CVPixelBuffer, phases: [Float]) async throws -> [CVPixelBuffer] {
        calls += 1
        return phases.map { _ in Self.black(like: a) }
    }

    func finish() {}

    /// Image noire (luma 0, chroma neutre) de la taille et du format de `image`.
    private static func black(like image: CVPixelBuffer) -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(
            nil, CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image),
            CVPixelBufferGetPixelFormatType(image), attributes, &created
        )
        let buffer = created!
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? 0 : 128, bytes)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferPropagateAttachments(image, buffer)
        return buffer
    }
}

/// Plages temporelles de la piste vidéo et de la piste audio (`nil` sans audio).
private func trackRanges(of url: URL) async throws -> (video: CMTimeRange, audio: CMTimeRange?) {
    let asset = AVURLAsset(url: url)
    let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let audio = try await asset.loadTracks(withMediaType: .audio).first
    return (try await video.load(.timeRange), try await audio?.load(.timeRange))
}

/// Paquets audio compressés de `url`, lus sans décodage : nombre de paquets et octets mis bout à bout.
private func audioPackets(in url: URL) async throws -> (count: Int, data: Data) {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    #expect(reader.startReading())

    var count = 0
    var data = Data()
    while let sample = output.copyNextSampleBuffer() {
        count += CMSampleBufferGetNumSamples(sample)
        guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        #expect(status == noErr)
        data.append(bytes)
    }
    #expect(reader.status == .completed)
    return (count, data)
}

/// Valeur partagée avec les rappels `@Sendable` de progression.
private final class Shared<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    var value: Value { storage.withLock { $0 } }

    /// Modifie la valeur sous verrou et renvoie le résultat de `body`.
    @discardableResult
    func update<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        storage.withLock { body(&$0) }
    }
}

/// Annule la tâche qui exécute l'appelant : appelée depuis le rappel de progression, elle annule le
/// nettoyage en cours, à un moment choisi, sans bloquer aucun fil.
private func cancelCurrentTask() {
    withUnsafeCurrentTask { $0?.cancel() }
}

/// Vrai si chaque valeur est supérieure ou égale à la précédente.
private func isMonotone(_ values: [Double]) -> Bool {
    zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
}

// MARK: - Tests

// Les tests encodent et décodent de la vidéo : en série, pour ne pas se disputer l'encodeur matériel.
@Suite("VideoCleaner", .serialized)
struct VideoCleanerTests {
    @Test func noStrobeKeepsEveryFourthFrame() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: [], baseLuma: baseLuma, withAudio: true
        )

        let report = try await VideoCleaner().clean(input: input, output: output) { _ in }

        #expect(report.totalFrames == 360)
        #expect(report.flashFrames == 0)
        #expect(report.selection == SelectionReport(slots: 90, heldSlots: 0, fallbackSlots: 0))
        // Scène claire (luma ≈ 0,33 avec la bande) : pas de débruitage.
        #expect(report.denoisedFrames == 0)
        let indices = try await sourceIndices(in: output)
        #expect(indices == stride(from: 0, to: 360, by: 4).map { Optional($0) })
    }

    /// Deuxième essai sur iPhone : la lampe ne fait qu'un coin d'une pièce claire. La luma moyenne ne bouge que de
    /// 1 % : l'image entière ne la voit pas, sa zone si. Aucune image de sortie ne montre la lampe allumée.
    @Test func smallLampInBrightRoomRemoved() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize, flashIndices: halfDutyLit,
            baseLuma: 0.5, withAudio: true, flashLuma: 1, lampRect: smallLampRect
        )

        let report = try await VideoCleaner().clean(input: input, output: output) { _ in }

        #expect(report.flashFrames == halfDutyLit.count)
        #expect(report.selection.slots == 90)
        if canSynthesize { #expect(report.selection.interpolatedSlots > 0) }
        let lumas = try await smallLampZoneLumas(in: output)
        #expect(lumas.count == 90)
        for (slot, luma) in lumas.enumerated() {
            // Éteinte 0,5, allumée 1.
            #expect(luma < 0.75, "créneau \(slot) : zone de la lampe à \(luma)")
        }

        // Sans les zones, la règle de l'image entière seule la laisse passer.
        var wholeImageOnly = CleanerConfig()
        wholeImageOnly.detector.watchesZones = false
        let records = try await VideoCleaner(config: wholeImageOnly).analyze(input) { _ in }
        #expect(records.allSatisfy { $0.verdict == .good })
    }

    /// L'essai sur iPhone : lampe allumée la moitié du temps, 5 fois par seconde, dans une pièce sombre. Toute
    /// image éclairée part, les trous (3 créneaux sur 6) sont recréés : 30 i/s sans image manquante ni lampe.
    @Test(.enabled(if: canSynthesize))
    func halfDutyStrobeRemovedAndSmooth() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await makeHalfDutyVideo(at: input)
        let before = try await trackRanges(of: input)

        let cleaner = VideoCleaner()
        let report = try await cleaner.clean(input: input, output: output) { _ in }

        #expect(report.flashFrames == halfDutyLit.count)
        #expect(report.selection.slots == 90)
        #expect(report.selection.interpolatedSlots > 0)
        #expect(report.failedInterpolations == 0)
        // Durées des deux passes, pour le journal de l'iPhone.
        #expect(report.analysisSeconds > 0)
        #expect(report.writingSeconds > 0)
        // Le plan suivi par le nettoyage, relu à partir de l'analyse.
        let records = try await cleaner.analyze(input) { _ in }
        let source = try await SourceVideo(url: input)
        let plan = cleaner.slotPlan(for: records, duration: source.end, interpolationAvailable: true)
        #expect(plan.report == report.selection)

        let frames = try await decodedFrames(in: output)
        #expect(frames.count == 90)
        for (slot, (plannedSlot, frame)) in zip(plan.slots, frames).enumerated() {
            #expect(frame.luma < litOutputLuma, "créneau \(slot) (\(plannedSlot)) : luma \(frame.luma)")
            // Une image recréée ne porte pas de bande lisible : seule sa luma compte.
            guard !isInterpolated(plannedSlot) else { continue }
            let index = try #require(frame.index, "créneau \(slot) (\(plannedSlot)) : bande illisible")
            #expect(!halfDutyLit.contains(index), "créneau \(slot) : image éclairée \(index)")
        }

        let after = try await trackRanges(of: output)
        let frame = 1.0 / 30
        #expect(abs(after.video.duration.seconds - before.video.duration.seconds) <= frame)
        let audioBefore = try #require(before.audio)
        let audioAfter = try #require(after.audio)
        #expect(abs(audioAfter.duration.seconds - audioBefore.duration.seconds) <= frame)
        #expect(abs(audioAfter.start.seconds - audioBefore.start.seconds) <= frame)
        let packetsBefore = try await audioPackets(in: input)
        let packetsAfter = try await audioPackets(in: output)
        #expect(packetsAfter.count == packetsBefore.count)
        #expect(packetsAfter.data == packetsBefore.data)
    }

    /// Vidéo qui commence lampe allumée, comme celle de l'essai : les premiers créneaux, sans bonne image avant
    /// eux, montrent la première image sans lumière au lieu d'une image éclairée.
    @Test(.enabled(if: canSynthesize))
    func videoStartingLitShowsNoLightAtTheStart() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        // La même lampe, décalée d'une demi-période : images 0 à 11 allumées.
        let lit = Set((0..<360).filter { $0 % 24 < 12 })
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: lit, baseLuma: darkLuma, withAudio: false, flashLuma: lampLuma
        )

        let report = try await VideoCleaner().clean(input: input, output: output) { _ in }

        #expect(report.selection.fallbackSlots == 0)
        let frames = try await decodedFrames(in: output)
        #expect(frames.count == 90)
        #expect(frames.allSatisfy { $0.luma < litOutputLuma })
        // Créneaux 0 à 2 : la première image sans lumière (12), comme le créneau 3 qui la contient.
        #expect(frames.prefix(4).map(\.index) == [12, 12, 12, 12])
    }

    /// Sans interpolation (désactivée, ou appareil qui ne la prend pas en charge) : exactement le choix des
    /// images de la V1, trous comblés en répétant la dernière bonne image.
    @Test func interpolationFallbackWhenDisabled() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await makeHalfDutyVideo(at: input)
        var config = CleanerConfig()
        config.interpolate = false
        let cleaner = VideoCleaner(config: config)

        let report = try await cleaner.clean(input: input, output: output) { _ in }

        let records = try await cleaner.analyze(input) { _ in }
        let source = try await SourceVideo(url: input)
        let v1 = FrameSelector.select(
            times: records.map(\.time), verdicts: records.map(\.verdict), stats: records.map(\.stats),
            duration: source.end, outputFPS: config.outputFPS, maxHoldSeconds: config.maxHoldSeconds
        )
        #expect(report.selection == v1.report)
        #expect(report.selection.interpolatedSlots == 0)
        #expect(report.selection.heldSlots > 0)
        let indices = try await sourceIndices(in: output)
        #expect(indices == v1.indices.map { Optional($0) })
    }

    /// Scène sombre (la lampe de test dans une pièce à 0,1) : toutes les images de la vidéo nettoyée sont
    /// éclaircies, chacune plus claire que sans éclaircir, et leur bande se relit toujours. Une scène claire ne
    /// l'est pas.
    @Test func darkSceneIsBrightenedAndBrightSceneIsNot() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dark = directory.appending(path: "dark.mov")
        try await makeHalfDutyVideo(at: dark)

        var plain = CleanerConfig()
        plain.brightenDarkScenes = false
        let plainOutput = directory.appending(path: "plain.mov")
        let plainReport = try await VideoCleaner(config: plain).clean(input: dark, output: plainOutput) { _ in }
        let brightOutput = directory.appending(path: "brightened.mov")
        let report = try await VideoCleaner().clean(input: dark, output: brightOutput) { _ in }

        #expect(plainReport.brightenedFrames == 0)
        #expect(plainReport.shadowLift == .none)
        #expect(report.brightenedFrames == report.selection.slots)
        #expect(report.shadowLift.shadows > 0.5, "\(report.shadowLift)")
        let before = try await decodedFrames(in: plainOutput)
        let after = try await decodedFrames(in: brightOutput)
        #expect(after.count == before.count)
        // Les images recréées ne portent pas de bande lisible, éclaircies ou non ; les autres gardent la leur.
        #expect(before.contains { $0.index != nil })
        for (slot, (plainFrame, frame)) in zip(before, after).enumerated() {
            #expect(frame.luma > plainFrame.luma + 0.03, "créneau \(slot) : \(plainFrame.luma) → \(frame.luma)")
            if let index = plainFrame.index {
                #expect(frame.index == index, "créneau \(slot) : bande \(index) relue \(String(describing: frame.index))")
            }
        }

        let room = directory.appending(path: "room.mov")
        try await SyntheticVideo.make(
            at: room, fps: sourceFPS, seconds: 1, size: testSize,
            flashIndices: halfDutyLit, baseLuma: 0.5, withAudio: false, flashLuma: 0.95
        )
        let roomReport = try await VideoCleaner().clean(input: room, output: directory.appending(path: "room-out.mov")) { _ in }
        #expect(roomReport.brightenedFrames == 0)
        #expect(roomReport.shadowLift == .none)
    }

    /// Le débruitage (scène sombre) ne change ni le nombre d'images ni les durées, et ne fait jamais échouer
    /// le nettoyage.
    @Test(.enabled(if: canDenoise))
    func denoiseNeverFails() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        try await makeHalfDutyVideo(at: input)

        var results: [(report: CleanReport, frames: Int, ranges: (video: CMTimeRange, audio: CMTimeRange?))] = []
        for denoise in [true, false] {
            var config = CleanerConfig()
            config.denoise = denoise
            let output = directory.appending(path: "output-\(denoise).mov")
            let report = try await VideoCleaner(config: config).clean(input: input, output: output) { _ in }
            results.append((report, try await sourceIndices(in: output).count, try await trackRanges(of: output)))
        }

        let (on, off) = (results[0], results[1])
        #expect(on.report.denoisedFrames == on.report.selection.slots, "toutes les images débruitées")
        #expect(off.report.denoisedFrames == 0)
        #expect(on.report.selection == off.report.selection)
        #expect(on.frames == 90)
        #expect(off.frames == 90)
        let frame = 1.0 / 30
        #expect(abs(on.ranges.video.duration.seconds - off.ranges.video.duration.seconds) <= frame)
        let audioOn = try #require(on.ranges.audio)
        let audioOff = try #require(off.ranges.audio)
        #expect(abs(audioOn.duration.seconds - audioOff.duration.seconds) <= frame)
    }

    /// Une synthèse qui échoue en plein fichier ne fait pas échouer le nettoyage : chaque trou concerné répète
    /// la dernière bonne image d'avant (A). Le bilan garde le plan et compte ces créneaux à part
    /// (`failedInterpolations`), pour qu'un appareil dont la synthèse échoue se voie dans le journal.
    @Test func failedInterpolationHoldsLastGoodFrame() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await makeHalfDutyVideo(at: input)
        var config = CleanerConfig()
        config.denoise = false
        let cleaner = VideoCleaner(config: config)
        let records = try await cleaner.analyze(input) { _ in }
        let source = try await SourceVideo(url: input)
        let plan = cleaner.slotPlan(for: records, duration: source.end, interpolationAvailable: true)
        #expect(plan.report.interpolatedSlots > 0)

        let failing = FailingInterpolator()
        let report = try await cleaner.render(
            records, of: source, to: output,
            canInterpolate: { _, _ in true }, makeInterpolator: { _, _ in failing }
        ) { _ in }

        #expect(failing.calls > 0)
        #expect(report.selection == plan.report)
        #expect(report.failedInterpolations == plan.report.interpolatedSlots)
        let indices = try await sourceIndices(in: output)
        let expected = plan.slots.map { slot -> Int? in
            switch slot {
            case .source(let index), .hold(let index), .fallback(let index): index
            case .interpolate(let from, _, _): from
            }
        }
        #expect(indices == expected)
    }

    /// Une synthèse qui rend des images bien plus sombres que A et B (noires) a échoué sans le dire : chaque trou
    /// concerné répète A, comme pour un échec déclaré, au lieu de montrer du noir dans la vidéo.
    @Test func blackInterpolationHoldsLastGoodFrame() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await makeHalfDutyVideo(at: input)
        var config = CleanerConfig()
        config.denoise = false
        let cleaner = VideoCleaner(config: config)
        let records = try await cleaner.analyze(input) { _ in }
        let source = try await SourceVideo(url: input)
        let plan = cleaner.slotPlan(for: records, duration: source.end, interpolationAvailable: true)

        let black = BlackInterpolator()
        let report = try await cleaner.render(
            records, of: source, to: output,
            canInterpolate: { _, _ in true }, makeInterpolator: { _, _ in black }
        ) { _ in }

        #expect(black.calls > 0)
        #expect(report.failedInterpolations == plan.report.interpolatedSlots)
        let frames = try await decodedFrames(in: output)
        #expect(frames.allSatisfy { $0.luma > 0.05 }, "\(frames.map(\.luma).min() ?? 0)")
    }

    /// La synthèse n'est créée que si le plan a des trous à recréer ; si elle ne peut pas l'être, le plan
    /// repart sans interpolation : exactement la V1.
    @Test func synthesizerCreatedOnlyForGapsElseV1() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = CleanerConfig()
        config.denoise = false
        let cleaner = VideoCleaner(config: config)

        // Éclairs d'une image : chaque créneau a une bonne image, aucun trou.
        let flashes = directory.appending(path: "flashes.mov")
        try await SyntheticVideo.make(
            at: flashes, fps: sourceFPS, seconds: 1, size: testSize,
            flashIndices: Set(stride(from: 0, to: 120, by: 10)), baseLuma: baseLuma, withAudio: false
        )
        var creations = 0
        _ = try await cleaner.render(
            try await cleaner.analyze(flashes) { _ in }, of: try await SourceVideo(url: flashes),
            to: directory.appending(path: "flashes-clean.mov"),
            canInterpolate: { _, _ in true }, makeInterpolator: { _, _ in creations += 1; return nil }
        ) { _ in }
        #expect(creations == 0)

        // La lampe : des trous, mais la synthèse ne démarre pas.
        let lamp = directory.appending(path: "lamp.mov")
        let output = directory.appending(path: "lamp-clean.mov")
        try await makeHalfDutyVideo(at: lamp)
        let records = try await cleaner.analyze(lamp) { _ in }
        let source = try await SourceVideo(url: lamp)
        let report = try await cleaner.render(
            records, of: source, to: output,
            canInterpolate: { _, _ in true }, makeInterpolator: { _, _ in creations += 1; return nil }
        ) { _ in }
        #expect(creations == 1)
        let v1 = FrameSelector.select(
            times: records.map(\.time), verdicts: records.map(\.verdict), stats: records.map(\.stats),
            duration: source.end, outputFPS: config.outputFPS, maxHoldSeconds: config.maxHoldSeconds
        )
        #expect(report.selection == v1.report)
        #expect(try await sourceIndices(in: output) == v1.indices.map { Optional($0) })
    }

    /// Un trou n'est jamais recréé au-delà de 0,5 s, quel que soit `maxInterpolationGap`.
    @Test func interpolationGapIsCappedAtHalfASecond() {
        var config = CleanerConfig()
        config.maxInterpolationGap = 2
        #expect(config.effectiveInterpolationGap(frameStep: 1 / sourceFPS) == 0.5)
        config.detector.maxFlashRunSeconds = 1
        config.maxInterpolationGap = 0.35
        #expect(config.effectiveInterpolationGap(frameStep: 1 / sourceFPS) == 0.5)

        /// Scène de 2 s à 120 i/s dont les images 60..<60 + `litFrames` sont éclairées.
        func plan(litFrames: Int) -> SelectionReport {
            var config = CleanerConfig()
            config.maxInterpolationGap = 2
            let records = (0..<240).map { index in
                FrameRecord(
                    time: Double(index) / sourceFPS,
                    stats: FrameStats(meanLuma: 0.1, saturatedFraction: 0),
                    verdict: (60..<(60 + litFrames)).contains(index) ? .flash : .good
                )
            }
            return VideoCleaner(config: config).slotPlan(for: records, duration: 2, interpolationAvailable: true).report
        }
        // 0,4 s de lumière (écart A–B ≈ 0,41 s) : recréé ; 0,6 s (écart ≈ 0,61 s) : maintien puis repli.
        #expect(plan(litFrames: 48).interpolatedSlots == 12)
        #expect(plan(litFrames: 72).interpolatedSlots == 0)
    }

    /// L'écart recréé couvre toujours le plus long trou qu'une lumière peut laisser : sa durée maximale
    /// (`maxFlashRunSeconds`, 0,3 s) plus une image de chaque côté, au moins `maxInterpolationGap`, au plus 0,5 s.
    @Test func interpolationGapCoversTheLongestLight() {
        var config = CleanerConfig()
        // 120 et 60 i/s : 0,3 s + 2 images reste sous 0,35 s.
        #expect(config.effectiveInterpolationGap(frameStep: 1.0 / 120) == 0.35)
        #expect(config.effectiveInterpolationGap(frameStep: 1.0 / 60) == 0.35)
        #expect(config.effectiveInterpolationGap(frameStep: nil) == 0.35)
        // 30 i/s : une lumière de 10 images (0,3 s) laisse 11/30 s ≈ 0,367 s entre ses deux bonnes images.
        #expect(abs(config.effectiveInterpolationGap(frameStep: 1.0 / 30) - (0.3 + 2.0 / 30 + 1e-6)) < 1e-12)
        #expect(config.effectiveInterpolationGap(frameStep: 1.0 / 30) >= 11.0 / 30)
        // Une limite plus courte que la lumière la plus longue est relevée jusqu'à elle.
        config.maxInterpolationGap = 0.2
        #expect(abs(config.effectiveInterpolationGap(frameStep: 1.0 / 120) - (0.3 + 2.0 / 120 + 1e-6)) < 1e-12)
        // Une limite nulle, négative ou non numérique garde son sens : aucun trou recréé.
        for disabled in [0, -1] as [Double] {
            config.maxInterpolationGap = disabled
            #expect(config.effectiveInterpolationGap(frameStep: 1.0 / 30) == disabled)
        }
        config.maxInterpolationGap = .nan
        #expect(config.effectiveInterpolationGap(frameStep: 1.0 / 30).isNaN)
    }

    /// Filmé à 30 i/s (scène très sombre) : une lampe allumée 9 ou 10 images sur 16 (jusqu'à 0,3 s, la plus
    /// longue lumière) laisse des trous de 10 ou 11 images, tous recréés : aucune image de sortie ne montre la
    /// lampe, pas même à la fin de la vidéo (lampe encore allumée).
    @Test(.enabled(if: canSynthesize), arguments: [9, 10])
    func lightUpToTheLimitIsRemovedAt30fps(litFrames: Int) async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        let lit = SyntheticVideo.squareWave(
            fps: 30, seconds: 3, frequency: 30.0 / 16, litFraction: Double(litFrames) / 16
        )
        try await SyntheticVideo.make(
            at: input, fps: 30, seconds: 3, size: testSize,
            flashIndices: lit, baseLuma: darkLuma, withAudio: false, flashLuma: lampLuma
        )

        let report = try await VideoCleaner().clean(input: input, output: output) { _ in }

        #expect(report.flashFrames == lit.count)
        #expect(report.selection.slots == 90)
        #expect(report.selection.interpolatedSlots > 0)
        let frames = try await decodedFrames(in: output)
        #expect(frames.count == 90)
        for (slot, frame) in frames.enumerated() {
            #expect(frame.luma < litOutputLuma, "créneau \(slot) : luma \(frame.luma)")
        }
    }

    /// La place réservée pour une copie nettoyée suit la règle de débit de l'écriture, à la cadence et au
    /// débit de l'original, son recopié compris : elle couvre la copie réellement écrite.
    @Test(arguments: [120.0, 30.0])
    func estimatedCleanedBytesCoverTheWrittenCopy(fps: Double) async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: fps, seconds: 3, size: testSize,
            flashIndices: [], baseLuma: baseLuma, withAudio: true
        )
        let cleaner = VideoCleaner()

        let estimate = try await cleaner.estimatedCleanedBytes(of: input)

        let source = try await SourceVideo(url: input)
        let videoRate = VideoCleaner.outputBitRate(
            sourceBitRate: Double(source.estimatedDataRate), sourceFPS: fps, outputFPS: 30
        ) / 8
        #expect(Double(estimate) >= videoRate * (source.end - source.start))
        _ = try await cleaner.clean(input: input, output: output) { _ in }
        let written = try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(estimate >= Int64(written))
    }

    /// Une image dont le débruitage échoue est écrite telle quelle : même nombre d'images, dans l'ordre, et
    /// `denoisedFrames` compte seulement les autres.
    @Test(.enabled(if: canDenoise))
    func failedDenoisingWritesFramesUnfiltered() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await makeHalfDutyVideo(at: input)
        var config = CleanerConfig()
        config.interpolate = false
        let cleaner = VideoCleaner(config: config)
        let records = try await cleaner.analyze(input) { _ in }
        let source = try await SourceVideo(url: input)

        // Une image sur dix échoue.
        let steps = FailingFilterSteps { $0.isMultiple(of: 10) }
        let report = try await cleaner.render(
            records, of: source, to: output,
            makeReducer: { NoiseReducer(width: $0, height: $1, strength: $2, wrapProcess: steps.wrap) }
        ) { _ in }

        #expect(steps.calls == 90)
        #expect(report.denoisedFrames == 81)
        let v1 = FrameSelector.select(
            times: records.map(\.time), verdicts: records.map(\.verdict), stats: records.map(\.stats),
            duration: source.end, outputFPS: config.outputFPS, maxHoldSeconds: config.maxHoldSeconds
        )
        #expect(try await sourceIndices(in: output) == v1.indices.map { Optional($0) })
    }

    /// Annulé en pleine écriture d'une scène sombre, synthèse et débruitage en cours : ni sortie ni
    /// `.partial`, et les sessions des processeurs sont closes sans planter (un nouveau nettoyage passe).
    @Test(.enabled(if: canSynthesize && canDenoise))
    func cancellingDarkCleanMidWriteLeavesNoOutput() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await makeHalfDutyVideo(at: input)

        let cancelledAt = Shared<Double?>(nil)
        let task = Task {
            try await VideoCleaner().clean(input: input, output: output) { value in
                guard value > 0.5, value < 1, cancelledAt.value == nil else { return }
                cancelledAt.update { $0 = value }
                cancelCurrentTask()
            }
        }

        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(cancelledAt.value != nil, "annulé pendant l'écriture")
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: partialURL(for: output).path))

        let report = try await VideoCleaner().clean(input: input, output: output) { _ in }
        #expect(report.selection.interpolatedSlots > 0)
        #expect(report.denoisedFrames == 90)
    }

    /// Ordre de relecture d'un plan : un trou interpolé lit A puis B une seule fois, quel que soit le nombre
    /// de ses créneaux ; deux trous qui se suivent avec d'autres A et B lisent chacun les leurs.
    /// Le journal détaille les 5 premiers trous non recréés, puis seulement leur nombre à la fin : un appareil
    /// dont la synthèse échoue sur toute une vidéo ne noie pas le journal.
    @Test func failedInterpolationLogIsRateLimited() {
        var log = FailureLogBudget()
        let detailed = (0..<7).map { _ in log.noteFailure() }

        #expect(detailed == [true, true, true, true, true, false, false])
        #expect(log.failures == 7)
        #expect(log.undetailed == 2)
        #expect(FailureLogBudget().undetailed == 0)
    }

    /// Ce que l'appareil offre, toutes tailles confondues (pour le journal du lancement) : vrai dès qu'une
    /// taille est prise en charge.
    @Test func deviceCapabilitiesMatchTheProcessors() {
        if canSynthesize { #expect(VideoCleaner.deviceSupportsInterpolation) }
        if canDenoise { #expect(VideoCleaner.deviceSupportsDenoise) }
    }

    /// Sans écriture, le bilan prévu n'a ni durées ni échecs.
    @Test func plannedReportHasNoWritingCounters() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        try await makeHalfDutyVideo(at: input)
        let cleaner = VideoCleaner()

        let report = try await cleaner.plannedReport(for: try await cleaner.analyze(input) { _ in }, of: input)

        #expect(report.failedInterpolations == 0)
        #expect(report.denoisedFrames == 0)
        #expect(report.analysisSeconds == 0)
        #expect(report.writingSeconds == 0)
    }

    @Test func sourceReadsCountEachGapOnce() {
        let plan: [SlotPlan] = [
            .source(0),
            .interpolate(from: 3, to: 16, phase: 0.1), .interpolate(from: 3, to: 16, phase: 0.4),
            .interpolate(from: 3, to: 16, phase: 0.7),
            .source(16), .hold(16), .fallback(20),
            .interpolate(from: 23, to: 30, phase: 0.5), .interpolate(from: 25, to: 30, phase: 0.5),
            .source(30),
        ]
        #expect(SlotImages.sourceReads(of: plan) == [0, 3, 16, 16, 16, 20, 23, 30, 25, 30, 30])
    }

    /// Règle du débruitage : scène sombre si la luma médiane des bonnes images est sous 0,3 (les éclairs ne
    /// comptent pas) ; sans bonne image, pas de débruitage.
    @Test func darkSceneUsesMedianOfGoodFrames() {
        func record(_ luma: Double, _ verdict: FrameVerdict = .good) -> FrameRecord {
            FrameRecord(time: 0, stats: FrameStats(meanLuma: luma, saturatedFraction: 0), verdict: verdict)
        }
        #expect(VideoCleaner.isDarkScene([record(0.1), record(0.2), record(0.9)]))
        #expect(!VideoCleaner.isDarkScene([record(0.1), record(0.3), record(0.9)]))
        #expect(VideoCleaner.isDarkScene([record(0.1), record(0.1), record(0.9, .flash), record(0.9, .flash)]))
        #expect(!VideoCleaner.isDarkScene([record(0.1, .flash)]))
        #expect(!VideoCleaner.isDarkScene([]))
    }

    @Test func strobeFramesRemoved() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        let flashes = Set(stride(from: 0, to: 360, by: 10))
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: flashes, baseLuma: baseLuma, withAudio: true
        )

        let report = try await VideoCleaner().clean(input: input, output: output) { _ in }

        #expect(report.flashFrames == flashes.count)
        let indices = try await sourceIndices(in: output)
        #expect(indices.count == 90)
        #expect(indices.allSatisfy { $0 != nil })
        #expect(indices.compactMap { $0 }.allSatisfy { !flashes.contains($0) })
    }

    @Test func durationsPreserved() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: Set(stride(from: 0, to: 360, by: 10)), baseLuma: baseLuma, withAudio: true
        )
        let before = try await trackRanges(of: input)

        _ = try await VideoCleaner().clean(input: input, output: output) { _ in }

        let after = try await trackRanges(of: output)
        let frame = 1.0 / 30
        #expect(abs(after.video.duration.seconds - before.video.duration.seconds) <= frame)
        let audioBefore = try #require(before.audio)
        let audioAfter = try #require(after.audio)
        #expect(abs(audioAfter.duration.seconds - audioBefore.duration.seconds) <= frame)
        // Synchro : l'audio garde ses horodatages d'origine.
        #expect(abs(audioAfter.start.seconds - audioBefore.start.seconds) <= frame)
    }

    @Test func audioCopiedUnchanged() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: Set(stride(from: 0, to: 360, by: 10)), baseLuma: baseLuma, withAudio: true
        )

        _ = try await VideoCleaner().clean(input: input, output: output) { _ in }

        // Recopie sans réencodage : mêmes paquets AAC, octet pour octet.
        let before = try await audioPackets(in: input)
        let after = try await audioPackets(in: output)
        #expect(before.count > 0)
        #expect(after.count == before.count)
        #expect(after.data == before.data)
    }

    @Test func keepsSizeOrientationAndCodec() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        // Vidéo filmée en portrait : capteur en paysage, quart de tour appliqué à l'affichage.
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: testSize.height, ty: 0)
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: [], baseLuma: baseLuma, withAudio: true, transform: portrait
        )

        _ = try await VideoCleaner().clean(input: input, output: output) { _ in }

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let (size, transform, frameRate, formats) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions
        )
        #expect(size == testSize)
        #expect(transform == portrait)
        #expect(abs(frameRate - 30) < 0.01)
        #expect(formats.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_HEVC)
    }

    @Test func worksWithoutAudio() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: [], baseLuma: baseLuma, withAudio: false
        )

        _ = try await VideoCleaner().clean(input: input, output: output) { _ in }

        let tracks = try await AVURLAsset(url: output).load(.tracks)
        #expect(tracks.count == 1)
        #expect(tracks.first?.mediaType == .video)
        let indices = try await sourceIndices(in: output)
        #expect(indices.count == 90)
        #expect(indices.allSatisfy { $0 != nil })
    }

    @Test func cleansFragmentedPartialFile() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        let flashes = Set(stride(from: 0, to: 600, by: 10))
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 5, size: testSize,
            flashIndices: flashes, baseLuma: baseLuma, withAudio: true,
            fragmentInterval: 1, truncateAfterSeconds: 2.5
        )
        // Le fichier est bien coupé : il ne contient pas les 5 s filmées.
        let truncated = try await trackRanges(of: input)
        #expect(truncated.video.end.seconds < 5)

        let report = try await VideoCleaner().clean(input: input, output: output) { _ in }

        #expect(report.totalFrames > 0)
        let cleaned = try await trackRanges(of: output)
        #expect(cleaned.video.duration.seconds >= 2)
        #expect(abs(cleaned.video.duration.seconds - truncated.video.duration.seconds) <= 1.0 / 30)
        #expect(cleaned.audio != nil)
        let indices = try await sourceIndices(in: output)
        #expect(indices.allSatisfy { $0 != nil })
        #expect(indices.compactMap { $0 }.allSatisfy { !flashes.contains($0) })
    }

    /// Comme dans l'app : horodatages à l'horloge de la caméra (≈ un jour après le démarrage de l'iPhone),
    /// fichier fragmenté chaque seconde, terminé normalement ou coupé en plein tournage. AVFoundation ramène la
    /// piste à 0 (début de session), même dans un fichier coupé : le nettoyage ne doit jamais voir 86 400 s de
    /// créneaux vides, ni décaler le son.
    @Test(arguments: [false, true])
    func realStyleTimestampsKeepDurationsAndDropFlashes(truncated: Bool) async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        let flashes = Set(stride(from: 3, to: 600, by: 10))
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: truncated ? 5 : 3, size: testSize,
            flashIndices: flashes, baseLuma: baseLuma, withAudio: true,
            fragmentInterval: 1, truncateAfterSeconds: truncated ? 2.5 : nil, startTime: 86_400.5
        )
        let before = try await trackRanges(of: input)
        if truncated { #expect(before.video.duration.seconds < 5, "le fichier est bien coupé") }

        let report = try await VideoCleaner().clean(input: input, output: output) { _ in }

        let frame = 1.0 / 30
        let after = try await trackRanges(of: output)
        #expect(report.totalFrames > 0)
        #expect(after.video.duration.seconds >= 2)
        #expect(abs(after.video.duration.seconds - before.video.duration.seconds) <= frame)
        let audioBefore = try #require(before.audio)
        let audioAfter = try #require(after.audio)
        #expect(abs(audioAfter.duration.seconds - audioBefore.duration.seconds) <= frame)
        // Synchro : l'écart entre le début du son et celui de l'image ne change pas.
        let offsetBefore = audioBefore.start.seconds - before.video.start.seconds
        let offsetAfter = audioAfter.start.seconds - after.video.start.seconds
        #expect(abs(offsetAfter - offsetBefore) <= frame)

        let indices = try await sourceIndices(in: output)
        #expect(Double(indices.count) * frame >= after.video.duration.seconds - frame)
        #expect(indices.allSatisfy { $0 != nil })
        #expect(indices.compactMap { $0 }.allSatisfy { !flashes.contains($0) })
    }

    @Test func originalUntouched() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: Set(stride(from: 0, to: 360, by: 10)), baseLuma: baseLuma, withAudio: true
        )
        let before = SHA256.hash(data: try Data(contentsOf: input))

        _ = try await VideoCleaner().clean(input: input, output: output) { _ in }

        let after = SHA256.hash(data: try Data(contentsOf: input))
        #expect(before == after)
    }

    @Test func cancellationStopsAndLeavesNoOutput() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: [], baseLuma: baseLuma, withAudio: true
        )

        // Annulation depuis le rappel, à la première progression d'écriture (> 0,5) : elle tombe à coup sûr
        // en pleine écriture, quand le `.partial` existe.
        let partialExisted = Shared<Bool?>(nil)
        let task = Task {
            try await VideoCleaner().clean(input: input, output: output) { value in
                guard value > 0.5, partialExisted.value == nil else { return }
                partialExisted.update { $0 = FileManager.default.fileExists(atPath: partialURL(for: output).path) }
                cancelCurrentTask()
            }
        }

        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(partialExisted.value == true)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: partialURL(for: output).path))
    }

    @Test func cancellationDuringAnalysisLeavesNoOutput() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: [], baseLuma: baseLuma, withAudio: true
        )

        // Annulation à la toute première progression : l'analyse vient de commencer.
        let progress = Shared<[Double]>([])
        let task = Task {
            try await VideoCleaner().clean(input: input, output: output) { value in
                let isFirst = progress.update { values in
                    values.append(value)
                    return values.count == 1
                }
                if isFirst { cancelCurrentTask() }
            }
        }

        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        let values = progress.value
        #expect(values.first.map { $0 > 0 && $0 < 0.5 } == true, "annulé pendant l'analyse")
        #expect(values.allSatisfy { $0 < 0.5 }, "arrêté avant l'écriture")
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: partialURL(for: output).path))
    }

    @Test func existingOutputSurvivesCancelledOrFailedRun() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: [], baseLuma: baseLuma, withAudio: true
        )
        let previous = Data("ancienne sortie".utf8)
        try previous.write(to: output)

        // Annulé en pleine écriture.
        let task = Task {
            try await VideoCleaner().clean(input: input, output: output) { value in
                if value > 0.5 { cancelCurrentTask() }
            }
        }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(try Data(contentsOf: output) == previous)
        #expect(!FileManager.default.fileExists(atPath: partialURL(for: output).path))

        // En échec : l'entrée n'est pas une vidéo.
        let notAVideo = directory.appending(path: "not-a-video.mov")
        try Data("pas une vidéo".utf8).write(to: notAVideo)
        await #expect(throws: (any Error).self) {
            try await VideoCleaner().clean(input: notAVideo, output: output) { _ in }
        }
        #expect(try Data(contentsOf: output) == previous)
        #expect(!FileManager.default.fileExists(atPath: partialURL(for: output).path))
    }

    @Test func sourceChangedBetweenPassesFails() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: [], baseLuma: baseLuma, withAudio: true
        )
        let previous = Data("ancienne sortie".utf8)
        try previous.write(to: output)
        let cleaner = VideoCleaner()
        let records = try await cleaner.analyze(input) { _ in }
        let source = try await SourceVideo(url: input)

        // L'analyse a une image de moins que la relecture : à partir de l'image 1, les rangs sont décalés et
        // l'image relue au rang choisi n'a plus l'horodatage de l'analyse.
        var shifted = records
        shifted.remove(at: 1)
        await #expect(throws: VideoCleanerError.sourceChanged) {
            _ = try await cleaner.render(shifted, of: source, to: output) { _ in }
        }

        // L'analyse a une image de plus en fin de piste (rang 360), seule bonne image du dernier créneau,
        // donc choisie : la relecture s'arrête avant de l'atteindre.
        var longer = records
        for index in 356..<360 { longer[index].verdict = .flash }
        longer.append(FrameRecord(time: 2.995, stats: records[359].stats, verdict: .good))
        await #expect(throws: VideoCleanerError.sourceChanged) {
            _ = try await cleaner.render(longer, of: source, to: output) { _ in }
        }

        #expect(try Data(contentsOf: output) == previous)
        #expect(!FileManager.default.fileExists(atPath: partialURL(for: output).path))
    }

    @Test func unorderedAnalysisTimesFailWithoutOutput() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: [], baseLuma: baseLuma, withAudio: true
        )
        let cleaner = VideoCleaner()
        let records = try await cleaner.analyze(input) { _ in }
        let source = try await SourceVideo(url: input)

        // Horodatages qui reculent : l'image 40 passe au créneau 50, l'image 200 au créneau 10. Le choix des
        // images reviendrait en arrière (créneau 50 -> image 40 après l'image 196 au créneau 49).
        var unordered = records
        unordered[40].time = records[200].time
        unordered[200].time = records[40].time
        await #expect(throws: VideoCleanerError.unorderedFrames) {
            _ = try await cleaner.render(unordered, of: source, to: output) { _ in }
        }

        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: partialURL(for: output).path))
    }

    @Test func replacesExistingOutput() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: [], baseLuma: baseLuma, withAudio: true
        )
        // Restes d'un essai précédent : une ancienne sortie et un `.partial` d'un nettoyage interrompu.
        try Data("ancienne sortie".utf8).write(to: output)
        try Data("nettoyage interrompu".utf8).write(to: partialURL(for: output))

        _ = try await VideoCleaner().clean(input: input, output: output) { _ in }

        #expect(try await sourceIndices(in: output).count == 90)
        #expect(!FileManager.default.fileExists(atPath: partialURL(for: output).path))
    }

    @Test func refusesToOverwriteInput() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 1, size: testSize,
            flashIndices: [], baseLuma: baseLuma, withAudio: false
        )
        let before = SHA256.hash(data: try Data(contentsOf: input))
        let link = directory.appending(path: "link.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
        // Une entrée qui porte le nom du `.partial` de la sortie : il serait effacé en début de nettoyage.
        let namedLikePartial = directory.appending(path: "clip.mov.partial")
        try FileManager.default.copyItem(at: input, to: namedLikePartial)

        let cases: [(input: URL, output: URL)] = [
            (input, input),
            (link, input),  // entrée atteinte par un lien symbolique vers la sortie
            (input, link),  // sortie qui est un lien symbolique vers l'entrée
            (namedLikePartial, directory.appending(path: "clip.mov")),
        ]
        for paths in cases {
            await #expect(throws: VideoCleanerError.outputIsInput) {
                try await VideoCleaner().clean(input: paths.input, output: paths.output) { _ in }
            }
        }
        #expect(SHA256.hash(data: try Data(contentsOf: input)) == before)
        #expect(SHA256.hash(data: try Data(contentsOf: namedLikePartial)) == before)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == input.path)
    }

    @Test func analyzeMarksSyntheticFlashes() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let flashes = Set(stride(from: 5, to: 360, by: 10))
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: flashes, baseLuma: baseLuma, withAudio: true
        )

        let records = try await VideoCleaner().analyze(input) { _ in }

        #expect(records.count == 360)
        #expect(records.indices.allSatisfy { abs(records[$0].time - Double($0) / sourceFPS) < 1e-6 })
        let flagged = Set(records.indices.filter { records[$0].verdict == .flash })
        #expect(flagged == flashes)
    }

    @Test func progressIsMonotoneAndEndsAtOne() async throws {
        let directory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.mov")
        let output = directory.appending(path: "output.mov")
        try await SyntheticVideo.make(
            at: input, fps: sourceFPS, seconds: 3, size: testSize,
            flashIndices: [], baseLuma: baseLuma, withAudio: true
        )

        let analysis = Shared<[Double]>([])
        _ = try await VideoCleaner().analyze(input) { value in analysis.update { $0.append(value) } }
        #expect(isMonotone(analysis.value))
        #expect(analysis.value.allSatisfy { (0...1).contains($0) })
        #expect(analysis.value.last == 1)

        let cleaning = Shared<[Double]>([])
        _ = try await VideoCleaner().clean(input: input, output: output) { value in cleaning.update { $0.append(value) } }
        let values = cleaning.value
        #expect(isMonotone(values))
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(values.contains { $0 > 0 && $0 <= 0.5 }, "analyse : 0…0,5")
        #expect(values.contains { $0 > 0.5 && $0 < 1 }, "écriture : 0,5…1")
        #expect(values.last == 1)
    }

    /// Échantillon pour `strobe-tune` et l'app (`build/` est ignoré par git).
    @Test func writesSampleForCLI() async throws {
        let sample = repositoryRoot().appending(path: "build/samples/strobe-sample.mov")
        try FileManager.default.createDirectory(
            at: sample.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        try await SyntheticVideo.make(
            at: sample, fps: sourceFPS, seconds: 5, size: CGSize(width: 640, height: 360),
            flashIndices: Set(stride(from: 0, to: 600, by: 10)), baseLuma: baseLuma, withAudio: true
        )

        let ranges = try await trackRanges(of: sample)
        #expect(abs(ranges.video.duration.seconds - 5) <= 1 / sourceFPS)
        #expect(ranges.audio != nil)

        // La lampe du premier essai : allumée la moitié du temps, 5 fois par seconde, pièce sombre.
        let halfDuty = repositoryRoot().appending(path: "build/samples/half-duty-sample.mov")
        try await SyntheticVideo.make(
            at: halfDuty, fps: sourceFPS, seconds: 5, size: CGSize(width: 640, height: 360),
            flashIndices: SyntheticVideo.squareWave(fps: sourceFPS, seconds: 5, frequency: 5, litFraction: 0.5),
            baseLuma: darkLuma, withAudio: true, flashLuma: lampLuma
        )
        #expect(abs(try await trackRanges(of: halfDuty).video.duration.seconds - 5) <= 1 / sourceFPS)

        // La même lampe pour le bouton de débogage de l'app (copiée dans App/DebugResources/strobe-half-duty.mov) :
        // filmée comme sur l'iPhone, capteur en paysage 1280×720 et quart de tour à l'affichage (720×1280).
        let appSample = repositoryRoot().appending(path: "build/samples/strobe-half-duty.mov")
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0)
        try await SyntheticVideo.make(
            at: appSample, fps: sourceFPS, seconds: 5, size: CGSize(width: 1280, height: 720),
            flashIndices: SyntheticVideo.squareWave(fps: sourceFPS, seconds: 5, frequency: 5, litFraction: 0.5),
            baseLuma: darkLuma, withAudio: true, transform: portrait, flashLuma: lampLuma
        )
        let appRanges = try await trackRanges(of: appSample)
        #expect(abs(appRanges.video.duration.seconds - 5) <= 1 / sourceFPS)
        #expect(appRanges.audio != nil)
        // Embarquée dans l'app (Debug) : moins de 2 Mo.
        let size = try #require(try appSample.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size < 2_000_000, "\(size) octets")
    }
}
