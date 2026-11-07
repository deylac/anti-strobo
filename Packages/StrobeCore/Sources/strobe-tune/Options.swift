import Foundation
import StrobeCore

/// Option mal formée ou inconnue : code de sortie 64, avec le message et le mode d'emploi sur stderr.
struct UsageError: Error {
    var message: String
}

/// Ce que demande la ligne de commande.
enum Command {
    case help
    case run(Options)
}

/// Réglages d'un lancement de `strobe-tune`.
struct Options {
    var input: URL
    /// Vidéo nettoyée à écrire ; sans elle, analyse seule.
    var output: URL?
    /// Fichier CSV d'une ligne par image.
    var csv: URL?
    var config = CleanerConfig()

    /// Mode d'emploi, avec les valeurs par défaut lues dans `CleanerConfig` (jamais recopiées).
    static var usage: String {
        let defaults = CleanerConfig()
        let detector = defaults.detector
        return """
        Usage : strobe-tune <entrée.mov> [options]

        Rejoue la détection d'éclairs (et le nettoyage) sur un enregistrement, pour régler les seuils.
        Sans --out, analyse seule (même bilan, sans écrire de vidéo). Le bilan est écrit sur stdout,
        l'avancement sur stderr quand c'est un terminal.

          --out <fichier>   écrit la vidéo nettoyée
          --csv <fichier>   écrit une ligne par image, avec en-tête : index,time,meanLuma,saturatedFraction,verdict
          --jump <x>        rapport de luma minimal entre lumière et sans lumière (défaut \(detector.relativeJump))
          --margin <x>      marge absolue de luma (défaut \(detector.absoluteMargin))
          --sat <x>         fraction saturée maximale (défaut \(detector.saturatedFractionMax))
          --window <s>      fenêtre des deux niveaux de lumière, en secondes (défaut \(detector.baselineWindowSeconds))
          --max-run <s>     durée maximale d'une lumière, en secondes (défaut \(detector.maxFlashRunSeconds))
          --edge <x>        part de l'écart entre sans et avec lumière au-delà de laquelle une image à moitié
                            éclairée part avec la lumière, entre 0 et 0.5 (défaut \(detector.edgeShare))
          --zone-jump <x>   rapport de luma minimal dans une zone de l'image (défaut \(detector.zoneRelativeJump))
          --zone-margin <x> marge absolue de luma dans une zone (défaut \(detector.zoneAbsoluteMargin))
          --step-factor <x> saut de zone minimal, en multiple du mouvement du moment (défaut \(detector.stepMotionFactor))
          --step-rhythm <s> délai maximal entre deux lumières d'une zone pour qu'une paire de sauts compte
                            (défaut \(detector.stepRhythmSeconds))
          --no-steps        juge les zones par deux niveaux de lumière seulement, pas par leurs sauts
          --no-zones        juge seulement l'image entière, pas ses zones (une petite lampe peut alors échapper)
          --hold <s>        durée maximale de répétition d'une image, en secondes (défaut \(defaults.maxHoldSeconds))
          --no-interp       ne recrée pas les images manquantes : répète la dernière bonne image (comme la V1)
          --no-denoise      ne débruite pas, même une scène sombre
          --no-brighten     n'éclaircit pas une scène sombre (et la débruite comme avant, à 0,5)
          -h, --help        affiche ce mode d'emploi

        Codes de sortie : 0 succès, 64 ligne de commande invalide, 1 erreur d'exécution.
        """
    }

    /// Lit les arguments (sans le nom du programme). Lève `UsageError` pour toute option inconnue,
    /// valeur manquante ou non numérique, et pour une entrée absente ou en trop.
    static func parse(_ arguments: [String]) throws -> Command {
        var input: String?
        var output: String?
        var csv: String?
        var config = CleanerConfig()

        var index = 0
        /// Valeur qui suit l'option `flag` ; une autre option n'est pas une valeur.
        func value(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                throw UsageError(message: "valeur manquante pour \(flag)")
            }
            return arguments[index]
        }
        func number(for flag: String) throws -> Double {
            let text = try value(for: flag)
            guard let number = Double(text), number.isFinite, number >= 0 else {
                throw UsageError(message: "\(flag) attend un nombre positif ou nul, pas « \(text) »")
            }
            return number
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help": return .help
            case "--out": output = try value(for: argument)
            case "--csv": csv = try value(for: argument)
            case "--jump": config.detector.relativeJump = try number(for: argument)
            case "--margin": config.detector.absoluteMargin = try number(for: argument)
            case "--sat": config.detector.saturatedFractionMax = try number(for: argument)
            case "--window": config.detector.baselineWindowSeconds = try number(for: argument)
            case "--max-run": config.detector.maxFlashRunSeconds = try number(for: argument)
            case "--edge":
                let share = try number(for: argument)
                guard share <= 0.5 else { throw UsageError(message: "--edge attend une part entre 0 et 0.5, pas \(share)") }
                config.detector.edgeShare = share
            case "--zone-jump": config.detector.zoneRelativeJump = try number(for: argument)
            case "--zone-margin": config.detector.zoneAbsoluteMargin = try number(for: argument)
            case "--step-factor": config.detector.stepMotionFactor = try number(for: argument)
            case "--no-steps": config.detector.watchesZoneSteps = false
            case "--step-rhythm": config.detector.stepRhythmSeconds = try number(for: argument)
            case "--no-zones": config.detector.watchesZones = false
            case "--hold": config.maxHoldSeconds = try number(for: argument)
            case "--no-interp": config.interpolate = false
            case "--no-denoise": config.denoise = false
            case "--no-brighten": config.brightenDarkScenes = false
            default:
                guard !argument.hasPrefix("-") || argument == "-" else {
                    throw UsageError(message: "option inconnue : \(argument)")
                }
                guard input == nil else {
                    throw UsageError(message: "une seule entrée est attendue (« \(input ?? "") » puis « \(argument) »)")
                }
                input = argument
            }
            index += 1
        }

        guard let input else { throw UsageError(message: "fichier d'entrée manquant") }
        return .run(Options(
            input: URL(fileURLWithPath: input),
            output: output.map { URL(fileURLWithPath: $0) },
            csv: csv.map { URL(fileURLWithPath: $0) },
            config: config
        ))
    }
}
