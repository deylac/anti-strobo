import SwiftUI

/// Point d'entrée de l'app : une seule fenêtre, l'écran caméra, et la file des nettoyages partagée par l'écran.
@main
struct AntiStroboApp: App {
    @State private var cleaning = CleaningCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FormatReport.logIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .environment(cleaning)
                #if DEBUG
                .task {
                    // Vérification au simulateur sans toucher l'écran : `-cleanSampleOnLaunch` nettoie l'échantillon
                    // aux éclairs, `-cleanHalfDutySampleOnLaunch` celui de la lampe.
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("-cleanSampleOnLaunch") {
                        await cleaning.cleanDebugSample(.flashes)
                    }
                    if arguments.contains("-cleanHalfDutySampleOnLaunch") {
                        await cleaning.cleanDebugSample(.halfDutyLamp)
                    }
                }
                #endif
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Au lancement et à chaque retour au premier plan : la liste des travaux a pu être illisible (iPhone
            // verrouillé) ou un enregistrement a pu rester sans travail (app tuée pendant l'enregistrement).
            if phase == .active {
                cleaning.resumePending()
            }
        }
    }
}
