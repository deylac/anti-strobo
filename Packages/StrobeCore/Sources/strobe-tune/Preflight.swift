import Foundation
import StrobeCore

/// Vérifie les chemins avant toute analyse, pour qu'une faute de frappe ne coûte pas une passe entière
/// et surtout qu'aucun fichier écrit (`--csv`, `--out`) ne remplace l'enregistrement ou l'autre sortie.
/// Lève `ToolError` (code de sortie 1).
func checkPaths(of options: Options) throws {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: options.input.path) else {
        throw ToolError(message: "fichier introuvable : \(options.input.path)")
    }

    // `isSameFile` résout les liens symboliques et compare les identifiants de fichier (liens durs,
    // volumes insensibles à la casse) : un chemin déguisé en l'entrée est refusé comme l'entrée elle-même.
    if let output = options.output, VideoCleaner.isSameFile(output, options.input) {
        throw ToolError(message: "--out désigne le fichier d'entrée, qui ne doit pas être modifié : \(output.path)")
    }
    if let csv = options.csv {
        if VideoCleaner.isSameFile(csv, options.input) {
            throw ToolError(message: "--csv désigne le fichier d'entrée, qui ne doit pas être modifié : \(csv.path)")
        }
        if let output = options.output, VideoCleaner.isSameFile(csv, output) {
            throw ToolError(message: "--csv et --out désignent le même fichier : \(csv.path)")
        }
    }

    for (flag, url) in [("--csv", options.csv), ("--out", options.output)] {
        guard let url else { continue }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw ToolError(message: "\(flag) désigne un dossier : \(url.path)")
        }
        let parent = url.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError(message: "le dossier de \(flag) n'existe pas : \(parent.path)")
        }
    }
}
