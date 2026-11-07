import Foundation
import Observation
import os
import Photos
import StrobeCore
import UIKit

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "Cleaning")

/// File des nettoyages : chaque enregistrement est nettoyé (vidéo 30 i/s sans les images brûlées par les flashs),
/// puis l'original et la version nettoyée sont rangés ensemble dans la pellicule.
///
/// Vie d'un travail (`CleaningJob`, mémorisé dans `jobs.json` pour survivre à l'arrêt de l'app) :
/// `.recorded` → `VideoCleaner` écrit `Recordings/<original>-clean.mov` → `.cleaned` → les deux vidéos sont
/// ajoutées à Photos (accès « ajout seulement ») → `.saved` → suppression des copies locales → travail retiré.
/// Une vidéo sans aucune image à garder (`noVideoFrames`) part seule dans la pellicule ; une vidéo sans piste vidéo
/// (`noVideoTrack`) reste dans l'app, `.unusable`, et n'est plus retentée.
///
/// La file et sa tâche de fond sont comptées par `CleaningSchedule` (logique pure) ; ce type applique ses actions.
/// Une seule `BGContinuedProcessingTask` couvre toute la file (voir `CleaningCoordinator+BackgroundTask.swift`) ;
/// l'accès à Photos et l'ajout des vidéos sont dans `CleaningCoordinator+Photos.swift`.
/// Le travail démarre tout de suite au premier plan ; la tâche s'y rattache quand iOS la lance. Refusée ou jamais
/// lancée (simulateur, réglages), le nettoyage continue au premier plan avec la même progression.
///
/// Invariants :
/// - l'original n'est jamais modifié ; il n'est supprimé qu'après son ajout réussi à Photos ;
/// - tout échec du nettoyage (y compris l'annulation) laisse le travail `.recorded`, à reprendre ; un échec côté
///   Photos le laisse `.cleaned`, rien n'est supprimé ; `error` dit pourquoi ;
/// - un nettoyage ne commence que s'il reste la place de sa copie et de la marge du système
///   (`StorageEstimator.hasRoomToClean`) ; sinon le travail reste `.recorded` ;
/// - un seul travail tourne à la fois, et jamais pendant un enregistrement (`setRecordingActive`) ; aucun ne
///   démarre tant que l'iPhone est trop chaud (état thermique `serious` ou plus), la file repart quand il refroidit ;
/// - les écritures de la liste des travaux passent toutes par une même chaîne (`serially`) : une remise en ordre
///   ne se croise jamais avec l'avancement d'un travail.
@MainActor
@Observable
final class CleaningCoordinator {
    /// Avancement (0…1) du travail en cours ; `nil` quand rien ne tourne.
    private(set) var progress: Double?
    /// Moment où les deux vidéos du dernier travail terminé sont arrivées dans la pellicule.
    private(set) var lastFinished: Date?
    /// Vrai si l'app n'était pas au premier plan quand `lastFinished` a changé (nettoyage en arrière-plan ou
    /// écran verrouillé) : l'écran garde alors la confirmation jusqu'au prochain toucher. Changé en même temps
    /// que `lastFinished`.
    private(set) var lastFinishedWhileInactive = false
    /// Travaux pas encore rangés dans la pellicule, en cours compris (dernier comptage réussi : une liste
    /// illisible, iPhone verrouillé par exemple, ne remet pas le compte à zéro).
    private(set) var pendingCount = 0
    /// Taille estimée, en octets, des copies nettoyées encore à écrire pour les originaux en attente (même
    /// comptage que `pendingCount`, voir `VideoCleaner.estimatedCleanedBytes(of:)`) : l'écran garde leur place
    /// dans le temps d'enregistrement restant.
    private(set) var pendingCleanedBytes: Int64 = 0
    /// Dernier message pour l'utilisateur (échec, ou original rangé seul), en français ; effacé au prochain toucher.
    private(set) var error: String?
    /// Vrai quand un travail tourne sans tâche de fond (iOS a refusé la demande, par exemple app passée en
    /// arrière-plan avant le « Stop ») : il s'arrêterait en quittant l'app. « Reprendre le nettoyage » en
    /// redemande une.
    private(set) var runningWithoutBackgroundTask = false
    /// Vrai quand des vidéos attendent que l'iPhone refroidisse pour être nettoyées.
    private(set) var waitingForCooling = false

    /// File, travail en cours et tâche de fond (comptabilité pure).
    @ObservationIgnored var schedule = CleaningSchedule()
    /// Tâches de fond iOS lancées, par numéro de demande.
    @ObservationIgnored var leases: [Int: BackgroundLease] = [:]
    /// Identifiants de tâche de fond déjà enregistrés dans ce processus : un second enregistrement du même
    /// identifiant tue l'app.
    @ObservationIgnored var registeredIdentifiers: Set<String> = []

    @ObservationIgnored private let store: CleaningJobStore
    @ObservationIgnored private let cleaner = VideoCleaner()
    /// Un fichier créé depuis ce moment appartient à l'app en cours (enregistrement en cours) : jamais adopté.
    @ObservationIgnored private let launchedAt = Date()
    /// Travaux confiés à la file, par identifiant (la file ne connaît que les identifiants).
    @ObservationIgnored private var scheduledJobs: [UUID: CleaningJob] = [:]
    /// Tâche Swift du travail en cours (annulée à l'expiration ou au début d'un enregistrement).
    @ObservationIgnored private var work: (jobID: UUID, task: Task<Void, Never>)?
    /// Question d'accès à Photos posée au dernier toucher, peut-être encore sans réponse.
    @ObservationIgnored var photosAccessRequest: Task<PHAuthorizationStatus, Never>?
    /// Dernière opération sur la liste des travaux ; la suivante attend qu'elle finisse.
    @ObservationIgnored private var storeTail: Task<Void, Never>?
    /// Abonnement aux changements d'état thermique.
    @ObservationIgnored private var thermalObserver: (any NSObjectProtocol)?

    /// Dossier de `jobs.json`.
    nonisolated static var jobsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "CleaningJobs", directoryHint: .isDirectory)
    }

    init(store: CleaningJobStore = CleaningJobStore(directory: CleaningCoordinator.jobsDirectory)) {
        self.store = store
        Self.logProcessingCapabilities()
        _ = schedule.setOverheated(CleaningSchedule.isTooHot(ProcessInfo.processInfo.thermalState))
        // La notification arrive sur une file quelconque : ramenée sur la file principale.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalStateChanged() }
        }
    }

    isolated deinit {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    // MARK: - Entrées

    /// Met au nettoyage un enregistrement qui vient de finir (`Recordings/<nom>.mov`), juste après le toucher sur
    /// « Stop » : iOS n'accorde la tâche de fond qu'à la suite d'une action de l'utilisateur. Crée le travail s'il
    /// n'existe pas (pas de doublon), puis confie à la file **tous** les travaux en attente, dont ceux qu'un
    /// enregistrement précédent a interrompus.
    func enqueue(original: URL) async {
        error = nil
        let directory: URL
        do {
            directory = try CameraController.recordingsDirectory()
        } catch {
            log.error("Dossier des enregistrements inaccessible : \(String(describing: error), privacy: .public)")
            self.error = StatusText.cleaningNotStarted
            return
        }
        guard Self.isDirectChild(original, of: directory) else {
            log.fault("Enregistrement hors de Recordings/ : \(original.path, privacy: .public)")
            error = StatusText.cleaningNotStarted
            return
        }

        askPhotosAccessIfNeeded()
        let name = original.lastPathComponent
        await serially {
            do {
                self.scheduleAll(try await self.jobsIncluding(original: name))
            } catch {
                // Sans la liste, on ne sait pas si ce fichier a déjà son travail : ne rien créer. L'original reste
                // dans `Recordings/` et sera adopté au prochain lancement.
                log.error("Liste des travaux illisible : \(String(describing: error), privacy: .public)")
                self.error = StatusText.cleaningNotStarted
            }
            await self.refreshPendingCount()
        }
    }

    /// Au lancement et à chaque retour de l'app au premier plan : remet la liste des travaux d'accord avec
    /// `Recordings/` (enregistrement sans travail après un arrêt brutal, copies déjà rangées, fichiers disparus) et
    /// met `pendingCount` à jour. Ne lance aucun nettoyage : iOS n'accorde la tâche de fond qu'à la suite d'un
    /// toucher (« Reprendre le nettoyage », voir `resumeAll`).
    func resumePending() {
        Task {
            await serially {
                await self.reconcile()
                await self.refreshPendingCount()
            }
        }
    }

    /// « Reprendre le nettoyage » : confie à la file chaque travail en attente, avec son identifiant ; un `.cleaned`
    /// passe directement à la sauvegarde dans Photos. Les travaux déjà en file ou en cours ne sont pas dupliqués.
    func resumeAll() async {
        error = nil
        askPhotosAccessIfNeeded()
        await serially {
            await self.reconcile()
            do {
                self.scheduleAll(try await self.store.readAll())
            } catch {
                log.error("Liste des travaux illisible : \(String(describing: error), privacy: .public)")
                self.error = StatusText.cleaningNotStarted
            }
            await self.refreshPendingCount()
        }
    }

    /// À brancher sur l'enregistrement (`CameraController.isRecording`) : le nettoyage ne concurrence jamais un
    /// enregistrement. Au début : le nettoyage en cours est annulé (il reste `.recorded` ; `VideoCleaner` supprime
    /// son `.partial`), la tâche de fond est terminée et rien d'autre ne démarre. À la fin : rien ne repart de
    /// soi-même ; le « Stop » suivant (`enqueue`) redemande une tâche qui couvre tous les travaux en attente.
    func setRecordingActive(_ active: Bool) {
        apply(schedule.setRecording(active))
    }

    /// iPhone trop chaud : le nettoyage en cours finit, les suivants attendent (`.recorded`) ; refroidi, la file
    /// repart d'elle-même.
    private func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        let hot = CleaningSchedule.isTooHot(state)
        guard hot != schedule.isOverheated else { return }
        log.notice("État thermique \(state.rawValue) : nettoyage \(hot ? "suspendu" : "permis", privacy: .public)")
        apply(schedule.setOverheated(hot))
    }

    // MARK: - File

    /// La liste des travaux, avec celui du nouvel enregistrement, créé s'il n'existe pas.
    /// - Throws: l'erreur de lecture de la liste ; rien n'est alors créé.
    private func jobsIncluding(original name: String) async throws -> [CleaningJob] {
        var jobs = try await store.readAll()
        guard !jobs.contains(where: { $0.originalFile == name }) else { return jobs }
        let job = CleaningJob(originalFile: name)
        do {
            try await store.upsert(job)
        } catch {
            // Le nettoyage se fait quand même. Si l'app est tuée avant la fin, l'original sans travail sera adopté
            // au prochain lancement.
            log.error("Travail non mémorisé : \(String(describing: error), privacy: .public)")
        }
        jobs.append(job)
        return jobs
    }

    /// Confie à la file les travaux en attente de `jobs`, du plus ancien au plus récent.
    private func scheduleAll(_ jobs: [CleaningJob]) {
        let pending = jobs.filter(\.state.isPending)
        for job in pending where !schedule.busy.contains(job.id) {
            scheduledJobs[job.id] = job
        }
        apply(schedule.enqueue(pending.map(\.id)))
    }

    /// Applique les actions de `CleaningSchedule`, puis reporte l'avancement.
    func apply(_ actions: [CleaningScheduleAction]) {
        for action in actions {
            switch action {
            case let .submitLease(token, firstJob):
                submitLease(token: token, firstJob: firstJob)
            case let .start(jobID):
                start(jobID)
            case let .cancel(jobID):
                if work?.jobID == jobID {
                    log.notice("Nettoyage en cours annulé")
                    work?.task.cancel()
                }
            case let .completeLease(token, success):
                leases.removeValue(forKey: token)?.complete(success: success)
            }
        }
        scheduledJobs = scheduledJobs.filter { schedule.busy.contains($0.key) }
        publishProgress()
    }

    private func start(_ jobID: UUID) {
        guard let job = scheduledJobs[jobID] else {
            // Impossible : la file ne reçoit que des travaux confiés ici. Par prudence, on la débloque.
            log.fault("Travail inconnu de la file : \(jobID.uuidString, privacy: .public)")
            Task { self.finished(jobID, success: false) }
            return
        }
        // Déjà nettoyé : il ne reste que l'ajout à Photos.
        if !Self.needsCleaning(job) { schedule.progress(1, of: jobID) }
        work = (jobID, Task {
            let success = await self.process(job)
            self.finished(jobID, success: success)
        })
    }

    private func finished(_ jobID: UUID, success: Bool) {
        if work?.jobID == jobID { work = nil }
        apply(schedule.finish(jobID, success: success))
        Task {
            await serially { await self.refreshPendingCount() }
        }
    }

    /// Vrai tant que la copie nettoyée reste à écrire (un `.cleaned` sans nom de copie est refait).
    nonisolated private static func needsCleaning(_ job: CleaningJob) -> Bool {
        job.state == .recorded || job.cleanedFile == nil
    }

    // MARK: - Avancement

    private func reportProgress(_ fraction: Double, of jobID: UUID) {
        schedule.progress(fraction, of: jobID)
        guard let value = schedule.currentProgress, let shown = progress else {
            publishProgress()
            return
        }
        // Au plus une mise à jour par point de pourcentage : l'écran et iOS n'en montrent pas plus.
        if value - shown >= 0.01 || (value == 1 && shown < 1) { publishProgress() }
    }

    /// Reporte l'avancement de la file sur l'écran (travail en cours) et sur la tâche de fond (toute la file), et
    /// l'état de la file (sans tâche de fond, en attente de refroidissement).
    func publishProgress() {
        if progress != schedule.currentProgress { progress = schedule.currentProgress }
        if runningWithoutBackgroundTask != schedule.isRunningWithoutLease {
            runningWithoutBackgroundTask = schedule.isRunningWithoutLease
        }
        if waitingForCooling != schedule.isWaitingForCooling { waitingForCooling = schedule.isWaitingForCooling }
        if let lease = schedule.lease, lease.isAttached {
            leases[lease.token]?.report(completed: schedule.completedUnits, total: schedule.totalUnits)
        }
    }

    // MARK: - Étapes

    /// Nettoie (si besoin) puis range les vidéos dans Photos. N'écrit l'état qu'une fois chaque étape réussie.
    /// - Returns: vrai si le travail est terminé et rangé dans la pellicule.
    private func process(_ start: CleaningJob) async -> Bool {
        var job = start
        do {
            let directory = try CameraController.recordingsDirectory()
            if Self.needsCleaning(job) {
                let original = directory.appending(path: job.originalFile)
                guard await hasRoomToClean(original) else {
                    log.notice("Pas assez de place pour nettoyer \(job.originalFile, privacy: .public) : il attend")
                    error = StatusText.notEnoughSpaceToClean
                    return false
                }
                do {
                    job = try await clean(job, in: directory)
                } catch VideoCleanerError.noVideoFrames {
                    // Aucune image à garder : réessayer ne changera rien. L'original seul part dans la pellicule.
                    return try await saveOriginalAlone(job, in: directory)
                } catch VideoCleanerError.noVideoTrack {
                    await markUnusable(job)
                    return false
                }
            }
            // Arrêté pendant le nettoyage ou juste après : on s'arrête avant Photos ; le travail reste `.cleaned`.
            try Task.checkCancellation()
            try await saveToPhotos([job.originalFile, job.cleanedFile].compactMap { $0 }, in: directory)
            await finishSaved(job, in: directory)
            lastFinishedWhileInactive = UIApplication.shared.applicationState != .active
            lastFinished = Date()
            return true
        } catch let failure as PhotosFailure {
            error = failure.message
        } catch is CancellationError where schedule.isRecording {
            // Arrêté pour laisser la place à l'enregistrement : rien à signaler, le prochain « Stop » le reprend.
            log.notice("Nettoyage de \(job.originalFile, privacy: .public) reporté : enregistrement en cours")
        } catch {
            log.error("Nettoyage de \(job.originalFile, privacy: .public) en échec : \(String(describing: error), privacy: .public)")
            self.error = StatusText.cleaningError(error)
        }
        return false
    }

    /// Écrit la copie nettoyée (l'original n'est que lu) puis note `.cleaned`.
    private func clean(_ job: CleaningJob, in directory: URL) async throws -> CleaningJob {
        let cleanedName = JobRecovery.cleanedFileName(forOriginal: job.originalFile)
        let jobID = job.id
        let report = try await cleaner.clean(
            input: directory.appending(path: job.originalFile),
            output: directory.appending(path: cleanedName)
        ) { [weak self] fraction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reportProgress(fraction, of: jobID) }
            }
        }
        let selection = report.selection
        log.notice("""
            Nettoyé \(job.originalFile, privacy: .public) : \(report.totalFrames) images dont \
            \(report.flashFrames) avec lumière ; \(selection.slots) créneaux : \(selection.sourceSlots) sources, \
            \(selection.interpolatedSlots) recréés (\(report.failedInterpolations) en échec, image d'avant \
            répétée), \(selection.heldSlots) répétés, \(selection.fallbackSlots) de repli ; \
            \(report.denoisedFrames) images débruitées ; analyse \
            \(report.analysisSeconds, format: .fixed(precision: 1)) s, écriture \
            \(report.writingSeconds, format: .fixed(precision: 1)) s
            """)

        var cleaned = job
        cleaned.cleanedFile = cleanedName
        cleaned.state = .cleaned
        await serially { await self.persist(cleaned) }
        return cleaned
    }

    /// Échec définitif du nettoyage (aucune image à garder) : l'original seul est rangé dans la pellicule, puis le
    /// travail se termine comme les autres (`.saved`, copie locale supprimée après la sauvegarde).
    private func saveOriginalAlone(_ job: CleaningJob, in directory: URL) async throws -> Bool {
        log.notice("Aucune image à garder dans \(job.originalFile, privacy: .public) : original rangé seul")
        try await saveToPhotos([job.originalFile], in: directory)
        var original = job
        original.cleanedFile = nil
        await finishSaved(original, in: directory)
        error = StatusText.originalSavedAlone
        return true
    }

    /// Original sans piste vidéo : gardé dans l'app tel quel, plus jamais retenté.
    private func markUnusable(_ job: CleaningJob) async {
        log.notice("Pas de piste vidéo dans \(job.originalFile, privacy: .public) : gardé, plus retenté")
        var unusable = job
        unusable.state = .unusable
        await serially { await self.persist(unusable) }
        error = StatusText.cleaningError(VideoCleanerError.noVideoTrack)
    }

    /// Les vidéos sont dans Photos : note `.saved`, puis supprime les copies locales (la nettoyée d'abord) et
    /// retire le travail. Si une suppression échoue, le travail `.saved` reste : `reconcile` finira le ménage
    /// (retiré trop tôt, l'original restant passerait pour un orphelin et serait rangé une seconde fois).
    private func finishSaved(_ job: CleaningJob, in directory: URL) async {
        await serially {
            var saved = job
            saved.state = .saved
            await self.persist(saved)

            var allDeleted = true
            for name in [job.cleanedFile, job.originalFile].compactMap({ $0 }) {
                do {
                    try FileManager.default.removeItem(at: directory.appending(path: name))
                } catch {
                    allDeleted = false
                    log.error("Copie locale \(name, privacy: .public) non supprimée : \(String(describing: error), privacy: .public)")
                }
            }
            guard allDeleted else { return }
            do {
                try await self.store.remove(id: job.id)
            } catch {
                log.error("Travail terminé non retiré : \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Écrit le nouvel état. Un échec est noté sans arrêter le travail : la remise en ordre au prochain passage
    /// (`JobRecovery`) rattrape une liste en retard sur les fichiers. À appeler depuis `serially`.
    private func persist(_ job: CleaningJob) async {
        do {
            try await store.upsert(job)
        } catch {
            log.error("État \(job.state.rawValue, privacy: .public) non mémorisé : \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Liste des travaux

    /// Applique le plan de `JobRecovery`. Sans liste ou sans dossier lisibles, ne fait rien : ce sera pour la
    /// prochaine fois (une liste vide par erreur ferait adopter des fichiers qui ont déjà leur travail).
    /// À appeler depuis `serially` : aucune écriture d'un travail en cours ne peut se glisser entre la lecture et
    /// l'application du plan.
    private func reconcile() async {
        // Un travail occupé au début de la lecture est laissé de côté, même s'il finit pendant celle-ci.
        let busyAtStart = schedule.busy
        let directory: URL
        let jobs: [CleaningJob]
        let files: [RecordingFile]
        do {
            directory = try CameraController.recordingsDirectory()
            jobs = try await store.readAll()
            files = try Self.recordingFiles(in: directory)
        } catch {
            log.notice("Remise en ordre reportée : \(String(describing: error), privacy: .public)")
            return
        }

        let plan = JobRecovery.plan(
            jobs: jobs, files: files, launchedAt: launchedAt, busy: busyAtStart.union(schedule.busy)
        )
        guard plan != RecoveryPlan() else { return }
        log.notice(
            "Remise en ordre : \(plan.adopt.count) adoptés, \(plan.update.count) à renettoyer, \(plan.remove.count) retirés, \(plan.deleteFiles.count) fichiers supprimés"
        )
        for name in plan.deleteFiles {
            do {
                try FileManager.default.removeItem(at: directory.appending(path: name))
            } catch {
                log.error("Copie locale \(name, privacy: .public) non supprimée : \(String(describing: error), privacy: .public)")
            }
        }
        for id in plan.remove {
            do {
                try await store.remove(id: id)
            } catch {
                log.error("Travail non retiré : \(String(describing: error), privacy: .public)")
            }
        }
        for job in plan.update + plan.adopt {
            await persist(job)
        }
    }

    /// Recompte les travaux à terminer et la place des copies nettoyées encore dues ; une liste illisible laisse
    /// le dernier compte.
    private func refreshPendingCount() async {
        guard let jobs = try? await store.readAll() else { return }
        pendingCount = Set(jobs.filter(\.state.isPending).map(\.id)).union(schedule.busy).count
        if let bytes = await owedCleanedBytes(of: jobs) { pendingCleanedBytes = bytes }
    }

    /// Taille estimée des copies nettoyées que les originaux en attente n'ont pas encore, ou `nil` sans dossier.
    /// Un original illisible (absent, abîmé) compte pour rien. Une lecture des pistes par travail en attente.
    private func owedCleanedBytes(of jobs: [CleaningJob]) async -> Int64? {
        guard let directory = try? CameraController.recordingsDirectory() else { return nil }
        var total: Int64 = 0
        for job in jobs where job.state.isPending && Self.needsCleaning(job) {
            total += (try? await cleaner.estimatedCleanedBytes(of: directory.appending(path: job.originalFile))) ?? 0
        }
        return total
    }

    /// Vrai s'il reste la place d'écrire la copie nettoyée de `original`, estimée d'après la règle de débit du
    /// nettoyage. Espace ou original illisible : on tente le nettoyage (un disque vraiment plein le fera échouer,
    /// l'original reste intact ; un original illisible échouera avec sa propre erreur).
    private func hasRoomToClean(_ original: URL) async -> Bool {
        guard let freeBytes = await CameraController.availableRecordingBytes(),
              let cleanedBytes = try? await cleaner.estimatedCleanedBytes(of: original)
        else { return true }
        return StorageEstimator.hasRoomToClean(cleanedBytes: cleanedBytes, freeBytes: freeBytes)
    }

    /// Exécute `operation` après les précédentes. Toutes les écritures de la liste des travaux passent par ici :
    /// une lecture et les écritures qui en découlent ne se croisent jamais avec une autre (deux remises en ordre
    /// adopteraient deux fois le même fichier ; un travail qui avance changerait la liste sous une remise en ordre).
    /// Une opération ne doit jamais attendre `serially` elle-même (blocage).
    private func serially(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        let previous = storeTail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        storeTail = task
        await task.value
    }

    nonisolated private static func recordingFiles(in directory: URL) throws -> [RecordingFile] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            .map { url in
                RecordingFile(
                    name: url.lastPathComponent,
                    createdAt: try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
                )
            }
    }

    nonisolated private static func isDirectChild(_ file: URL, of directory: URL) -> Bool {
        file.deletingLastPathComponent().resolvingSymlinksInPath().path
            == directory.resolvingSymlinksInPath().path
    }
}
