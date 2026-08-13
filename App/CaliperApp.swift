import SwiftData
import SwiftUI

@main
struct CaliperApp: App {

    /// Built once, at launch. A failure here is not recoverable — there is no
    /// useful Caliper without its store — so it surfaces as a diagnostic screen
    /// rather than a crash or a silently empty app.
    private let container: Result<ModelContainer, Error>

    init() {
        container = Result { try CaliperModelContainer.make() }
    }

    var body: some Scene {
        WindowGroup {
            switch container {
            case .success(let container):
                RootView()
                    .modelContainer(container)
            case .failure(let error):
                StoreUnavailableView(error: error)
            }
        }
    }
}

/// M0 placeholder. The logging loop lands at M3.
struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Caliper")
                .font(.largeTitle.weight(.semibold))
            Text("M0 — scaffold")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct StoreUnavailableView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 12) {
            Text("Caliper can't open its data store.")
                .font(.headline)
            Text(String(describing: error))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
