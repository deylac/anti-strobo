import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import StrobeCore

/// Taille des images de test.
private let size = CGSize(width: 320, height: 180)

/// L'appareil sait recréer des images, et débruiter, à cette taille : sinon les tests qui en ont besoin
/// sont sautés (Mac sans ces traitements, simulateur).
private let canSynthesize = FrameSynthesizer.isSupported(width: Int(size.width), height: Int(size.height))
private let canDenoise = NoiseReducer.isSupported(width: Int(size.width), height: Int(size.height))

/// Luma moyenne d'une image 420 plein écart.
private func luma(of buffer: CVPixelBuffer) -> Double {
    LumaSampler.stats(of: buffer, step: 1).meanLuma
}

/// Vrai si `buffer` a le format et la taille des images décodées par le nettoyage.
private func isCleanerFrame(_ buffer: CVPixelBuffer) -> Bool {
    CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        && CVPixelBufferGetWidth(buffer) == Int(size.width)
        && CVPixelBufferGetHeight(buffer) == Int(size.height)
}

/// Matrice YCbCr d'une image (`nil` sans attachement).
private func matrix(of buffer: CVPixelBuffer) -> String? {
    CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
}

/// Image de test marquée en matrice SD (601), comme la vidéo de la lampe : autre que la matrice HD que
/// VideoToolbox suppose quand une image n'en dit rien.
private func standardDefinitionFrame(index: Int, luma: Double) throws -> CVPixelBuffer {
    let buffer = try SyntheticVideo.frame(index: index, luma: luma, size: size)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
    return buffer
}

/// Étape de filtrage qui échoue pour les appels dont le rang (à partir de 1) est dans `failing`, et laisse
/// faire le vrai filtre pour les autres.
final class FailingFilterSteps {
    struct Failure: Error {}
    private let failing: (Int) -> Bool
    private(set) var calls = 0

    init(failing: @escaping (Int) -> Bool) {
        self.failing = failing
    }

    func wrap(_ process: @escaping NoiseReducer.Process) -> NoiseReducer.Process {
        { parameters in
            self.calls += 1
            if self.failing(self.calls) { throw Failure() }
            try await process(parameters)
        }
    }
}

/// Enrobe le filtrage du débruitage : l'appel n° `blackCall` « réussit » en rendant du noir, comme le GPU refusé
/// quand l'iPhone se verrouille pendant le nettoyage.
final class BlackFilterSteps {
    private let blackCall: Int
    private(set) var calls = 0

    init(blackCall: Int) {
        self.blackCall = blackCall
    }

    func wrap(_ process: @escaping NoiseReducer.Process) -> NoiseReducer.Process {
        { parameters in
            self.calls += 1
            try await process(parameters)
            guard self.calls == self.blackCall, let filter = parameters as? VTTemporalNoiseFilterParameters,
                  let destination = filter.destinationFrame?.buffer else { return }
            let black = try SyntheticVideo.frame(index: 0, luma: 0, size: CGSize(
                width: CVPixelBufferGetWidth(destination), height: CVPixelBufferGetHeight(destination)
            ))
            CVPixelBufferLockBaseAddress(black, [])
            memset(CVPixelBufferGetBaseAddressOfPlane(black, 0), 0,
                   CVPixelBufferGetBytesPerRowOfPlane(black, 0) * CVPixelBufferGetHeightOfPlane(black, 0))
            CVPixelBufferUnlockBaseAddress(black, [])
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
            VTPixelTransferSessionTransferImage(session!, from: black, to: destination)
        }
    }
}

// Le traitement passe par le GPU et le moteur neuronal : en série, comme les tests vidéo.
@Suite("Traitement des images", .serialized)
struct FrameProcessingTests {
    @Test(.enabled(if: canSynthesize))
    func synthesizerRecreatesInBetweenFrames() async throws {
        let synthesizer = try #require(FrameSynthesizer(width: Int(size.width), height: Int(size.height)))
        defer { synthesizer.finish() }
        let a = try standardDefinitionFrame(index: 7, luma: 0.1)
        let b = try standardDefinitionFrame(index: 7, luma: 0.3)

        let frames = try await synthesizer.frames(between: a, and: b, phases: [0.25, 0.5, 0.75])

        #expect(frames.count == 3)
        #expect(synthesizer.processorCalls == 1)
        #expect(frames.allSatisfy(isCleanerFrame))
        // De A vers B : chaque image recréée est entre les deux, dans l'ordre des phases.
        let lumas = [luma(of: a)] + frames.map(luma) + [luma(of: b)]
        #expect(zip(lumas, lumas.dropFirst()).allSatisfy { $0 < $1 }, "\(lumas)")
        // Même bande dans A et B : l'image recréée la garde.
        #expect(frames.allSatisfy { SyntheticVideo.decodeIndex(from: $0) == 7 })
        // Couleurs de A, pour l'encodeur (le processeur rend des images sans couleurs).
        #expect(frames.allSatisfy { matrix(of: $0) == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String })
    }

    /// Un long trou est recréé en appels de 4 images au plus (mêmes A et B), sans rupture entre les appels.
    @Test(.enabled(if: canSynthesize))
    func longGapIsRecreatedInCallsOfFourFrames() async throws {
        let synthesizer = try #require(FrameSynthesizer(width: Int(size.width), height: Int(size.height)))
        defer { synthesizer.finish() }
        let a = try standardDefinitionFrame(index: 5, luma: 0.1)
        let b = try standardDefinitionFrame(index: 5, luma: 0.4)
        let phases: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]

        let frames = try await synthesizer.frames(between: a, and: b, phases: phases)

        #expect(FrameSynthesizer.maximumFramesPerCall == 4)
        #expect(synthesizer.processorCalls == 3)
        #expect(frames.count == phases.count)
        let lumas = [luma(of: a)] + frames.map(luma) + [luma(of: b)]
        #expect(zip(lumas, lumas.dropFirst()).allSatisfy { $0 < $1 }, "\(lumas)")
    }

    @Test(.enabled(if: canSynthesize))
    func synthesizerWithoutPhasesGivesNothing() async throws {
        let synthesizer = try #require(FrameSynthesizer(width: Int(size.width), height: Int(size.height)))
        defer { synthesizer.finish() }
        let a = try SyntheticVideo.frame(index: 1, luma: 0.1, size: size)

        #expect(try await synthesizer.frames(between: a, and: a, phases: []).isEmpty)
        #expect(synthesizer.processorCalls == 0)
    }

    @Test(.enabled(if: canSynthesize))
    func identicalFramesGiveTheSameImage() async throws {
        let synthesizer = try #require(FrameSynthesizer(width: Int(size.width), height: Int(size.height)))
        defer { synthesizer.finish() }
        let a = try SyntheticVideo.frame(index: 3, luma: 0.2, size: size)

        let frames = try await synthesizer.frames(between: a, and: a, phases: [0.5])

        // Aller-retour par le format du processeur sans dérive de luma (pleine plage gardée).
        #expect(abs(luma(of: frames[0]) - luma(of: a)) < 0.01)
    }

    @Test(.enabled(if: canDenoise))
    func reducerKeepsEveryFrameInOrder() async throws {
        let reducer = try #require(NoiseReducer(width: Int(size.width), height: Int(size.height)))
        defer { reducer.finish() }
        let inputs = try (0..<6).map { try standardDefinitionFrame(index: 100 + $0, luma: 0.15) }

        var outputs: [NoiseReducer.Output] = []
        for input in inputs {
            outputs += await reducer.push(input)
        }
        outputs += await reducer.flush()

        #expect(outputs.count == inputs.count)
        #expect(outputs.allSatisfy { $0.isFiltered })
        #expect(outputs.allSatisfy { isCleanerFrame($0.image) })
        #expect(outputs.map { SyntheticVideo.decodeIndex(from: $0.image) } == (100..<106).map { Optional($0) })
        #expect(outputs.allSatisfy { abs(luma(of: $0.image) - luma(of: inputs[0])) < 0.01 })
        #expect(outputs.allSatisfy { matrix(of: $0.image) == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String })
        // Après `flush`, plus rien n'est retenu.
        #expect(await reducer.flush().isEmpty)
    }

    /// Une image dont le filtrage échoue sort telle quelle, à sa place ; les autres sont filtrées.
    @Test(.enabled(if: canDenoise))
    func failedFilteringGivesTheFrameUnfiltered() async throws {
        let steps = FailingFilterSteps { $0 == 3 }
        let reducer = try #require(NoiseReducer(width: Int(size.width), height: Int(size.height), wrapProcess: steps.wrap))
        defer { reducer.finish() }
        let inputs = try (0..<6).map { try standardDefinitionFrame(index: 100 + $0, luma: 0.15) }

        var outputs: [NoiseReducer.Output] = []
        for input in inputs {
            outputs += await reducer.push(input)
        }
        outputs += await reducer.flush()

        #expect(steps.calls == inputs.count)
        #expect(outputs.count == inputs.count)
        #expect(outputs.map(\.isFiltered) == [true, true, false, true, true, true])
        #expect(outputs[2].image === inputs[2])
        #expect(outputs.map { SyntheticVideo.decodeIndex(from: $0.image) } == (100..<106).map { Optional($0) })
    }

    /// Une image que le filtrage rend noire (GPU refusé, sans erreur) sort telle quelle, non filtrée.
    @Test(.enabled(if: canDenoise))
    func blackFilteringGivesTheFrameUnfiltered() async throws {
        let steps = BlackFilterSteps(blackCall: 3)
        let reducer = try #require(NoiseReducer(width: Int(size.width), height: Int(size.height), wrapProcess: steps.wrap))
        defer { reducer.finish() }
        let inputs = try (0..<6).map { try standardDefinitionFrame(index: 100 + $0, luma: 0.15) }

        var outputs: [NoiseReducer.Output] = []
        for input in inputs {
            outputs += await reducer.push(input)
        }
        outputs += await reducer.flush()

        #expect(outputs.map(\.isFiltered) == [true, true, false, true, true, true])
        #expect(outputs[2].image === inputs[2])
    }

    @Test(.enabled(if: canDenoise))
    func reducerFiltersASingleFrame() async throws {
        let reducer = try #require(NoiseReducer(width: Int(size.width), height: Int(size.height)))
        defer { reducer.finish() }

        #expect(await reducer.push(try SyntheticVideo.frame(index: 9, luma: 0.15, size: size)).isEmpty)
        let outputs = await reducer.flush()

        #expect(outputs.count == 1)
        #expect(outputs.first.map { SyntheticVideo.decodeIndex(from: $0.image) } == 9)
    }

    @Test func unsupportedSizesAreRefused() {
        #expect(FrameSynthesizer(width: 0, height: 0) == nil)
        #expect(NoiseReducer(width: 0, height: 0) == nil)
        #expect(!FrameSynthesizer.isSupported(width: 0, height: 0))
        #expect(!NoiseReducer.isSupported(width: 0, height: 0))
    }
}
