import Foundation

/// La lumière de la pièce, vue par toutes les zones à la fois (règle V2-R24).
///
/// Une lampe qui éclaire la pièce fait monter presque toutes les zones d'un même rapport, dans la même image ;
/// le mouvement les fait varier chacune à sa façon. La médiane, sur les zones, du saut de luma d'une image à la
/// suivante (en logarithme) suit donc la lampe même quand l'image entière la voit mal : essai sur iPhone du
/// 7 novembre à 15 h, dos à la lampe, l'image entière passait de 0,20 à 0,28 (rapport 1,4, pas deux niveaux), la
/// médiane des sauts des zones de ±0,3 à chaque allumage et extinction, contre ±0,05 pour le mouvement. Cumulée,
/// elle donne une série où les paires de sauts (`StepPairDetector`) trouvent les éclairs de la pièce.
enum RoomLight {
    /// Zone trop sombre (en 255es) pour que son saut compte : le bruit y fait des rapports au hasard.
    private static let minimumLuma: UInt8 = 12
    /// Ajouté aux lumas avant le rapport, pour que les zones presque noires ne dominent pas.
    private static let offset = 4.0
    /// Échelle de la série : +10 % de lumière dans la pièce valent `stepMinimum` (4 / 255).
    private static let scale = 4 / log(1.1)

    /// Vrai pour chaque image que les paires de sauts de la lumière de la pièce disent éclairée. Tout faux s'il y a
    /// moins de trois zones.
    static func litFrames(_ stats: [FrameStats], times: [Double], config: FlashDetectorConfig) -> [Bool] {
        guard let zoneCount = stats.first?.zoneLumas.count, zoneCount >= 3,
              stats.allSatisfy({ $0.zoneLumas.count == zoneCount })
        else { return [Bool](repeating: false, count: stats.count) }
        var values = [Double](repeating: 0, count: stats.count)
        var steps: [Double] = []
        steps.reserveCapacity(zoneCount)
        for index in stats.indices.dropFirst() {
            let now = stats[index].zoneLumas
            let before = stats[index - 1].zoneLumas
            steps.removeAll(keepingCapacity: true)
            for zone in 0..<zoneCount where max(now[zone], before[zone]) >= minimumLuma {
                steps.append(log((Double(now[zone]) + offset) / (Double(before[zone]) + offset)))
            }
            steps.sort()
            let median = steps.isEmpty ? 0 : steps[(steps.count - 1) / 2]
            values[index] = values[index - 1] + scale * median
        }
        return StepPairDetector.litFrames(values: values, times: times, config: config)
    }
}
