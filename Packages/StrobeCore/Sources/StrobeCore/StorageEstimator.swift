import Foundation

/// Estime l'espace occupé par un enregistrement et sa copie nettoyée, et le temps qu'il reste avant de manquer
/// de place. L'app n'impose aucune durée maximale : le stockage libre est la vraie limite, et il est affiché.
public enum StorageEstimator {
    /// Bits par pixel du flux HEVC de l'enregistrement : 0,09 donne ≈ 2,8 Mo/s en 1080p à 120 i/s
    /// (≈ 10 Go par heure).
    private static let bitsPerPixel = 0.09

    /// Marge d'espace laissée libre pour le système, en octets.
    public static let safetyBytes: Int64 = 500_000_000

    /// Débit nominal d'un enregistrement, en octets par seconde : `width × height × fps × 0,09 / 8`.
    /// - Parameters:
    ///   - width: largeur de l'image, en pixels.
    ///   - height: hauteur de l'image, en pixels.
    ///   - fps: cadence de capture, en images par seconde.
    public static func nominalBytesPerSecond(width: Int, height: Int, fps: Double) -> Double {
        Double(width) * Double(height) * fps * bitsPerPixel / 8
    }

    /// Débit de la copie nettoyée, en octets par seconde de vidéo, pour un original filmé à `sourceFPS` au
    /// débit `sourceBytesPerSecond` : la règle de l'écriture (`VideoCleaner.outputBitRate`), soit
    /// `max(4 Mbit/s, débit × 30 / sourceFPS × 1,5)`.
    ///
    /// La copie est à 30 i/s quelle que soit la cadence de l'original : au débit nominal (proportionnel à la
    /// cadence), elle pèse autant à 120, 60 et 30 i/s, soit 0,375, 0,75 puis 1,5 fois l'original. Comme
    /// l'écriture, une cadence inconnue (nulle, négative ou non finie) compte pour 120 i/s.
    public static func cleanedBytesPerSecond(sourceBytesPerSecond: Double, sourceFPS: Double) -> Double {
        VideoCleaner.outputBitRate(
            sourceBitRate: sourceBytesPerSecond * 8,
            sourceFPS: VideoCleaner.sourceFPS(nominal: sourceFPS),
            outputFPS: CleanerConfig().outputFPS
        ) / 8
    }

    /// Durée d'enregistrement encore possible, en secondes :
    /// `max(0, (freeBytes − safetyBytes − copies dues) / (bytesPerSecond + débit de la copie))`.
    ///
    /// Chaque seconde enregistrée occupe `bytesPerSecond` pour l'original, plus le débit de sa copie nettoyée
    /// (`cleanedBytesPerSecond` à cette cadence et ce débit), écrite ensuite. Les copies encore dues sont
    /// réservées : celle de l'enregistrement en cours (`recordedBytes` déjà écrits, au même débit) et celles
    /// des originaux qui attendent leur nettoyage (`owedCleanedBytes`). `safetyBytes` reste toujours libre pour
    /// le système. Une taille négative compte pour rien ; un débit nul, négatif ou non fini, ou un résultat
    /// non fini, donne 0.
    /// - Parameters:
    ///   - freeBytes: espace libre, en octets.
    ///   - bytesPerSecond: débit de l'original, en octets par seconde (voir `nominalBytesPerSecond`).
    ///   - fps: cadence de capture de l'original.
    ///   - recordedBytes: taille déjà écrite de l'enregistrement en cours, en octets.
    ///   - owedCleanedBytes: taille estimée des copies nettoyées des originaux en attente, en octets (voir
    ///     `VideoCleaner.estimatedCleanedBytes(of:)`).
    ///   - safetyBytes: marge d'espace à ne jamais consommer, en octets.
    public static func remainingRecordingSeconds(
        freeBytes: Int64,
        bytesPerSecond: Double,
        fps: Double,
        recordedBytes: Int64 = 0,
        owedCleanedBytes: Int64 = 0,
        safetyBytes: Int64 = StorageEstimator.safetyBytes
    ) -> TimeInterval {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return 0 }
        let cleanedPerSecond = cleanedBytesPerSecond(sourceBytesPerSecond: bytesPerSecond, sourceFPS: fps)
        // En flottant : `freeBytes − safetyBytes` pourrait dépasser Int64 avec des valeurs extrêmes.
        let recordingCopy = Double(max(0, recordedBytes)) / bytesPerSecond * cleanedPerSecond
        let reservedBytes = Double(max(0, owedCleanedBytes)) + recordingCopy
        let usableBytes = Double(freeBytes) - Double(safetyBytes) - reservedBytes
        let seconds = usableBytes / (bytesPerSecond + cleanedPerSecond)
        return seconds.isFinite ? max(0, seconds) : 0
    }

    /// Vrai s'il reste la place d'écrire une copie nettoyée de `cleanedBytes` octets (voir
    /// `VideoCleaner.estimatedCleanedBytes(of:)`) sans entamer la marge : `freeBytes ≥ cleanedBytes + safetyBytes`.
    /// - Parameters:
    ///   - cleanedBytes: taille estimée de la copie, en octets (négative : comptée pour rien).
    ///   - freeBytes: espace libre, en octets.
    ///   - safetyBytes: marge d'espace à ne jamais consommer, en octets.
    public static func hasRoomToClean(
        cleanedBytes: Int64,
        freeBytes: Int64,
        safetyBytes: Int64 = StorageEstimator.safetyBytes
    ) -> Bool {
        Double(freeBytes) >= Double(max(0, cleanedBytes)) + Double(safetyBytes)
    }
}
