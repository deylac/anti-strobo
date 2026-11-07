// strobe-tune : outil en ligne de commande de réglage hors ligne des seuils de détection.
// Rejoue l'analyse (et, avec --out, le nettoyage) sur un enregistrement réel, sans nouvelle build de l'app.
// Codes de sortie : 0 succès, 64 ligne de commande invalide, 1 erreur d'exécution.

import Foundation
import StrobeCore

/// Mesure et juge chaque image de `options.input`, avec avancement.
func analyze(_ options: Options) async throws -> [FrameRecord] {
    let printer = ProgressPrinter("Analyse")
    defer { printer.finish() }
    return try await VideoCleaner(config: options.config).analyze(options.input) { printer.update($0) }
}

/// Analyse (CSV ou analyse seule) et/ou nettoyage, puis affiche le bilan sur stdout.
func execute(_ options: Options) async throws {
    try checkPaths(of: options)

    let report: CleanReport
    if let output = options.output {
        // `clean` ré-analyse lui-même : l'analyse séparée ne sert qu'au CSV.
        if let csv = options.csv {
            try writeCSV(for: try await analyze(options), to: csv)
        }
        let printer = ProgressPrinter("Nettoyage")
        defer { printer.finish() }
        report = try await VideoCleaner(config: options.config)
            .clean(input: options.input, output: output) { printer.update($0) }
    } else {
        let records = try await analyze(options)
        if let csv = options.csv { try writeCSV(for: records, to: csv) }
        // Même plan que le nettoyage, sans écrire de vidéo : pour itérer sur les seuils sans payer l'encodage.
        report = try await VideoCleaner(config: options.config).plannedReport(for: records, of: options.input)
    }
    print(reportText(for: report, cleaned: options.output != nil), terminator: "")
}

do {
    switch try Options.parse(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        print(Options.usage)
    case .run(let options):
        try await execute(options)
    }
} catch let error as UsageError {
    writeToStandardError("strobe-tune : \(error.message)\n\n\(Options.usage)\n")
    exit(64)
} catch {
    writeToStandardError("strobe-tune : \(describe(error))\n")
    exit(1)
}
