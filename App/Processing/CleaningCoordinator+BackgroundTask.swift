import BackgroundTasks
import Foundation
import os
import StrobeCore

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "Cleaning")

/// Tâche de fond de la file : une seule `BGContinuedProcessingTask` couvre tous les travaux en file (comptabilité
/// dans `CleaningSchedule`). Elle permet de continuer app en arrière-plan ou écran verrouillé ; le nettoyage n'en
/// dépend pas.
extension CleaningCoordinator {
    /// Vrai si l'iPhone permet le calcul graphique en arrière-plan à une tâche de fond : l'interpolation et le
    /// débruitage (VideoToolbox) en ont besoin quand l'app n'est plus à l'écran.
    nonisolated static var backgroundGPUAvailable: Bool {
        BGTaskScheduler.supportedResources.contains(.gpu)
    }

    /// Note au journal, au lancement, ce que l'appareil offre au nettoyage : interpolation, débruitage, et
    /// calcul graphique en arrière-plan.
    nonisolated static func logProcessingCapabilities() {
        let resources = BGTaskScheduler.supportedResources
        log.notice("""
            Appareil : VTFrameRateConversionConfiguration.isSupported = \(VideoCleaner.deviceSupportsInterpolation), \
            VTTemporalNoiseFilterConfiguration.isSupported = \(VideoCleaner.deviceSupportsDenoise), \
            BGTaskScheduler.supportedResources = \(resources.rawValue) (GPU : \(resources.contains(.gpu)))
            """)
    }

    /// Demande à iOS la tâche de fond de la file, nommée d'après son premier travail.
    ///
    /// Le gestionnaire est enregistré pour l'identifiant complet, juste avant la soumission. Enregistrer le motif
    /// `app.camantistrobo.ios.clean.*` lui-même ne marche pas : iOS refuse ce motif comme gestionnaire, et
    /// `submit` lève alors une exception Objective-C (« No launch handler registered… ») qui tue l'app.
    func submitLease(token: Int, firstJob: UUID) {
        let identifier = backgroundTaskIdentifier(for: firstJob)
        registeredIdentifiers.insert(identifier)
        // File principale : le gestionnaire (isolé à l'acteur principal) y est appelé.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) {
            [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            self.backgroundTaskStarted(task, token: token)
        }
        guard registered else {
            log.error("Tâche de fond non enregistrée (\(identifier, privacy: .public)) : nettoyage au premier plan")
            schedule.leaseUnavailable(token: token)
            return
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: StatusText.backgroundTaskTitle,
            subtitle: StatusText.backgroundTaskSubtitle
        )
        // Interpolation et débruitage passent par le GPU (VideoToolbox) : sans cette demande, ils échouent écran
        // verrouillé. Demandé seulement si l'iPhone le permet (sinon iOS refuserait toute la tâche) ; il faut
        // aussi le droit `com.apple.developer.background-tasks.continued-processing.gpu`
        // (Config/AntiStrobo.entitlements).
        if Self.backgroundGPUAvailable {
            request.requiredResources = .gpu
        }
        // Stratégie par défaut (`.queue`) : si iOS ne peut pas la lancer tout de suite, la tâche attend une place
        // pendant que le nettoyage avance au premier plan, et s'y rattache quand elle démarre.
        do {
            try BGTaskScheduler.shared.submit(request)
            let gpu = request.requiredResources.contains(.gpu)
            log.notice("Tâche de fond demandée : \(identifier, privacy: .public), GPU : \(gpu)")
        } catch {
            log.notice("Tâche de fond refusée (\(String(describing: error), privacy: .public)) : nettoyage au premier plan")
            schedule.leaseUnavailable(token: token)
        }
    }

    /// `app.camantistrobo.ios.clean.<id du travail>`, ou avec un suffixe `-2`, `-3`… quand une demande nommée
    /// d'après le même travail a déjà été enregistrée dans ce processus.
    private func backgroundTaskIdentifier(for jobID: UUID) -> String {
        let base = "app.camantistrobo.ios.clean.\(jobID.uuidString)"
        var identifier = base
        var attempt = 1
        while registeredIdentifiers.contains(identifier) {
            attempt += 1
            identifier = "\(base)-\(attempt)"
        }
        return identifier
    }

    /// iOS lance la tâche `token` : elle se rattache à la file, ou se termine aussitôt si la file s'est vidée (ou a
    /// été arrêtée) entre-temps.
    private func backgroundTaskStarted(_ task: BGTask, token: Int) {
        guard let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        leases[token] = BackgroundLease(task: task) { [weak self] in
            guard let self else { return }
            // iOS reprend son temps, ou l'utilisateur arrête la tâche depuis l'activité en direct.
            log.notice("Tâche de fond expirée : nettoyage arrêté, le reste attend un toucher")
            self.apply(self.schedule.leaseExpired(token: token))
        }
        log.notice("Tâche de fond lancée (demande \(token))")
        apply(schedule.leaseAttached(token: token))
    }
}

/// Une `BGContinuedProcessingTask` : reflète l'avancement de la file et se termine une seule fois. L'expiration
/// est ramenée sur l'acteur principal.
@MainActor
final class BackgroundLease {
    private let task: BGContinuedProcessingTask
    private var isCompleted = false

    init(task: BGContinuedProcessingTask, onExpiration: @escaping @MainActor @Sendable () -> Void) {
        self.task = task
        task.progress.totalUnitCount = CleaningSchedule.unitsPerJob
        task.progress.completedUnitCount = 0
        // Appelé par iOS sur une file quelconque.
        task.expirationHandler = { @Sendable in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onExpiration() }
            }
        }
    }

    /// Avancement de toute la file, en unités (`CleaningSchedule.unitsPerJob` par travail).
    func report(completed: Int64, total: Int64) {
        guard !isCompleted, total > 0 else { return }
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = min(max(completed, 0), total)
    }

    func complete(success: Bool) {
        guard !isCompleted else { return }
        isCompleted = true
        if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
        task.setTaskCompleted(success: success)
    }
}
