import MWDATCamera
import MWDATCore
import SwiftUI

@main
struct WatersheepApp: App {
    private let wearables: WearablesInterface
    @StateObject private var wearablesViewModel: WearablesViewModel

    init() {
        do {
            try Wearables.configure()
        } catch {
            NSLog("[Watersheep] Failed to configure Wearables SDK: \(error)")
        }

        let wearables = Wearables.shared
        self.wearables = wearables
        _wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
    }

    var body: some Scene {
        WindowGroup {
            MainAppView(wearables: wearables, viewModel: wearablesViewModel)
                .alert("Error", isPresented: $wearablesViewModel.showError) {
                    Button("OK") {
                        wearablesViewModel.dismissError()
                    }
                } message: {
                    Text(wearablesViewModel.errorMessage)
                }
                .background(RegistrationView(viewModel: wearablesViewModel))
        }
    }
}
