import CoreVideo
import Foundation
import os

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "VideoCleaner")

/// Images de la vidéo nettoyée, créneau par créneau, d'après le plan (`FrameSelector.plan`) : relit la source
/// dans l'ordre et recrée les images des trous.
///
/// Chaque image source utilisée (créneau source, répété ou de repli, A et B d'une interpolation) doit porter
/// l'horodatage relevé à l'analyse, sinon `VideoCleanerError.sourceChanged` : les images sont repérées par
/// leur rang, et une relecture qui ne redonne pas la même suite ferait une vidéo fausse.
///
/// Les créneaux interpolés qui se suivent avec les mêmes A et B (tout un trou) sont recréés d'un seul appel à
/// la synthèse : on garde A, on lit jusqu'à B (les images brûlées entre les deux sont lâchées au passage), puis
/// on demande toutes leurs phases. Mémoire : A, B et les images du trou au plus. Si la synthèse échoue, ou rend
/// une image plus de deux fois plus sombre que A et que B (`FrameProcessingError.implausibleResult`), tout
/// le trou répète A (compté dans `failedInterpolations`, journalisé pour les `FailureLogBudget.detailedFailures`
/// premiers trous) : le nettoyage n'échoue jamais à cause d'elle.
struct SlotImages {
    /// Écart toléré (secondes) entre l'horodatage d'une image relue et celui relevé à l'analyse.
    private static let timeTolerance = 1e-6

    private let plan: [SlotPlan]
    /// Horodatage de chaque image source relevé à l'analyse.
    private let times: [Double]
    private let frames: VideoFrames
    private let interpolator: (any FrameInterpolator)?

    /// Prochain créneau à rendre.
    private var slot = 0
    /// Rang de la dernière image source lue (-1 avant la première) et cette image.
    private var sourceIndex = -1
    private var current: (time: Double, image: CVPixelBuffer)?
    /// Créneaux interpolés au plan qui répètent A, faute de synthèse.
    private(set) var failedInterpolations = 0
    /// Trous non recréés, et lesquels sont détaillés dans le journal.
    private(set) var failureLog = FailureLogBudget()

    /// - Throws: `VideoCleanerError.unorderedFrames` si les images à lire reculent (horodatages de l'analyse qui
    ///   reculent : la relecture, dans l'ordre, ne peut pas revenir en arrière) ; `VideoCleanerError.sourceChanged`
    ///   si le plan désigne une image absente de l'analyse. Une erreur plutôt qu'un arrêt de l'app : le travail
    ///   reste à reprendre et les autres continuent.
    init(plan: [SlotPlan], times: [Double], frames: VideoFrames, interpolator: (any FrameInterpolator)?) throws {
        let reads = Self.sourceReads(of: plan)
        guard zip(reads, reads.dropFirst()).allSatisfy({ $0 <= $1 }) else { throw VideoCleanerError.unorderedFrames }
        guard reads.allSatisfy({ times.indices.contains($0) }) else { throw VideoCleanerError.sourceChanged }
        self.plan = plan
        self.times = times
        self.frames = frames
        self.interpolator = interpolator
    }

    /// Vrai une fois tous les créneaux rendus.
    var isFinished: Bool { slot == plan.count }

    /// Images du créneau suivant : une seule, ou celles de tout un trou interpolé, dans l'ordre des créneaux.
    /// Une fois tous les créneaux rendus, arrête la relecture et ne rend plus rien.
    mutating func next(_ checkpoint: inout CancellationCheckpoint) async throws -> [CVPixelBuffer] {
        guard slot < plan.count else { return [] }
        defer { if isFinished { frames.cancel() } }

        switch plan[slot] {
        case .source(let index), .hold(let index), .fallback(let index):
            let image = try await read(index, &checkpoint)
            slot += 1
            return [image]

        case .interpolate(let from, let to, _):
            var phases: [Float] = []
            while slot < plan.count, case .interpolate(from, to, let phase) = plan[slot] {
                phases.append(Float(phase))
                slot += 1
            }
            let a = try await read(from, &checkpoint)
            let b = try await read(to, &checkpoint)
            do {
                guard let interpolator else { throw FrameProcessingError.unavailable }
                let images = try await interpolator.frames(between: a, and: b, phases: phases)
                guard images.count == phases.count else { throw FrameProcessingError.invalidParameters }
                // Une image recréée entre A et B n'est pas bien plus sombre que les deux : la recréation d'Apple
                // rend du noir, sans erreur, quand l'iPhone verrouillé ne lui prête plus le GPU.
                let floor = min(LumaSampler.stats(of: a).meanLuma, LumaSampler.stats(of: b).meanLuma) / 2
                guard images.allSatisfy({ LumaSampler.stats(of: $0).meanLuma >= floor }) else {
                    throw FrameProcessingError.implausibleResult
                }
                return images
            } catch {
                if failureLog.noteFailure() {
                    log.error("""
                        Images \(from)…\(to) : \(phases.count) image(s) non recréée(s) \
                        (\(String(describing: error), privacy: .public)), image \(from) répétée
                        """)
                }
                failedInterpolations += phases.count
                return Array(repeating: a, count: phases.count)
            }
        }
    }

    /// Images sources lues pour rendre `plan`, dans l'ordre de lecture : celle de chaque créneau source, répété
    /// ou de repli, et A puis B une seule fois par trou interpolé (créneaux qui se suivent avec mêmes A et B).
    static func sourceReads(of plan: [SlotPlan]) -> [Int] {
        var reads: [Int] = []
        var previous: SlotPlan?
        for slot in plan {
            switch slot {
            case .source(let index), .hold(let index), .fallback(let index):
                reads.append(index)
            case .interpolate(let from, let to, _):
                if case .interpolate(from, to, _)? = previous { break }
                reads += [from, to]
            }
            previous = slot
        }
        return reads
    }

    /// Image source `index`, lue en avançant dans la source (les indices ne reculent jamais) ; vérifie qu'elle
    /// porte l'horodatage de l'analyse.
    private mutating func read(_ index: Int, _ checkpoint: inout CancellationCheckpoint) async throws -> CVPixelBuffer {
        while sourceIndex < index {
            guard let frame = try frames.next() else { throw VideoCleanerError.sourceChanged }
            sourceIndex += 1
            current = frame
            try await checkpoint.step()
        }
        guard let frame = current, sourceIndex == index, abs(frame.time - times[index]) <= Self.timeTolerance else {
            throw VideoCleanerError.sourceChanged
        }
        return frame.image
    }
}

/// Combien d'échecs de synthèse détailler dans le journal : les `detailedFailures` premiers, puis seulement leur
/// nombre à la fin du nettoyage. Un appareil dont la synthèse échoue sur toute une vidéo (une heure : des
/// milliers de trous) ne noie pas le journal.
struct FailureLogBudget: Equatable {
    /// Échecs détaillés au plus.
    static let detailedFailures = 5

    /// Échecs comptés.
    private(set) var failures = 0

    /// Compte un échec ; vrai s'il faut le détailler.
    mutating func noteFailure() -> Bool {
        failures += 1
        return failures <= Self.detailedFailures
    }

    /// Échecs comptés mais pas détaillés.
    var undetailed: Int { max(0, failures - Self.detailedFailures) }
}
