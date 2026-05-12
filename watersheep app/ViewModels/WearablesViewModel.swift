/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Combine
import CoreBluetooth
import MWDATCore
import SwiftUI

@MainActor
final class WearablesViewModel: NSObject, ObservableObject, CBCentralManagerDelegate {
  @Published var devices: [DeviceIdentifier]
  @Published var registrationState: RegistrationState
  @Published var showGettingStartedSheet: Bool = false
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published private(set) var deviceSummary = "No devices"
  @Published private(set) var sessionSummary = "No device session"
  @Published private(set) var bluetoothStateSummary = "Checking Bluetooth"
  @Published private(set) var bluetoothPermissionSummary = "Checking permission"
  @Published private(set) var isBluetoothPoweredOn = false

  private var registrationTask: Task<Void, Never>?
  private var deviceStreamTask: Task<Void, Never>?
  private var setupDeviceStreamTask: Task<Void, Never>?
  private let wearables: WearablesInterface
  private var bluetoothManager: CBCentralManager?
  private var compatibilityListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var sessionListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var deviceSessionStates: [DeviceIdentifier: SessionState] = [:]

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.devices = wearables.devices
    self.registrationState = wearables.registrationState
    super.init()
    refreshBluetoothPermissionSummary()
    bluetoothManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true])

    setupDeviceStreamTask = Task {
      await setupDeviceStream()
    }

    registrationTask = Task {
      for await registrationState in wearables.registrationStateStream() {
        let previousState = self.registrationState
        self.registrationState = registrationState
        if self.showGettingStartedSheet == false && registrationState == .registered && previousState == .registering {
          self.showGettingStartedSheet = true
        }
      }
    }
  }

  deinit {
    registrationTask?.cancel()
    deviceStreamTask?.cancel()
    setupDeviceStreamTask?.cancel()
  }

  private func setupDeviceStream() async {
    if let task = deviceStreamTask, !task.isCancelled {
      task.cancel()
    }

    deviceStreamTask = Task {
      for await devices in wearables.devicesStream() {
        self.devices = devices
        monitorDeviceCompatibility(devices: devices)
      }
    }
  }

  private func monitorDeviceCompatibility(devices: [DeviceIdentifier]) {
    let deviceSet = Set(devices)
    compatibilityListenerTokens = compatibilityListenerTokens.filter { deviceSet.contains($0.key) }
    sessionListenerTokens = sessionListenerTokens.filter { deviceSet.contains($0.key) }
    deviceSessionStates = deviceSessionStates.filter { deviceSet.contains($0.key) }

    for deviceId in devices {
      guard let device = wearables.deviceForIdentifier(deviceId) else { continue }

      if compatibilityListenerTokens[deviceId] == nil {
        let deviceName = device.nameOrId()
        let token = device.addCompatibilityListener { [weak self] compatibility in
          guard let self else { return }
          if compatibility == .deviceUpdateRequired {
            Task { @MainActor in
              self.showError("Device '\(deviceName)' requires an update to work with this app")
            }
          }
        }
        compatibilityListenerTokens[deviceId] = token
      }

      if sessionListenerTokens[deviceId] == nil {
        Task { @MainActor [weak self] in
          guard let self else { return }
          let sessionToken = await wearables.addDeviceSessionStateListener(forDeviceId: deviceId) { [weak self] state in
            Task { @MainActor in
              self?.deviceSessionStates[deviceId] = state
              self?.refreshDeviceSummaries()
            }
          }
          self.sessionListenerTokens[deviceId] = sessionToken
        }
      }
    }

    refreshDeviceSummaries()
  }

  private func refreshDeviceSummaries() {
    guard !devices.isEmpty else {
      deviceSummary = "No devices"
      sessionSummary = "No device session"
      return
    }

    let names = devices.compactMap { deviceId -> String? in
      guard let device = wearables.deviceForIdentifier(deviceId) else {
        return "\(deviceId)"
      }
      return "\(device.nameOrId()) [\(linkLabel(device.linkState)), \(device.compatibility().displayString)]"
    }
    deviceSummary = names.joined(separator: ", ")

    let sessions = devices.map { deviceId -> String in
      let name = wearables.deviceForIdentifier(deviceId)?.nameOrId() ?? "\(deviceId)"
      let state = deviceSessionStates[deviceId]?.description ?? "unknown"
      return "\(name): \(state)"
    }
    sessionSummary = sessions.joined(separator: ", ")
  }

  private func linkLabel(_ linkState: LinkState) -> String {
    String(describing: linkState)
  }

  func connectGlasses() {
    guard registrationState != .registering else { return }
    guard ensureBluetoothReadyForRegistration() else { return }
    Task { @MainActor in
      do {
        try await wearables.startRegistration()
      } catch let error as RegistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func disconnectGlasses() {
    Task { @MainActor in
      do {
        try await wearables.startUnregistration()
      } catch let error as UnregistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func showError(_ error: String) {
    errorMessage = error
    showError = true
  }

  func dismissError() {
    showError = false
  }

  private func ensureBluetoothReadyForRegistration() -> Bool {
    refreshBluetoothPermissionSummary()

    if !isBluetoothAuthorized {
      showError("Bluetooth access is not allowed for Watersheep. Open iPhone Settings and allow Bluetooth, then try again.")
      return false
    }

    if !isBluetoothPoweredOn {
      showError("Bluetooth is off or not ready yet. Turn Bluetooth on, wait a moment, then tap Connect Glasses again.")
      return false
    }

    return true
  }

  private var isBluetoothAuthorized: Bool {
    switch CBCentralManager.authorization {
    case .allowedAlways:
      return true
    case .notDetermined, .restricted, .denied:
      return false
    @unknown default:
      return false
    }
  }

  private func refreshBluetoothPermissionSummary() {
    switch CBCentralManager.authorization {
    case .allowedAlways:
      bluetoothPermissionSummary = "Allowed"
    case .notDetermined:
      bluetoothPermissionSummary = "Not determined"
    case .restricted:
      bluetoothPermissionSummary = "Restricted"
    case .denied:
      bluetoothPermissionSummary = "Denied"
    @unknown default:
      bluetoothPermissionSummary = "Unknown"
    }
  }

  private func refreshBluetoothStateSummary(for state: CBManagerState) {
    switch state {
    case .unknown:
      bluetoothStateSummary = "Unknown"
      isBluetoothPoweredOn = false
    case .resetting:
      bluetoothStateSummary = "Resetting"
      isBluetoothPoweredOn = false
    case .unsupported:
      bluetoothStateSummary = "Unsupported"
      isBluetoothPoweredOn = false
    case .unauthorized:
      bluetoothStateSummary = "Unauthorized"
      isBluetoothPoweredOn = false
    case .poweredOff:
      bluetoothStateSummary = "Powered Off"
      isBluetoothPoweredOn = false
    case .poweredOn:
      bluetoothStateSummary = "Powered On"
      isBluetoothPoweredOn = true
    @unknown default:
      bluetoothStateSummary = "Unknown"
      isBluetoothPoweredOn = false
    }
  }

  nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.refreshBluetoothPermissionSummary()
      self.refreshBluetoothStateSummary(for: central.state)
    }
  }
}
