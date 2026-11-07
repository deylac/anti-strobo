#if DEBUG
import Foundation
import os

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "Cleaning")

/// Débogage : les vidéos de test embarquées (Debug seulement, `App/DebugResources/`).
enum DebugSample: String {
    /// Éclairs d'une image, une image sur dix, scène moyenne : le choix des images sans interpolation.
    case flashes = "strobe-sample"
    /// Lampe à 5 Hz allumée la moitié du temps dans une pièce sombre, filmée en portrait : interpolation des
    /// trous et débruitage, sans avoir à filmer.
    case halfDutyLamp = "strobe-half-duty"
}

extension CleaningCoordinator {
    /// Débogage : copie la vidéo de test `sample` dans `Recordings/` sous un nouveau nom, puis la met au nettoyage
    /// comme un enregistrement qui vient de finir.
    func cleanDebugSample(_ sample: DebugSample = .flashes) async {
        guard let source = Bundle.main.url(forResource: sample.rawValue, withExtension: "mov") else {
            log.error("Vidéo de test absente du paquet : \(sample.rawValue, privacy: .public)")
            return
        }
        let destination: URL
        do {
            destination = try CameraController.recordingsDirectory().appending(path: "\(UUID().uuidString).mov")
            // Écriture atomique : le fichier n'apparaît dans `Recordings/` que complet.
            try Data(contentsOf: source).write(to: destination, options: .atomic)
        } catch {
            log.error("Copie de la vidéo de test impossible : \(String(describing: error), privacy: .public)")
            return
        }
        log.notice("Vidéo de test \(sample.rawValue, privacy: .public) mise au nettoyage")
        await enqueue(original: destination)
    }
}
#endif
