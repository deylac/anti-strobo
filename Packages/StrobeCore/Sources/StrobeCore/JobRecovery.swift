import Foundation

/// Un fichier présent dans le dossier `Recordings/`.
public struct RecordingFile: Sendable, Equatable {
    /// Nom du fichier, relatif à `Recordings/`.
    public var name: String
    /// Date de création du fichier ; `nil` si le système ne l'a pas donnée.
    public var createdAt: Date?

    public init(name: String, createdAt: Date?) {
        self.name = name
        self.createdAt = createdAt
    }
}

/// Ce qu'il faut faire pour remettre la liste des travaux d'accord avec le contenu de `Recordings/`.
/// Un plan vide (`RecoveryPlan()`) veut dire que tout est en ordre.
public struct RecoveryPlan: Sendable, Equatable {
    /// Travaux à ajouter : un `.recorded` par enregistrement sans travail (app tuée pendant l'enregistrement).
    public var adopt: [CleaningJob] = []
    /// Travaux à réécrire : un `.cleaned` dont la copie nettoyée a disparu repasse à `.recorded`.
    public var update: [CleaningJob] = []
    /// Travaux à retirer de la liste : terminés (`.saved`) sans plus aucune copie locale, ou dont l'original a disparu
    /// (en attente ou `.unusable`).
    public var remove: [UUID] = []
    /// Fichiers à supprimer, relatifs à `Recordings/`, dans cet ordre : copies locales de travaux `.saved`, dont les
    /// deux vidéos sont déjà dans Photos.
    public var deleteFiles: [String] = []

    public init() {}
}

/// Rapproche la liste des travaux de nettoyage et les fichiers de `Recordings/`, au lancement de l'app et à chaque
/// retour au premier plan. Logique pure : l'app lit le dossier et la liste, puis applique le plan.
///
/// Règles :
/// - un travail « occupé » (en file ou en cours dans l'app) n'est jamais touché, et ses fichiers ne sont pas des
///   orphelins ;
/// - **orphelin** : un `.mov` qu'aucun travail ne cite (ni comme original ni comme copie nettoyée), qui n'est ni une
///   copie nettoyée (`*-clean.mov`) ni un fichier caché, et créé **avant** le lancement de l'app. Il devient un travail
///   `.recorded` daté de sa création. Un fichier créé depuis le lancement (ou de date inconnue) peut être
///   l'enregistrement en cours, qui recevra son travail à l'arrêt : il n'est pas adopté. Les `.partial` ne sont pas
///   des `.mov` ;
/// - `.saved` : les deux vidéos sont dans Photos (l'état n'est écrit qu'après la sauvegarde). Les copies locales
///   restantes sont supprimées, la copie nettoyée d'abord ; le travail n'est retiré qu'une fois ses fichiers partis
///   (au passage suivant). Retiré plus tôt, un original dont la suppression a échoué deviendrait un orphelin, rangé
///   une seconde fois dans Photos ;
/// - original disparu (travail en attente) : il n'y a plus rien à nettoyer ni à perdre, le travail est retiré. Une
///   copie nettoyée encore présente est gardée : rien ne prouve qu'elle est dans Photos ;
/// - `.cleaned` dont la copie nettoyée a disparu (ou n'a pas de nom) : repasse à `.recorded`, pour la refaire ;
/// - `.unusable` (original sans piste vidéo) : laissé tel quel ; retiré seulement si son fichier a disparu.
///
/// Rien d'autre n'est jamais supprimé : un original n'est effacé que s'il appartient à un travail `.saved`.
public enum JobRecovery {
    /// Suffixe ajouté au nom de l'original pour la copie nettoyée.
    private static let cleanedSuffix = "-clean"
    private static let movieExtension = "mov"

    /// Nom de la copie nettoyée d'un original : `4F2A.mov` → `4F2A-clean.mov`. Toujours en `.mov`.
    public static func cleanedFileName(forOriginal name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return "\(base)\(cleanedSuffix).\(movieExtension)"
    }

    /// Calcule le plan de remise en ordre.
    /// - Parameters:
    ///   - jobs: tous les travaux connus (y compris `.saved`), lus sans erreur.
    ///   - files: le contenu complet de `Recordings/`, lu sans erreur. Une liste incomplète ferait retirer à tort des
    ///     travaux dont l'original existe.
    ///   - launchedAt: moment du lancement de l'app.
    ///   - busy: travaux en file ou en cours dans l'app, à laisser tels quels.
    public static func plan(
        jobs: [CleaningJob],
        files: [RecordingFile],
        launchedAt: Date,
        busy: Set<UUID> = []
    ) -> RecoveryPlan {
        let present = Set(files.map(\.name))
        var plan = RecoveryPlan()

        for job in jobs where !busy.contains(job.id) {
            switch job.state {
            case .saved:
                let leftovers = [job.cleanedFile, job.originalFile]
                    .compactMap { $0 }
                    .filter(present.contains)
                if leftovers.isEmpty {
                    plan.remove.append(job.id)
                } else {
                    plan.deleteFiles += leftovers
                }
            case .unusable:
                // Gardé tel quel, jamais retenté ; retiré seulement si son fichier a disparu.
                if !present.contains(job.originalFile) {
                    plan.remove.append(job.id)
                }
            case .recorded, .cleaned:
                if !present.contains(job.originalFile) {
                    plan.remove.append(job.id)
                } else if job.state == .cleaned, !(job.cleanedFile.map(present.contains) ?? false) {
                    var redo = job
                    redo.state = .recorded
                    redo.cleanedFile = nil
                    plan.update.append(redo)
                }
            }
        }

        let referenced = Set(jobs.flatMap { [$0.originalFile, $0.cleanedFile].compactMap { $0 } })
        plan.adopt = files
            .compactMap { file -> (name: String, createdAt: Date)? in
                guard let createdAt = file.createdAt, createdAt < launchedAt,
                      isRecording(file.name), !referenced.contains(file.name)
                else { return nil }
                return (file.name, createdAt)
            }
            .sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
            .map { CleaningJob(originalFile: $0.name, state: .recorded, createdAt: $0.createdAt) }

        return plan
    }

    /// Vrai pour un nom d'original possible : un `.mov` visible qui n'est pas une copie nettoyée.
    private static func isRecording(_ name: String) -> Bool {
        let nsName = name as NSString
        return !name.hasPrefix(".")
            && nsName.pathExtension == movieExtension
            && !nsName.deletingPathExtension.hasSuffix(cleanedSuffix)
    }
}
