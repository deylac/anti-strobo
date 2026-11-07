import Foundation
import StrobeCore
import Synchronization

/// Échec d'exécution (code de sortie 1) dont le message est déjà prêt pour l'utilisateur.
struct ToolError: Error {
    var message: String
}

func writeToStandardError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

/// Message lisible d'une erreur d'exécution (les `VideoCleanerError` n'ont pas de texte par défaut).
func describe(_ error: any Error) -> String {
    switch error {
    case let error as ToolError: error.message
    case VideoCleanerError.noVideoTrack: "le fichier n'a pas de piste vidéo"
    case VideoCleanerError.noVideoFrames: "la piste vidéo ne donne aucune image"
    case VideoCleanerError.outputIsInput: "la sortie est le fichier d'entrée, qui ne doit pas être modifié"
    case VideoCleanerError.sourceChanged: "le fichier d'entrée a changé pendant le nettoyage"
    case VideoCleanerError.readFailed: "la lecture du fichier a échoué"
    case VideoCleanerError.writeFailed: "l'écriture du fichier a échoué"
    default: error.localizedDescription
    }
}

/// Avancement en pourcentage entier, réécrit sur une seule ligne de stderr (le rapport reste seul sur stdout).
final class ProgressPrinter: Sendable {
    private let label: String
    /// Le retour chariot n'a de sens que sur un terminal : redirigé vers un fichier ou un tube, rien n'est écrit.
    private let isTerminal = isatty(STDERR_FILENO) != 0
    private let lastPercent = Mutex(-1)

    init(_ label: String) {
        self.label = label
    }

    /// Appelée depuis le fil du nettoyage : n'écrit que quand le pourcentage change.
    func update(_ fraction: Double) {
        guard isTerminal else { return }
        let percent = Int((min(1, max(0, fraction)) * 100).rounded(.down))
        let changed = lastPercent.withLock { last in
            defer { last = percent }
            return percent != last
        }
        if changed { writeToStandardError("\r\(label) : \(percent) %") }
    }

    /// Termine la ligne d'avancement (rien si rien n'a été affiché).
    func finish() {
        if lastPercent.withLock({ $0 }) >= 0 { writeToStandardError("\n") }
    }
}

/// Une ligne par image, avec en-tête, nombres au point décimal quelle que soit la langue du système.
func csvText(for records: [FrameRecord]) -> String {
    var lines = ["index,time,meanLuma,saturatedFraction,verdict"]
    lines.reserveCapacity(records.count + 1)
    for (index, record) in records.enumerated() {
        let verdict = record.verdict == .flash ? "flash" : "good"
        lines.append(
            String(format: "%d,%.6f,%.6f,%.6f,", index, record.time, record.stats.meanLuma, record.stats.saturatedFraction)
                + verdict
        )
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Écrit le CSV de `records` à `url` (écriture atomique) ; lève `ToolError` si l'écriture échoue.
func writeCSV(for records: [FrameRecord], to url: URL) throws {
    do {
        try Data(csvText(for: records).utf8).write(to: url, options: .atomic)
    } catch {
        throw ToolError(message: "écriture du CSV impossible (\(url.path)) : \(error.localizedDescription)")
    }
}

/// Bilan affiché sur stdout, le même avec ou sans nettoyage ; les échecs de synthèse, les images débruitées et
/// les durées des deux passes ne sont connus qu'après un nettoyage (`cleaned`).
func reportText(for report: CleanReport, cleaned: Bool) -> String {
    let selection = report.selection
    var lines = [
        "Images analysées : \(report.totalFrames)",
        "Images brûlées (éclairs) : \(report.flashFrames)",
        "Créneaux de sortie : \(selection.slots)",
        "Créneaux sources : \(selection.sourceSlots)",
        "Images recréées : \(selection.interpolatedSlots)",
        "Créneaux répétés : \(selection.heldSlots)",
        "Créneaux de repli : \(selection.fallbackSlots)",
    ]
    if cleaned {
        lines += [
            "Recréations en échec (image d'avant répétée) : \(report.failedInterpolations)",
            "Images débruitées : \(report.denoisedFrames)",
            String(
                format: "Images éclaircies : %d (+%.2f IL, ombres %.2f)",
                report.brightenedFrames, report.shadowLift.exposureEV, report.shadowLift.shadows
            ),
            String(format: "Durée de l'analyse : %.2f s", report.analysisSeconds),
            String(format: "Durée de l'écriture : %.2f s", report.writingSeconds),
        ]
    }
    return lines.joined(separator: "\n") + "\n"
}
