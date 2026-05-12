import MWDATCore
import SwiftUI

struct StreamSessionView: View {
  @ObservedObject private var wearablesViewModel: WearablesViewModel
  @ObservedObject private var viewModel: StreamSessionViewModel

  init(viewModel: StreamSessionViewModel, wearablesVM: WearablesViewModel) {
    self.viewModel = viewModel
    self.wearablesViewModel = wearablesVM
  }

  var body: some View {
    VStack(spacing: 20) {
      if viewModel.isStreaming {
        StreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)
        Button("Stop Camera") {
          Task {
            await viewModel.stopStreaming(reason: "stream session view")
          }
        }
        .buttonStyle(.borderedProminent)
      } else {
        VStack(spacing: 20) {
          StreamView(viewModel: viewModel, wearablesVM: wearablesViewModel)

          Text(viewModel.hasActiveDevice ? "Your glasses are ready to stream." : "Waiting for connected glasses.")
            .font(.subheadline)
            .foregroundStyle(.secondary)

          Button("Start Camera") {
            Task {
              await viewModel.startStreaming(reason: "stream session view")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(wearablesViewModel.registrationState != .registered)
        }
      }
    }
    .padding(24)
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") {
        viewModel.dismissError()
      }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}
