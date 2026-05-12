/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Combine
import Foundation
import MWDATCamera
import MWDATCore
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamLifecycleState: Equatable {
  case idle
  case connecting
  case streaming
  case stopping
  case failed(String)

  var title: String {
    switch self {
    case .idle:
      return "Idle"
    case .connecting:
      return "Connecting"
    case .streaming:
      return "Streaming"
    case .stopping:
      return "Stopping"
    case .failed:
      return "Stream Failed"
    }
  }

  var isActive: Bool {
    switch self {
    case .connecting, .streaming, .stopping:
      return true
    case .idle, .failed:
      return false
    }
  }
}

@MainActor
final class StreamSessionViewModel: ObservableObject {
  private enum Constants {
    static let firstFrameTimeoutSeconds: Double = 12
    static let frameRateLogInterval: TimeInterval = 2
    static let previewFramePublishInterval: CFTimeInterval = 0.12
    static let stalledFrameIntervalsBeforeRecovery = 3
  }

  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError = false
  @Published var errorMessage = ""
  @Published var hasActiveDevice = false
  @Published private(set) var streamState: StreamLifecycleState = .idle
  @Published private(set) var statusMessage = "Camera stream is idle."
  @Published private(set) var frameCount = 0
  @Published private(set) var frameRate: Double = 0
  @Published private(set) var didRetryAfterFirstFrameTimeout = false
  @Published private(set) var didRetryAfterStreamStall = false
  @Published private(set) var didRetryAfterInternalStartError = false
  @Published private(set) var activeCodec = "raw"
  @Published private(set) var rawFrameCallbackCount = 0
  @Published private(set) var decodeFailureCount = 0
  @Published private(set) var lastFrameReceivedAt: Date?

  var isStreaming: Bool {
    streamState.isActive
  }

  var hasValidFrame: Bool {
    currentVideoFrame != nil && hasReceivedFirstFrame
  }

  var currentFrameAge: TimeInterval? {
    guard let lastFrameReceivedAt else { return nil }
    return Date().timeIntervalSince(lastFrameReceivedAt)
  }

  func hasFreshFrame(maxAge: TimeInterval = 3) -> Bool {
    guard hasValidFrame, let currentFrameAge else { return false }
    return currentFrameAge <= maxAge
  }

  private var streamSession: StreamSession?
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var startTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var firstFrameWatchdogTask: Task<Void, Never>?
  private var frameRateTask: Task<Void, Never>?
  private var startGeneration = 0
  private var activeVideoCodec = VideoCodec.raw
  private var isRecoveringStream = false
  private var lastFrameRateSampleCount = 0
  private var lastFrameRateSampleTime = CACurrentMediaTime()
  private var lastPreviewFramePublishedAt: CFTimeInterval = 0
  private var consecutiveZeroFrameIntervals = 0

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)

    deviceMonitorTask = Task { @MainActor in
      for await device in deviceSelector.activeDeviceStream() {
        self.hasActiveDevice = device != nil
      }
    }
  }

  deinit {
    startTask?.cancel()
    stopTask?.cancel()
    firstFrameWatchdogTask?.cancel()
    frameRateTask?.cancel()
    deviceMonitorTask?.cancel()
  }

  func handleStartStreaming() async {
    await startStreaming(reason: "user request")
  }

  func startSession() async {
    await startStreaming(reason: "legacy startSession")
  }

  func startStreaming(reason: String) async {
    switch streamState {
    case .connecting, .streaming:
      log("start ignored while \(streamState.title.lowercased()) (\(reason))")
      return
    case .stopping:
      log("start deferred while stopping (\(reason))")
      return
    case .idle, .failed:
      break
    }

    guard startTask == nil else {
      log("duplicate start ignored while start task is active (\(reason))")
      return
    }

    startTask = Task { [weak self] in
      guard let self else { return }
      await self.performStart(reason: reason, retryingAfterTimeout: false)
      self.startTask = nil
    }
    await startTask?.value
  }

  func stopSession() async {
    await stopStreaming(reason: "user request")
  }

  func stopStreaming(reason: String) async {
    if case .idle = streamState {
      log("stop ignored while idle (\(reason))")
      return
    }

    guard stopTask == nil else {
      log("duplicate stop ignored while stop task is active (\(reason))")
      return
    }

    stopTask = Task { [weak self] in
      guard let self else { return }
      await self.performStop(reason: reason, finalState: .idle)
      self.stopTask = nil
    }
    await stopTask?.value
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  private func performStart(reason: String, retryingAfterTimeout: Bool) async {
    startGeneration += 1
    let generation = startGeneration
    if !retryingAfterTimeout {
      didRetryAfterFirstFrameTimeout = false
      didRetryAfterStreamStall = false
      didRetryAfterInternalStartError = false
      activeVideoCodec = .raw
    }

    transition(to: .connecting, reason: reason)
    resetFrameState()

    if let configurationError = validateMWDATConfiguration() {
      fail(configurationError, reason: "invalid MWDAT configuration")
      return
    }

    do {
      let permission = Permission.camera
      let status = try await wearables.checkPermissionStatus(permission)
      let granted: Bool
      if status == .granted {
        granted = true
      } else {
        granted = try await wearables.requestPermission(permission) == .granted
      }

      guard granted else {
        fail("Camera permission denied.", reason: "permission denied")
        return
      }

      try await buildAndStartSession(generation: generation, codec: activeVideoCodec)
    } catch {
      fail("Permission error: \(error.localizedDescription)", reason: "permission error")
    }
  }

  private func validateMWDATConfiguration() -> String? {
    guard let config = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any] else {
      return "Meta camera configuration is missing from Info.plist."
    }

    let clientToken = configurationValue(config["ClientToken"])
    if clientToken.isEmpty || clientToken.contains("$(") || clientToken.localizedCaseInsensitiveContains("replace_with") {
      return "Meta CLIENT_TOKEN is missing. Add the rotated token to watersheep app/Config/Secrets.xcconfig, then rebuild the app."
    }

    let appID = configurationValue(config["MetaAppID"])
    if appID.isEmpty || appID.contains("$(") {
      return "Meta app id is missing from the build settings."
    }

    let teamID = configurationValue(config["TeamID"])
    if teamID.isEmpty || teamID.contains("$(") {
      return "Apple development team id is missing from the build settings."
    }

    return nil
  }

  private func configurationValue(_ value: Any?) -> String {
    guard let string = value as? String else {
      return ""
    }
    return string.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func buildAndStartSession(generation: Int, codec: VideoCodec) async throws {
    await releaseSessionReferences(stopSessionFirst: false, reason: "build start")
    activeVideoCodec = codec
    activeCodec = codecName(codec)

    let config = StreamSessionConfig(
      videoCodec: codec,
      resolution: StreamingResolution.medium,
      frameRate: 24
    )
    let session = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
    streamSession = session
    installListeners(for: session, generation: generation)

    log("DAT stream start requested: generation=\(generation), codec=\(codecName(codec))")
    await session.start()
    guard startGeneration == generation, streamSession === session else { return }
    updateStatusFromState(session.state)
    guard session.state != .stopped && session.state != .stopping else { return }
    scheduleFirstFrameWatchdog(generation: generation)
    startFrameRateMonitor()
  }

  private func performStop(reason: String, finalState: StreamLifecycleState) async {
    transition(to: .stopping, reason: reason)
    await releaseSessionReferences(stopSessionFirst: true, reason: reason)
    resetFrameState()
    transition(to: finalState, reason: "stop complete: \(reason)")
  }

  private func releaseSessionReferences(stopSessionFirst: Bool, reason: String) async {
    log("releasing DAT session resources: \(reason)")
    firstFrameWatchdogTask?.cancel()
    firstFrameWatchdogTask = nil
    frameRateTask?.cancel()
    frameRateTask = nil

    if stopSessionFirst, let streamSession {
      await streamSession.stop()
    }

    await stateListenerToken?.cancel()
    await videoFrameListenerToken?.cancel()
    await errorListenerToken?.cancel()
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    streamSession = nil
  }

  private func installListeners(for session: StreamSession, generation: Int) {
    stateListenerToken = session.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self, self.startGeneration == generation else { return }
        self.updateStatusFromState(state)
      }
    }

    videoFrameListenerToken = session.videoFramePublisher.listen { [weak self] videoFrame in
      guard let image = videoFrame.makeUIImage() else {
        Task { @MainActor [weak self] in
          guard let self, self.startGeneration == generation else { return }
          self.rawFrameCallbackCount += 1
          self.decodeFailureCount += 1
          if !self.hasReceivedFirstFrame {
            self.statusMessage = "Receiving DAT frames, but the preview decoder has not produced an image yet."
          }
          if self.decodeFailureCount == 1 || self.decodeFailureCount % 30 == 0 {
            self.log("DAT frame callback received but makeUIImage failed: decodeFailures=\(self.decodeFailureCount)")
          }
        }
        return
      }

      Task { @MainActor [weak self] in
        guard let self, self.startGeneration == generation else { return }
        self.rawFrameCallbackCount += 1
        self.handleDecodedFrame(image)
      }
    }

    errorListenerToken = session.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self, self.startGeneration == generation else { return }
        let message = self.formatStreamingError(error)
        self.log("DAT stream error: \(message)")
        if await self.retryAfterInternalStartErrorIfNeeded(error, generation: generation) {
          return
        }
        self.showError(message)
        await self.failAndTearDown(message, reason: "DAT error")
      }
    }
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      if streamState != .stopping && streamState != .idle {
        transition(to: .idle, reason: "DAT state stopped")
      }
    case .waitingForDevice:
      streamingStatus = .waiting
      statusMessage = "Waiting for glasses to become active."
      log("DAT state waitingForDevice")
    case .starting:
      transition(to: .connecting, reason: "DAT state starting")
    case .stopping:
      transition(to: .stopping, reason: "DAT state stopping")
    case .paused:
      streamingStatus = .waiting
      statusMessage = "Stream is paused by the device."
      log("DAT state paused")
    case .streaming:
      if hasReceivedFirstFrame {
        transition(to: .streaming, reason: "DAT state streaming with frames")
      } else {
        streamingStatus = .waiting
        statusMessage = didRetryAfterFirstFrameTimeout
          ? "Retrying HEVC stream. DAT is connected, waiting for the first frame."
          : "Connected to DAT stream. Waiting for the first frame."
        log("DAT state streaming but no frames yet")
      }
    }
  }

  private func handleDecodedFrame(_ image: UIImage) {
    lastFrameReceivedAt = Date()
    frameCount += 1

    if !hasReceivedFirstFrame {
      hasReceivedFirstFrame = true
      currentVideoFrame = image
      lastPreviewFramePublishedAt = CACurrentMediaTime()
      firstFrameWatchdogTask?.cancel()
      firstFrameWatchdogTask = nil
      transition(to: .streaming, reason: "first frame received")
      log("first frame received")
      return
    }

    let now = CACurrentMediaTime()
    if now - lastPreviewFramePublishedAt >= Constants.previewFramePublishInterval {
      currentVideoFrame = image
      lastPreviewFramePublishedAt = now
    }
  }

  private func scheduleFirstFrameWatchdog(generation: Int) {
    firstFrameWatchdogTask?.cancel()
    firstFrameWatchdogTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Constants.firstFrameTimeoutSeconds))
      guard let self else { return }
      await self.handleFirstFrameTimeoutIfNeeded(generation: generation)
    }
  }

  private func handleFirstFrameTimeoutIfNeeded(generation: Int) async {
    guard startGeneration == generation else { return }
    guard !isRecoveringStream else { return }
    guard !hasReceivedFirstFrame else { return }
    guard streamState == .connecting || streamState == .streaming else { return }

    log("first frame timeout: generation=\(generation), frameCount=\(frameCount)")
    if !didRetryAfterFirstFrameTimeout {
      didRetryAfterFirstFrameTimeout = true
      activeVideoCodec = .hvc1
      statusMessage = "No frames received after DAT connected. Retrying once with HEVC streaming..."
      transition(to: .connecting, reason: "first frame timeout retry")
      let nextGeneration = startGeneration + 1
      startGeneration = nextGeneration
      isRecoveringStream = true
      await releaseSessionReferences(stopSessionFirst: true, reason: "first frame timeout retry")
      resetFrameState()
      do {
        try await buildAndStartSession(generation: nextGeneration, codec: activeVideoCodec)
      } catch {
        await failAndTearDown("Device session error: \(error.localizedDescription)", reason: "device session retry error")
      }
      isRecoveringStream = false
      return
    }

    statusMessage = "DAT is connected but no frames have arrived yet. Keep the glasses awake with hinges open; power-cycle them if this stays stuck."
    log("first frame still pending after codec retry: generation=\(generation), callbacks=\(rawFrameCallbackCount), decodeFailures=\(decodeFailureCount)")
  }

  private func failAndTearDown(_ message: String, reason: String) async {
    transition(to: .stopping, reason: "failure teardown: \(reason)")
    await releaseSessionReferences(stopSessionFirst: true, reason: reason)
    resetFrameState()
    fail(actionableFailureMessage(for: message), reason: reason)
  }

  private func retryAfterInternalStartErrorIfNeeded(_ error: StreamSessionError, generation: Int) async -> Bool {
    guard case .internalError = error else { return false }
    guard startGeneration == generation else { return false }
    guard !isRecoveringStream else { return true }
    guard !didRetryAfterInternalStartError else { return false }
    guard activeVideoCodec == .raw else { return false }
    guard !hasReceivedFirstFrame && rawFrameCallbackCount == 0 else { return false }

    didRetryAfterInternalStartError = true
    activeVideoCodec = .hvc1
    statusMessage = "Glasses rejected the raw camera stream. Retrying once with HEVC..."
    transition(to: .connecting, reason: "internal start error retry")
    let nextGeneration = startGeneration + 1
    startGeneration = nextGeneration
    isRecoveringStream = true
    await releaseSessionReferences(stopSessionFirst: true, reason: "internal start error retry")
    resetFrameState()

    do {
      try await buildAndStartSession(generation: nextGeneration, codec: activeVideoCodec)
    } catch {
      await failAndTearDown("Device session error: \(error.localizedDescription)", reason: "device session internal error retry")
    }
    isRecoveringStream = false

    return true
  }

  private func resetFrameState() {
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    lastFrameReceivedAt = nil
    frameCount = 0
    frameRate = 0
    rawFrameCallbackCount = 0
    decodeFailureCount = 0
    lastFrameRateSampleCount = 0
    lastFrameRateSampleTime = CACurrentMediaTime()
    lastPreviewFramePublishedAt = 0
    consecutiveZeroFrameIntervals = 0
  }

  private func startFrameRateMonitor() {
    frameRateTask?.cancel()
    lastFrameRateSampleCount = frameCount
    lastFrameRateSampleTime = CACurrentMediaTime()
    frameRateTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Constants.frameRateLogInterval))
        await MainActor.run {
          guard let self else { return }
          let now = CACurrentMediaTime()
          let elapsed = max(now - self.lastFrameRateSampleTime, 0.001)
          let delivered = self.frameCount - self.lastFrameRateSampleCount
          self.frameRate = Double(delivered) / elapsed
          self.updateStreamStallState(deliveredFrames: delivered)
          self.lastFrameRateSampleCount = self.frameCount
          self.lastFrameRateSampleTime = now
          self.log("recv fps: \(String(format: "%.1f", self.frameRate)), decoded frames: \(self.frameCount), callbacks: \(self.rawFrameCallbackCount), decode failures: \(self.decodeFailureCount)")
        }
      }
    }
  }

  private func updateStreamStallState(deliveredFrames: Int) {
    guard hasReceivedFirstFrame else {
      consecutiveZeroFrameIntervals = 0
      return
    }

    if deliveredFrames > 0 {
      if consecutiveZeroFrameIntervals >= Constants.stalledFrameIntervalsBeforeRecovery {
        log("stream recovered after stall: deliveredFrames=\(deliveredFrames)")
      }
      consecutiveZeroFrameIntervals = 0
      return
    }

    guard streamState == .streaming else { return }

    consecutiveZeroFrameIntervals += 1
    if consecutiveZeroFrameIntervals == 1 {
      statusMessage = "Connected to DAT stream, waiting for fresh camera frames..."
    }

    guard consecutiveZeroFrameIntervals >= Constants.stalledFrameIntervalsBeforeRecovery else { return }
    consecutiveZeroFrameIntervals = 0

    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.handleStreamingStallIfNeeded()
    }
  }

  private func handleStreamingStallIfNeeded() async {
    guard hasReceivedFirstFrame else { return }
    guard streamState == .streaming else { return }

    log("stream stall detected: frameCount=\(frameCount), callbacks=\(rawFrameCallbackCount)")

    if !didRetryAfterStreamStall {
      didRetryAfterStreamStall = true
      transition(to: .connecting, reason: "stream stall recovery")
      statusMessage = "Camera frames paused unexpectedly. Restarting the DAT stream..."
      let nextGeneration = startGeneration + 1
      startGeneration = nextGeneration
      await releaseSessionReferences(stopSessionFirst: true, reason: "stream stall recovery")
      resetFrameState()
      do {
        try await buildAndStartSession(generation: nextGeneration, codec: activeVideoCodec)
      } catch {
        await failAndTearDown("Device session error: \(error.localizedDescription)", reason: "device session stall recovery error")
      }
      return
    }

    await failAndTearDown(
      "Camera frames stopped arriving after the stream started. Restart the camera, and if it happens again power-cycle the glasses.",
      reason: "stream stall after retry"
    )
  }

  private func transition(to newState: StreamLifecycleState, reason: String) {
    let previousTitle = streamState.title
    streamState = newState

    switch newState {
    case .idle:
      streamingStatus = .stopped
      statusMessage = "Camera stream is idle."
    case .connecting:
      streamingStatus = .waiting
      if statusMessage.isEmpty || !statusMessage.lowercased().contains("retry") {
        statusMessage = "Connecting to glasses stream..."
      }
    case .streaming:
      streamingStatus = .streaming
      statusMessage = hasReceivedFirstFrame ? "Streaming live preview." : "Connected. Waiting for camera frames."
    case .stopping:
      streamingStatus = .waiting
      statusMessage = "Stopping camera stream..."
    case .failed(let message):
      streamingStatus = .stopped
      statusMessage = message
    }

    log("state \(previousTitle) -> \(newState.title): \(reason)")
  }

  private func fail(_ message: String, reason: String) {
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    frameRate = 0
    showError(message)
    transition(to: .failed(message), reason: reason)
  }

  private func actionableFailureMessage(for message: String) -> String {
    guard message == "An internal error occurred. Please try again." else {
      return message
    }

    if rawFrameCallbackCount == 0, decodeFailureCount == 0, !hasReceivedFirstFrame {
      return "The glasses connected, but camera streaming was rejected before the first frame. Open the hinges, keep the glasses awake, disconnect any other app using the Meta camera, then reconnect the glasses and try again."
    }

    return message
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  private func formatStreamingError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound(let deviceIdentifier):
      return "Device \(deviceIdentifier) was not found. Please ensure your glasses are connected."
    case .deviceNotConnected(let deviceIdentifier):
      return "Device \(deviceIdentifier) is not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    case .thermalCritical:
      return "Device is overheating. Streaming has been paused to protect the device."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }

  private func log(_ message: String) {
    print("[StreamSession] \(message)")
  }

  private func codecName(_ codec: VideoCodec) -> String {
    switch codec {
    case .raw:
      return "raw"
    case .hvc1:
      return "hvc1"
    @unknown default:
      return "unknown"
    }
  }
}
