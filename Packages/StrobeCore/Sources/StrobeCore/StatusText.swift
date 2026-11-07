import Foundation

/// Tous les textes d'état affichés à l'utilisateur, en français.
///
/// Logique pure, sans dépendance à l'interface : chaque texte se teste en comparant la chaîne exacte.
/// Les espaces sont des espaces ASCII ordinaires et l'apostrophe est l'apostrophe ASCII `'`.
public enum StatusText {
    /// Texte de la phase de mesure de l'exposition de référence.
    ///
    /// Tant qu'aucune image n'a été mesurée (`progress` nul : état de départ, caméra qui démarre), le temps
    /// restant n'est que le délai maximal, pas une estimation : il n'est pas affiché (`Mesure de la lumière…`).
    /// - Parameter s: état courant du mesureur (voir `ExposureMeter`).
    public static func measurement(_ s: MeasurementState) -> String {
        switch s {
        case .measuring(let progress, _) where !(progress > 0):
            return "Mesure de la lumière…"
        case .measuring(_, let secondsRemaining):
            return "Mesure de la lumière… \(secondsRemaining) s"
        case .ready:
            return "Exposition prête"
        case .failed(.notEnoughGoodFrames, _):
            return "Trop de flashs pour mesurer. Touche l'écran pour réessayer."
        case .failed(.tooDark, _):
            return "Scène très sombre : l'image sera sombre. Touche l'écran pour réessayer."
        }
    }

    /// Plafond du temps restant, en minutes (≈ 1 900 ans) : garantit que la conversion en entier ne peut pas échouer.
    private static let maxMinutes = 1e9

    /// Temps restant, arrondi à la minute inférieure :
    /// - moins d'une minute : `Moins d'1 min restante` ;
    /// - une minute : `≈ 1 min restante` ; de 2 à 59 minutes : `≈ 45 min restantes` ;
    /// - à partir d'une heure : `≈ 2 h 15 min restantes`, ou `≈ 1 h restante` / `≈ 2 h restantes` à l'heure pile
    ///   (heures et minutes sans zéro de remplissage).
    ///
    /// Une durée négative ou non finie donne `Moins d'1 min restante`.
    /// - Parameter seconds: temps restant, en secondes.
    public static func remaining(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Moins d'1 min restante" }

        let totalMinutes = Int(min(seconds / 60, maxMinutes).rounded(.down))
        switch totalMinutes {
        case ..<1:
            return "Moins d'1 min restante"
        case 1:
            return "≈ 1 min restante"
        case 2..<60:
            return "≈ \(totalMinutes) min restantes"
        default:
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if minutes == 0 {
                return hours == 1 ? "≈ 1 h restante" : "≈ \(hours) h restantes"
            }
            return "≈ \(hours) h \(minutes) min restantes"
        }
    }

    /// Avertissement de chaleur, ou `nil` quand il n'y a rien à dire (états `nominal` et `fair`).
    /// - Parameter state: état thermique de l'appareil.
    public static func thermal(_ state: ProcessInfo.ThermalState) -> String? {
        switch state {
        case .serious:
            return "L'iPhone chauffe"
        case .critical:
            return "L'iPhone est très chaud : il peut couper la caméra"
        case .nominal, .fair:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Tolérance ajoutée avant l'arrondi à l'entier inférieur : sans elle, `0,57 × 100` vaut
    /// `56,99999999999999` et afficherait 56 % au lieu de 57 %.
    private static let percentEpsilon = 1e-9

    /// Texte du nettoyage de la vidéo avec son avancement, arrondi au pourcentage inférieur et ramené dans 0…100.
    /// Une valeur non finie donne 0 %.
    /// - Parameter progress: avancement, de 0 (rien fait) à 1 (terminé).
    public static func processing(progress: Double) -> String {
        let percent = progress.isFinite
            ? Int(min(max((progress * 100 + percentEpsilon).rounded(.down), 0), 100))
            : 0
        return "Nettoyage de la vidéo… \(percent) %"
    }

    /// Message de fin : le brut et la version nettoyée sont dans la pellicule.
    public static let done = "Les deux vidéos sont dans ta pellicule"

    /// Question posée quand la mesure de référence n'est pas fiable et que l'utilisateur veut filmer quand même.
    public static let unreliableReferenceConfirm = "La mesure n'est pas fiable. Filmer quand même ?"

    // MARK: Nettoyage en arrière-plan

    /// Titre de la tâche de fond affiché par iOS (activité en direct) pendant le nettoyage.
    public static let backgroundTaskTitle = "Nettoyage de la vidéo"

    /// Sous-titre de la tâche de fond affiché par iOS pendant le nettoyage.
    public static let backgroundTaskSubtitle = "Retrait des flashs, puis rangement dans ta pellicule"

    /// Message d'un nettoyage qui n'a pas abouti. L'original n'est jamais touché, le travail reste à reprendre.
    /// - Parameter error: erreur levée par le nettoyage (`CancellationError` quand iOS ou l'utilisateur l'a arrêté).
    public static func cleaningError(_ error: any Error) -> String {
        switch error {
        case is CancellationError:
            return "Nettoyage interrompu : ta vidéo originale est gardée."
        case VideoCleanerError.noVideoTrack, VideoCleanerError.noVideoFrames:
            return "Cette vidéo ne peut pas être nettoyée : l'original est gardé."
        default:
            return "Le nettoyage a échoué : ta vidéo originale est gardée."
        }
    }

    /// L'app n'a pas le droit d'ajouter des vidéos à la pellicule.
    public static let photosDenied = "Autorise l'accès à Photos dans Réglages pour y ranger tes vidéos."

    /// Le nettoyage n'a pas pu être mis en route (liste des travaux illisible, fichier inattendu).
    public static let cleaningNotStarted = "Le nettoyage n'a pas pu démarrer : ta vidéo originale est gardée."

    /// La question de l'accès à Photos n'a pas encore reçu de réponse : rien n'est refusé, il faudra un toucher.
    public static let photosNotDetermined =
        "Il reste à ranger tes vidéos dans Photos : touche « Reprendre le nettoyage »."

    /// La vidéo n'a aucune image exploitable : seul l'original a été rangé dans la pellicule.
    public static let originalSavedAlone =
        "Cette vidéo n'a pas pu être nettoyée : l'original est dans ta pellicule."

    /// L'ajout à la pellicule a échoué ; les deux vidéos restent dans l'app pour un nouvel essai.
    public static let photosSaveFailed = "Impossible de ranger les vidéos dans ta pellicule : elles restent dans l'app."

    /// L'iPhone chauffe trop : les vidéos en attente ne sont pas nettoyées tant qu'il n'a pas refroidi.
    public static let cleaningPausedForHeat = "Nettoyage en pause le temps que l'iPhone refroidisse."

    /// Pas assez d'espace libre pour écrire la copie nettoyée : le nettoyage n'a pas commencé, l'original attend.
    public static let notEnoughSpaceToClean =
        "Plus assez de place pour nettoyer tes vidéos : libère de l'espace puis touche « Reprendre le nettoyage »."

    // MARK: Écran caméra

    /// L'accès à la caméra est refusé : rien ne peut être filmé tant qu'il n'est pas donné dans Réglages.
    public static let cameraDenied = "Autorise la caméra dans Réglages pour filmer."

    /// La caméra ne tourne plus (configuration impossible, démarrage refusé, relances épuisées) : il faut relancer
    /// l'app.
    public static let cameraStopped = "La caméra s'est arrêtée. Relance l'app."

    /// La caméra est interrompue (appel, autre app, passage en arrière-plan) ou arrêtée en attendant de repartir :
    /// pas d'image, pas de mesure.
    public static let cameraPaused = "Caméra en pause"

    /// La caméra n'a pas gardé l'exposition de référence : l'enregistrement reste bloqué jusqu'à une nouvelle mesure.
    public static let referenceLockFailed = "Réglage impossible. Touche l'écran pour réessayer."

    /// Bouton qui lance l'enregistrement, et réponse « oui » à `unreliableReferenceConfirm`.
    public static let record = "Filmer"

    /// Bouton qui arrête l'enregistrement (nom lu par VoiceOver : le bouton n'a qu'un symbole).
    public static let stop = "Arrêter"

    /// Réponse « non » à `unreliableReferenceConfirm`.
    public static let cancel = "Annuler"

    /// Bouton qui relance les nettoyages en attente (cité par `photosNotDetermined`).
    public static let resumeCleaning = "Reprendre le nettoyage"

    /// Plafond de la durée filmée, en secondes (≈ 31 ans) : garantit que la conversion en entier ne peut pas échouer.
    private static let maxElapsedSeconds = 1e9

    /// Durée filmée, arrondie à la seconde inférieure : `mm:ss` sous une heure (`00:05`, `12:34`), puis `h:mm:ss`
    /// (`1:01:01`, heures sans zéro de remplissage). Une durée négative ou non finie donne `00:00`.
    /// - Parameter seconds: temps écoulé depuis le début de l'enregistrement, en secondes.
    public static func elapsed(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }

        let total = Int(min(seconds, maxElapsedSeconds).rounded(.down))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        if hours == 0 {
            return "\(twoDigits(minutes)):\(twoDigits(secs))"
        }
        return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))"
    }

    /// Entier de 0 à 99 écrit sur deux chiffres.
    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// Niveau de la batterie, arrondi au pourcentage le plus proche et ramené dans 0…100 (`Batterie 80 %`), ou
    /// `nil` quand il est inconnu (`UIDevice.batteryLevel` vaut -1 sur le simulateur ou sans suivi de la batterie).
    /// - Parameter level: niveau de 0 (vide) à 1 (pleine).
    public static func battery(level: Float) -> String? {
        guard level.isFinite, level >= 0 else { return nil }
        let percent = Int(min(level * 100, 100).rounded())
        return "Batterie \(percent) %"
    }
}
