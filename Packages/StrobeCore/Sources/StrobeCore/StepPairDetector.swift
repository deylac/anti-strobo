/// Lumière d'une zone par ses sauts : une lampe ou un stroboscope s'allume d'un coup, d'une image à la suivante, et
/// s'éteint d'un coup peu après ; le mouvement de la main, lui, fait varier la zone peu à peu, d'un pas qui change peu
/// d'une image à l'autre.
///
/// Essai sur iPhone du 7 novembre à 11 h (lampe à 5 Hz, filmée à la main en s'approchant) : dans sa zone, la lampe
/// n'ajoutait que 7 à 13 / 255 à une luma de 120 à 140 que le mouvement faisait varier davantage. La règle des deux
/// niveaux (`LightLevels`) n'y voyait rien sur la moitié de la vidéo ; les paires de sauts y retrouvent chaque phase.
///
/// Règle, sur la série des lumas d'une zone (en 255es), Δ(t) = luma(t) − luma(t − 1) :
/// - un *saut* à l'image t : Δ(t) se détache du pas du mouvement de chaque côté. Pour les 6 images d'avant, puis les 6
///   d'après : le pas est la médiane de leurs Δ, leur dispersion la médiane basse de leurs écarts à ce pas ; l'écart
///   de Δ(t) au pas atteint `stepMinimum` et `stepMotionFactor` fois la dispersion, de même signe des deux côtés.
///   Un panoramique régulier avance toujours du même pas : pas de saut. Un mouvement qui commence n'a pas le même pas
///   avant et après : pas de saut non plus. Deux sauts de même sens sur deux images de suite n'en font qu'un (image à
///   moitié éclairée pendant la pose) ; son ampleur est la somme des écarts (le plus petit des deux côtés) ;
/// - une *lumière* : un saut vers le haut, puis un saut vers le bas, sans autre saut vers le haut entre eux, au plus
///   `maxFlashRunSeconds` plus tard, d'une ampleur entre la moitié et le double de la montée, et sans que la zone
///   retombe entre les deux sous son niveau éteint plus la moitié de la montée (sinon une phase éteinte, que le
///   mouvement a fondue, les sépare) ; le niveau éteint suit le mouvement, en droite d'avant la montée à après la
///   descente. Le premier saut vers le bas qui remplit ces conditions ferme la lumière ;
/// - une lumière allumée jusqu'à la fin : un saut vers le haut sans descente, moins de `maxFlashRunSeconds` avant la
///   fin, la zone restant au-dessus de son niveau d'avant plus la moitié du saut ; allumée dès le début : un premier
///   saut vers le bas moins de `maxFlashRunSeconds` après le début ;
/// - le *rythme* : une lumière ne compte que si la zone en montre une autre, d'ampleur entre la moitié et le double,
///   à moins de `stepRhythmSeconds` d'elle. Une lumière qui clignote passe ; un faisceau qui balaie la salle, une
///   personne qui passe devant une lampe, l'iPhone qu'on abaisse vers une lumière en arrêtant, non ;
/// - images avec lumière : de la première image du saut vers le haut à la dernière avant la fin du saut vers le bas,
///   bords à moitié éclairés compris.
enum StepPairDetector {
    /// Nombre de voisins de chaque côté d'un saut pour mesurer le mouvement du moment.
    private static let motionNeighbours = 6

    private struct Step {
        /// Première image après le saut, et dernière image du saut (égales pour un saut d'une image).
        var start: Int
        var end: Int
        var rises: Bool
        var amplitude: Double
    }

    /// Lumière candidate : images `frames`, commencée à l'instant `time`, d'ampleur `amplitude`.
    private struct Light {
        var frames: Range<Int>
        var time: Double
        var amplitude: Double
    }

    /// Vrai pour chaque image de `lumas` (luma d'une zone, en 255es, horodatée par `times`) qu'une paire de sauts dit
    /// avec lumière.
    static func litFrames(_ lumas: [UInt8], times: [Double], config: FlashDetectorConfig) -> [Bool] {
        litFrames(values: lumas.map(Double.init), times: times, config: config)
    }

    /// Comme `litFrames(_:times:config:)`, pour une série de valeurs dans la même unité (255es de luma), pas
    /// forcément entières (voir `RoomLight`).
    static func litFrames(values: [Double], times: [Double], config: FlashDetectorConfig) -> [Bool] {
        let count = values.count
        var lit = [Bool](repeating: false, count: count)
        guard count > 2 else { return lit }

        var deltas = [Double](repeating: 0, count: count)
        for frame in 1..<count { deltas[frame] = values[frame] - values[frame - 1] }
        let steps = findSteps(deltas: deltas, minimum: config.stepMinimum * 255, factor: config.stepMotionFactor)
        let maxRun = config.maxFlashRunSeconds + FlashDetectorConfig.runLengthTolerance

        /// Vrai si les images `frames` restent toutes au-dessus de `floor` (aucune, c'est vrai aussi).
        func staysAbove(_ floor: Double, _ frames: Range<Int>) -> Bool {
            frames.isEmpty || values[frames].min()! >= floor
        }
        /// Vrai si, entre les deux sauts (bords exclus), la zone reste au-dessus de son niveau éteint plus la moitié
        /// de la montée. Le niveau éteint suit le mouvement : droite entre l'image d'avant la montée et la dernière
        /// image de la descente (sur l'essai sur iPhone, la main assombrissait la zone de 26 / 255 pendant une phase).
        func staysLit(rise: Step, fall: Step) -> Bool {
            let before = values[rise.start - 1]
            let after = values[fall.end]
            let span = Double(fall.end - (rise.start - 1))
            return ((rise.end + 1)..<max(rise.end + 1, fall.start - 1)).allSatisfy { frame in
                let off = before + (after - before) * Double(frame - (rise.start - 1)) / span
                return values[frame] >= off + rise.amplitude / 2
            }
        }

        var lights: [Light] = []
        for (index, rise) in steps.enumerated() where rise.rises {
            var blocked = false
            var paired = false
            for fall in steps[(index + 1)...] {
                guard !fall.rises, times[fall.start] - times[rise.start] <= maxRun else {
                    blocked = true
                    break
                }
                let ratio = fall.amplitude / rise.amplitude
                if ratio >= 0.5, ratio <= 2, staysLit(rise: rise, fall: fall) {
                    lights.append(Light(frames: rise.start..<fall.end, time: times[rise.start], amplitude: rise.amplitude))
                    paired = true
                    break
                }
            }
            if !paired, !blocked, times[count - 1] - times[rise.start] <= maxRun,
               staysAbove(values[rise.start - 1] + rise.amplitude / 2, (rise.end + 1)..<count) {
                lights.append(Light(frames: rise.start..<count, time: times[rise.start], amplitude: rise.amplitude))
            }
        }
        if let fall = steps.first, !fall.rises, times[fall.start] - times[0] <= maxRun {
            lights.append(Light(frames: 0..<fall.end, time: times[0], amplitude: fall.amplitude))
        }

        // Le rythme : chaque lumière doit en avoir une autre, d'ampleur voisine, à moins de `stepRhythmSeconds`.
        lights.sort { $0.time < $1.time }
        for (index, light) in lights.enumerated() {
            let similar = { (other: Light) in
                abs(other.time - light.time) <= config.stepRhythmSeconds
                    && other.amplitude >= light.amplitude / 2 && other.amplitude <= light.amplitude * 2
            }
            let before = lights[..<index].reversed().prefix { light.time - $0.time <= config.stepRhythmSeconds }
            let after = lights[(index + 1)...].prefix { $0.time - light.time <= config.stepRhythmSeconds }
            guard before.contains(where: similar) || after.contains(where: similar) else { continue }
            for frame in light.frames { lit[frame] = true }
        }
        return lit
    }

    /// Les sauts de la série `deltas` (Δ(0) = 0), fusionnés quand deux sauts de même sens se suivent.
    private static func findSteps(deltas: [Double], minimum: Double, factor: Double) -> [Step] {
        let count = deltas.count
        var buffer = [Double](repeating: 0, count: motionNeighbours)

        /// Écart signé de Δ(`frame`) au pas du mouvement des images `side`, s'il s'en détache (au moins `minimum` et
        /// `factor` fois leur dispersion) ; nil sinon. Sans voisins, le pas et la dispersion sont nuls.
        func excess(_ frame: Int, over side: Range<Int>) -> Double? {
            var pace = 0.0
            var spread = 0.0
            if !side.isEmpty {
                for (slot, neighbour) in side.enumerated() { buffer[slot] = deltas[neighbour] }
                buffer[0..<side.count].sort()
                pace = buffer[(side.count - 1) / 2]
                for (slot, neighbour) in side.enumerated() { buffer[slot] = abs(deltas[neighbour] - pace) }
                buffer[0..<side.count].sort()
                spread = buffer[(side.count - 1) / 2]
            }
            let value = deltas[frame] - pace
            return abs(value) >= max(minimum, factor * spread) ? value : nil
        }

        var steps: [Step] = []
        for frame in 1..<count {
            guard let early = excess(frame, over: max(1, frame - motionNeighbours)..<frame),
                  let late = excess(frame, over: (frame + 1)..<min(count, frame + motionNeighbours + 1)),
                  (early > 0) == (late > 0)
            else { continue }
            let rises = early > 0
            let amplitude = min(abs(early), abs(late))
            if let last = steps.last, last.rises == rises, last.end == frame - 1 {
                steps[steps.count - 1].end = frame
                steps[steps.count - 1].amplitude += amplitude
            } else {
                steps.append(Step(start: frame, end: frame, rises: rises, amplitude: amplitude))
            }
        }
        return steps
    }
}
