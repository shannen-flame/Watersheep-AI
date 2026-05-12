import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel

  var body: some View {
    ZStack {
      Color.black
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
      } else {
        VStack(spacing: 12) {
          if shouldShowSpinner {
            ProgressView()
              .tint(.white)
          }

          Text(placeholderTitle)
            .font(.headline)
            .foregroundStyle(.white)

          Text(placeholderText)
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.white.opacity(0.68))
            .padding(.horizontal, 20)

          if viewModel.streamState.isActive || viewModel.rawFrameCallbackCount > 0 || viewModel.decodeFailureCount > 0 {
            Text(streamDiagnostics)
              .font(.caption.monospacedDigit())
              .multilineTextAlignment(.center)
              .foregroundStyle(Color.white.opacity(0.5))
              .padding(.horizontal, 20)
          }
        }
      }

      VStack {
        HStack {
          statusBadge
          Spacer()
          if viewModel.frameCount > 0 {
            Text("\(String(format: "%.1f", viewModel.frameRate)) fps")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(Color.black.opacity(0.45), in: Capsule())
          }
        }
        .padding(12)
        Spacer()
      }
    }
    .frame(maxWidth: .infinity)
    .aspectRatio(3.0 / 4.0, contentMode: .fit)
  }

  private var shouldShowSpinner: Bool {
    switch viewModel.streamState {
    case .connecting, .stopping:
      return true
    case .streaming:
      return !viewModel.hasReceivedFirstFrame
    case .idle, .failed:
      return false
    }
  }

  private var placeholderTitle: String {
    switch viewModel.streamState {
    case .idle:
      return wearablesVM.registrationState == .registered ? "Preview idle" : "Glasses disconnected"
    case .connecting:
      return viewModel.didRetryAfterFirstFrameTimeout ? "Retrying stream" : "Connecting"
    case .streaming:
      return "No frames received yet"
    case .stopping:
      return "Stopping stream"
    case .failed:
      return "Stream failed"
    }
  }

  private var placeholderText: String {
    if wearablesVM.registrationState != .registered {
      return "Connect your glasses to preview the camera feed."
    }
    return viewModel.statusMessage
  }

  private var streamDiagnostics: String {
    "frames \(viewModel.frameCount) | callbacks \(viewModel.rawFrameCallbackCount) | decode \(viewModel.decodeFailureCount)"
  }

  private var statusBadge: some View {
    Text(viewModel.streamState.title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(statusColor.opacity(0.82), in: Capsule())
  }

  private var statusColor: Color {
    switch viewModel.streamState {
    case .idle:
      return .gray
    case .connecting, .stopping:
      return .orange
    case .streaming:
      return viewModel.hasReceivedFirstFrame ? .green : .orange
    case .failed:
      return .red
    }
  }
}
