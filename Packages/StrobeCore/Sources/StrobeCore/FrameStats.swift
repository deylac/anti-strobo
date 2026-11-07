import CoreVideo

/// Statistiques de luminance d'une image : luma moyenne et part saturée normalisées dans 0…1, luma de chaque zone.
public struct FrameStats: Sendable, Equatable, Codable {
    /// Luma moyenne des pixels échantillonnés (0 = noir, 1 = blanc).
    public var meanLuma: Double
    /// Part des pixels échantillonnés dont la luma normalisée atteint `LumaSampler.saturationThreshold`.
    public var saturatedFraction: Double
    /// Luma moyenne de chaque zone de la grille `LumaSampler.zoneColumns` × `LumaSampler.zoneRows`, en 255es, rangée
    /// par rangée de haut en bas, de gauche à droite (image telle qu'elle est stockée, sans l'orientation de la
    /// vidéo). Une petite lampe allumée change à peine la luma moyenne d'une pièce claire, mais nettement celle de
    /// sa zone. Vide quand l'image est trop petite pour donner au moins un point à chaque zone.
    public var zoneLumas: [UInt8]

    public init(meanLuma: Double, saturatedFraction: Double, zoneLumas: [UInt8] = []) {
        self.meanLuma = meanLuma
        self.saturatedFraction = saturatedFraction
        self.zoneLumas = zoneLumas
    }

    private enum CodingKeys: String, CodingKey {
        case meanLuma, saturatedFraction, zoneLumas
    }

    /// Des statistiques écrites avant les zones se lisent sans zones.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meanLuma = try container.decode(Double.self, forKey: .meanLuma)
        saturatedFraction = try container.decode(Double.self, forKey: .saturatedFraction)
        zoneLumas = try container.decodeIfPresent([UInt8].self, forKey: .zoneLumas) ?? []
    }

    /// La zone `zone` vue comme une image entière : sa luma, sans part saturée (la saturation se juge sur toute
    /// l'image) ni zones.
    func zone(_ zone: Int) -> FrameStats {
        FrameStats(meanLuma: Double(zoneLumas[zone]) / 255, saturatedFraction: 0)
    }

    /// Les mêmes statistiques sans les zones, une fois les éclairs jugés (mémoire du nettoyage d'une longue vidéo).
    var withoutZones: FrameStats {
        FrameStats(meanLuma: meanLuma, saturatedFraction: saturatedFraction)
    }
}

/// Mesure la luminance d'un `CVPixelBuffer` en sous-échantillonnant la grille de pixels.
public enum LumaSampler {
    /// Luma normalisée à partir de laquelle un pixel est considéré comme brûlé (saturé).
    public static let saturationThreshold = 0.98
    /// Grille des zones (`FrameStats.zoneLumas`) : 8 × 8. Mesuré sur l'essai sur iPhone (lampe dans une pièce en plein
    /// jour, filmée à la main) : plus fine (16 × 16), une zone est assez petite pour qu'un bord net (fenêtre, lampe
    /// toute proche) qui bouge avec la main la fasse clignoter ; plus grossière, la lampe s'y noie.
    public static let zoneColumns = 8
    public static let zoneRows = 8

    /// Mesure la luma moyenne, la fraction de pixels saturés et la luma de chaque zone de `buffer`.
    ///
    /// Formats pris en charge :
    /// - `420YpCbCr8BiPlanarFullRange` : plan Y lu tel quel, Y / 255.
    /// - `420YpCbCr8BiPlanarVideoRange` : (Y − 16) / 219, borné à 0…1.
    /// - `32BGRA` : luma Rec.709 (0,2126 R + 0,7152 G + 0,0722 B) / 255, utile aux tests et à la CLI.
    ///
    /// Un format non pris en charge, ou une image vide, donne des statistiques nulles.
    /// - Parameters:
    ///   - buffer: image à mesurer.
    ///   - step: pas d'échantillonnage en x et en y, en pixels ; toute valeur inférieure à 1 est ramenée à 1.
    public static func stats(of buffer: CVPixelBuffer, step: Int = 8) -> FrameStats {
        let step = max(1, step)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return measureLumaPlane(of: buffer, step: step, videoRange: false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return measureLumaPlane(of: buffer, step: step, videoRange: true)
        case kCVPixelFormatType_32BGRA:
            return measureBGRA(of: buffer, step: step)
        default:
            return empty
        }
    }

    private static let empty = FrameStats(meanLuma: 0, saturatedFraction: 0)

    /// Plan Y (plan 0) d'un format bi-planaire : Y / 255 en plein écart, (Y − 16) / 219 borné à 0…1 en écart vidéo.
    private static func measureLumaPlane(of buffer: CVPixelBuffer, step: Int, videoRange: Bool) -> FrameStats {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return empty }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

        return measure(
            width: CVPixelBufferGetWidthOfPlane(buffer, 0),
            height: CVPixelBufferGetHeightOfPlane(buffer, 0),
            step: step,
            luma: { x, y in
                let value = Double(bytes[y * rowBytes + x])
                return clamp01(videoRange ? (value - 16) / 219 : value / 255)
            },
            stripLumaSum: { y, start, end in
                // Somme entière des octets, rapide même sans optimisation du compilateur (version Debug). En écart
                // vidéo, (Y − 16) / 219 borné à 0…1 vaut (borne(Y, 16, 235) − 16) / 219.
                let row = bytes + y * rowBytes
                var total: UInt32 = 0
                if videoRange {
                    for x in start..<end { total &+= UInt32(min(max(row[x], 16), 235)) }
                    return (Double(total) - 16 * Double(end - start)) / 219
                }
                for x in start..<end { total &+= UInt32(row[x]) }
                return Double(total) / 255
            }
        )
    }

    private static func measureBGRA(of buffer: CVPixelBuffer, step: Int) -> FrameStats {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return empty }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let luma: (Int, Int) -> Double = { x, y in
            let pixel = y * rowBytes + x * 4
            let blue = Double(bytes[pixel])
            let green = Double(bytes[pixel + 1])
            let red = Double(bytes[pixel + 2])
            return clamp01((0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255)
        }

        return measure(
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            step: step,
            luma: luma,
            stripLumaSum: { y, start, end in (start..<end).reduce(0) { $0 + luma($1, y) } }
        )
    }

    /// Toute l'image : luma `luma(x, y)` des points (0, step, 2·step, …) des lignes 0, step, 2·step, …
    ///
    /// Zones (colonne `x × zoneColumns / width`, rangée `y × zoneRows / height`) : `stripLumaSum(y, début, fin)`,
    /// somme des lumas des pixels `début..<fin` de la ligne `y`, sur chaque morceau de ligne, une ligne par pas,
    /// décalée d'une ligne à l'autre (ligne `k × step + (5k mod step)`). Prise point par point ou toujours sur les
    /// mêmes lignes, une zone, petite, verrait un motif fin et contrasté (stores, écran à LED) changer d'une image à
    /// l'autre au moindre mouvement ; sa moyenne sur toutes les colonnes et toutes les phases de lignes, non.
    private static func measure(
        width: Int,
        height: Int,
        step: Int,
        luma: (_ x: Int, _ y: Int) -> Double,
        stripLumaSum: (_ y: Int, _ start: Int, _ end: Int) -> Double
    ) -> FrameStats {
        var sum = 0.0
        var saturated = 0
        var count = 0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let value = luma(x, y)
                sum += value
                if value >= saturationThreshold { saturated += 1 }
                count += 1
            }
        }
        guard count > 0 else { return empty }

        var zoneSums = [Double](repeating: 0, count: zoneColumns * zoneRows)
        var zoneCounts = [Int](repeating: 0, count: zoneColumns * zoneRows)
        let zoneBounds = (0...zoneColumns).map { $0 * width / zoneColumns }
        for block in 0... {
            let y = block * step + (5 * block) % step
            guard y < height else { break }
            let zoneRowStart = y * zoneRows / height * zoneColumns
            for column in 0..<zoneColumns {
                zoneSums[zoneRowStart + column] += stripLumaSum(y, zoneBounds[column], zoneBounds[column + 1])
                zoneCounts[zoneRowStart + column] += zoneBounds[column + 1] - zoneBounds[column]
            }
        }
        let zoneLumas = zoneCounts.contains(0)
            ? []
            : zip(zoneSums, zoneCounts).map { UInt8(($0 / Double($1) * 255).rounded()) }

        return FrameStats(
            meanLuma: sum / Double(count),
            saturatedFraction: Double(saturated) / Double(count),
            zoneLumas: zoneLumas
        )
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
