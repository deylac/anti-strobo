import Foundation

/// Étape d'avancement d'un travail de nettoyage. Les valeurs brutes sont écrites dans `jobs.json` : ne pas les renommer.
public enum JobState: String, Sendable, Codable {
    /// Original enregistré, pas encore nettoyé.
    case recorded
    /// Copie nettoyée produite, pas encore enregistrée dans la pellicule.
    case cleaned
    /// Les deux vidéos sont dans la pellicule (ou l'original seul, quand il n'a pas pu être nettoyé) : le travail
    /// est terminé.
    case saved
    /// Original sans piste vidéo : gardé tel quel dans l'app, ni nettoyé ni rangé dans la pellicule, jamais retenté.
    case unusable

    /// Vrai pour un travail qui reste à faire (`.recorded` ou `.cleaned`).
    public var isPending: Bool {
        switch self {
        case .recorded, .cleaned: true
        case .saved, .unusable: false
        }
    }
}

/// Un enregistrement à nettoyer (ou en cours de finalisation), mémorisé pour reprendre après un arrêt de l'app.
public struct CleaningJob: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    /// Nom du fichier original, relatif au dossier `Recordings/`.
    public var originalFile: String
    /// Nom du fichier nettoyé, relatif au dossier `Recordings/` ; `nil` tant que le nettoyage n'est pas fini.
    public var cleanedFile: String?
    public var state: JobState
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        originalFile: String,
        cleanedFile: String? = nil,
        state: JobState = .recorded,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.originalFile = originalFile
        self.cleanedFile = cleanedFile
        self.state = state
        self.createdAt = createdAt
    }
}

/// Liste des travaux de nettoyage, enregistrée dans `jobs.json` (écriture atomique) pour survivre à l'arrêt de l'app.
///
/// - La liste est chargée à la première utilisation et gardée en mémoire ; elle est toujours triée par `createdAt`
///   croissant. À date égale, l'ordre d'insertion est conservé. Les dates sont écrites en ISO-8601 à la seconde :
///   les fractions de seconde sont perdues à la relecture, c'est pourquoi la liste est écrite déjà triée.
/// - Si `jobs.json` a été lu mais ne se décode pas, il est renommé `jobs.corrupt-<horodatage Unix>.json` et le
///   magasin repart vide. Rien ne plante et rien n'est écrasé : si ce renommage est lui-même impossible, la liste
///   reste vide et `upsert` / `remove` lèvent l'erreur au lieu d'écraser le fichier illisible.
/// - Si `jobs.json` existe mais ne peut pas être lu (erreur d'entrée/sortie, fichier verrouillé par la protection
///   des données quand l'iPhone est verrouillé…), ce n'est pas une corruption : le fichier n'est ni renommé ni
///   modifié. `all()` et `pending()` renvoient alors une liste vide pour cet appel, sans mémoriser ce résultat (la
///   lecture est retentée à l'appel suivant), et `upsert` / `remove` lèvent l'erreur de lecture au lieu d'écrire.
/// - Une erreur d'écriture est levée par `upsert` / `remove` et laisse la liste en mémoire inchangée.
/// - Sur iOS, `jobs.json` est écrit avec la protection `completeUntilFirstUserAuthentication` : le fichier reste
///   lisible téléphone verrouillé, une fois l'appareil déverrouillé une première fois après son démarrage.
public actor CleaningJobStore {
    private static let fileName = "jobs.json"

    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Travaux connus, triés ; valable seulement une fois `isLoaded` vrai.
    private var jobs: [CleaningJob] = []
    /// Vrai une fois `jobs.json` lu (ou absent). Reste faux après une erreur de lecture : on la retentera.
    private var isLoaded = false
    /// Erreur du dernier renommage raté d'un fichier non décodable ; non nil tant que ce fichier est encore en place.
    private var unreadableFileError: (any Error)?

    /// - Parameter directory: dossier qui contient `jobs.json` ; il est créé s'il n'existe pas.
    public init(directory: URL) {
        self.directory = directory
        // Au mieux : si cela échoue, la première écriture retente et lève l'erreur.
        try? Self.createDirectory(directory)
    }

    /// Tous les travaux, du plus ancien au plus récent.
    public func all() -> [CleaningJob] {
        // Lecture impossible pour l'instant : liste vide pour cet appel, retentée au prochain.
        (try? readAll()) ?? []
    }

    /// Comme `all()`, mais une lecture impossible de `jobs.json` lève son erreur au lieu de donner une liste vide :
    /// pour décider à partir de la liste (adopter un fichier, compter les travaux), « vide » doit vouloir dire vide.
    /// L'échec n'est pas mémorisé : la lecture est retentée à l'appel suivant.
    public func readAll() throws -> [CleaningJob] {
        try loadIfNeeded()
        return jobs
    }

    /// Les travaux à terminer (`JobState.isPending` : ni `.saved` ni `.unusable`), du plus ancien au plus récent.
    public func pending() -> [CleaningJob] {
        all().filter { $0.state.isPending }
    }

    /// Ajoute le travail, ou remplace celui qui a le même `id`, et enregistre la liste.
    /// - Throws: l'erreur de lecture de `jobs.json`, l'erreur d'écriture, ou celle du fichier non décodable qui n'a
    ///   pas pu être mis de côté. Dans tous ces cas, rien n'est écrit.
    public func upsert(_ job: CleaningJob) throws {
        try loadIfNeeded()
        try ensureUnreadableFileIsAside()

        var updated = jobs
        if let index = updated.firstIndex(where: { $0.id == job.id }) {
            updated[index] = job
        } else {
            updated.append(job)
        }
        updated = Self.sortedByDate(updated)
        try write(updated)
        jobs = updated
    }

    /// Retire le travail et enregistre la liste. Ne fait rien si l'`id` est inconnu.
    /// - Throws: l'erreur de lecture de `jobs.json`, l'erreur d'écriture, ou celle du fichier non décodable qui n'a
    ///   pas pu être mis de côté. Dans tous ces cas, rien n'est écrit.
    public func remove(id: UUID) throws {
        try loadIfNeeded()
        try ensureUnreadableFileIsAside()

        let updated = jobs.filter { $0.id != id }
        guard updated.count != jobs.count else { return }
        try write(updated)
        jobs = updated
    }

    // MARK: - Lecture

    /// Charge `jobs.json` une fois pour toutes.
    /// - Throws: l'erreur de lecture si le fichier existe mais ne peut pas être lu. Il n'est alors ni renommé ni
    ///   mémorisé comme chargé : la lecture sera retentée. Un fichier lu mais non décodable est mis de côté.
    private func loadIfNeeded() throws {
        guard !isLoaded else { return }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            isLoaded = true
            return
        }
        let data = try Data(contentsOf: fileURL)
        isLoaded = true

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            jobs = Self.sortedByDate(try decoder.decode([CleaningJob].self, from: data))
        } catch {
            jobs = []
            moveUnreadableFileAside()
        }
    }

    /// Renomme `jobs.json` (lu mais non décodable) en `jobs.corrupt-<horodatage Unix>.json` ;
    /// ne remplace jamais un fichier existant.
    private func moveUnreadableFileAside() {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = directory.appendingPathComponent("jobs.corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            unreadableFileError = nil
        } catch {
            unreadableFileError = error
        }
    }

    /// Avant toute écriture : tant que le fichier non décodable est en place, on retente de le mettre de côté,
    /// et on lève l'erreur plutôt que de l'écraser.
    private func ensureUnreadableFileIsAside() throws {
        guard unreadableFileError != nil else { return }
        moveUnreadableFileAside()
        if let error = unreadableFileError { throw error }
    }

    // MARK: - Écriture

    private func write(_ jobs: [CleaningJob]) throws {
        try Self.createDirectory(directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(jobs).write(to: fileURL, options: Self.writingOptions)
    }

    /// Écriture atomique ; sur iOS, le fichier reste lisible téléphone verrouillé après le premier déverrouillage,
    /// car le nettoyage tourne en arrière-plan.
    private static var writingOptions: Data.WritingOptions {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        return options
    }

    private static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Tri par date de création croissante, stable : à date égale, l'ordre d'entrée est conservé.
    private static func sortedByDate(_ jobs: [CleaningJob]) -> [CleaningJob] {
        jobs.enumerated()
            .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }
            .map(\.element)
    }
}
