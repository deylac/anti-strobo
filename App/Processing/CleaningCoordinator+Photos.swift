import Foundation
import os
import Photos
import StrobeCore

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "Cleaning")

/// Accès « ajout seulement » à la pellicule et ajout des vidéos.
extension CleaningCoordinator {
    enum PhotosFailure: Error {
        case denied
        case notDetermined
        case saveFailed

        var message: String {
            switch self {
            case .denied: StatusText.photosDenied
            case .notDetermined: StatusText.photosNotDetermined
            case .saveFailed: StatusText.photosSaveFailed
            }
        }
    }

    /// Pose la question de l'accès à Photos tant que l'app est au premier plan, suite au toucher : à la fin du
    /// nettoyage, l'app peut être en arrière-plan, où iOS ne peut pas afficher la demande.
    func askPhotosAccessIfNeeded() {
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined else { return }
        photosAccessRequest = Task { await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
    }

    /// Accès « ajout seulement » au moment de ranger. Si la question posée au toucher attend encore sa réponse, on
    /// l'attend ; sans question en cours, on ne la pose pas ici (l'app peut être en arrière-plan) : le travail
    /// restera `.cleaned` et la question sera posée au prochain toucher.
    private func photosAccess() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .notDetermined, let request = photosAccessRequest else { return status }
        return await request.value
    }

    /// Ajoute les fichiers (l'original d'abord) à la pellicule, en un seul changement : tous ou aucun. Les fichiers
    /// sont copiés (`shouldMoveFile = false`) : ils restent dans `Recordings/` jusqu'à `finishSaved`.
    func saveToPhotos(_ names: [String], in directory: URL) async throws {
        switch await photosAccess() {
        case .authorized, .limited:
            break
        case .notDetermined:
            throw PhotosFailure.notDetermined
        default:
            throw PhotosFailure.denied
        }

        let files = names.map { directory.appending(path: $0) }
        let identifiers = OSAllocatedUnfairLock<[String]>(initialState: [])
        do {
            // `@Sendable` : Photos exécute ce bloc sur sa propre file. Sans cela, écrit dans une méthode de l'acteur
            // principal, il hériterait de son isolation et l'app s'arrêterait sur la vérification de file.
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                for file in files {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: file, options: options)
                    if let identifier = request.placeholderForCreatedAsset?.localIdentifier {
                        identifiers.withLock { $0.append(identifier) }
                    }
                }
            }
        } catch {
            log.error("Ajout à Photos en échec : \(String(describing: error), privacy: .public)")
            throw PhotosFailure.saveFailed
        }
        let saved = identifiers.withLock { $0 }
        log.notice("Rangées dans Photos : \(saved.joined(separator: ", "), privacy: .public)")
    }
}
