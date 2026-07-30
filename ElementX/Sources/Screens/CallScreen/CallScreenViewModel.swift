//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import CallKit
import Combine
import SwiftUI

typealias CallScreenViewModelType = StateStoreViewModel<CallScreenViewState, CallScreenViewAction>

class CallScreenViewModel: CallScreenViewModelType, CallScreenViewModelProtocol {
    private let elementCallService: ElementCallServiceProtocol
    private let configuration: ElementCallConfiguration
    private let isPictureInPictureAllowed: Bool
    private let appSettings: AppSettings
    private let analyticsService: AnalyticsServiceProtocol
    
    private let widgetDriver: ElementCallWidgetDriverProtocol
    
    private let actionsSubject: PassthroughSubject<CallScreenViewModelAction, Never> = .init()
    var actions: AnyPublisher<CallScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    @CancellableTask
    private var timeoutTask: Task<Void, Never>?
    
    private var audioRouteTasks = [Task<Void, Never>]()
    
    private var prefersEarpieceAudioRoute = true

    private var isManagingCallAudioSession = false
    
    /// Designated initialiser
    /// - Parameters:
    ///   - elementCallService: service responsible for setting up CallKit
    ///   - roomProxy: The room in which the call should be created
    ///   - callBaseURL: Which Element Call instance should be used
    ///   - clientID: Something to identify the current client on the Element Call side
    init(elementCallService: ElementCallServiceProtocol,
         configuration: ElementCallConfiguration,
         allowPictureInPicture: Bool,
         appSettings: AppSettings,
         analyticsService: AnalyticsServiceProtocol) {
        self.elementCallService = elementCallService
        self.configuration = configuration
        self.appSettings = appSettings
        self.analyticsService = analyticsService
        isPictureInPictureAllowed = allowPictureInPicture
        
        guard let deviceID = configuration.clientProxy.deviceID else { fatalError("Missing device ID for the call.") }
        widgetDriver = configuration.roomProxy.elementCallWidgetDriver(deviceID: deviceID)
        
        super.init(initialViewState: CallScreenViewState(script: CallScreenJavaScriptMessageName.allCasesInjectionScript))
        
        elementCallService.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case let .setAudioEnabled(enabled, roomID):
                    guard roomID == configuration.callRoomID else {
                        MXLog.error("Received mute request for a different room: \(roomID) != \(configuration.callRoomID)")
                        return
                    }
                    
                    Task {
                        await self.setAudioEnabled(enabled)
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
        
        widgetDriver.messagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] receivedMessage in
                guard let self else { return }
                
                Task {
                    await self.postJSONToWidget(receivedMessage)
                }
            }
            .store(in: &cancellables)
        
        widgetDriver.actions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                guard let self else { return }
                
                switch action {
                case .callEnded:
                    actionsSubject.send(.dismiss)
                case .mediaStateChanged(let audioEnabled, _):
                    elementCallService.setAudioEnabled(audioEnabled, roomID: configuration.callRoomID)
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in
                guard let self, isManagingCallAudioSession else { return }
                logCurrentAudioRoute(context: "route changed")
                enforcePreferredAudioRoute(after: .milliseconds(350), updateWebOutputs: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: AVAudioSession.interruptionNotification,
                       object: AVAudioSession.sharedInstance())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAudioSessionInterruption(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, isManagingCallAudioSession else { return }
                restoreCallAudioSession(after: .milliseconds(250), updateWebOutputs: true)
            }
            .store(in: &cancellables)
        
        setupCall()
    }
    
    override func process(viewAction: CallScreenViewAction) {
        switch viewAction {
        case .urlChanged(let url):
            guard let url else { return }
            MXLog.info("URL changed to: \(url)")
        case .pictureInPictureIsAvailable(let controller):
            actionsSubject.send(.pictureInPictureIsAvailable(controller))
        case .navigateBack:
            Task { await handleBackwardsNavigation() }
        case .pictureInPictureWillStop:
            actionsSubject.send(.pictureInPictureStopped)
        case .endCall:
            actionsSubject.send(.dismiss)
        case .mediaCapturePermissionGranted:
            guard isManagingCallAudioSession else { return }
            prepareCallAudioSession(reason: "media capture permission granted")
            enforcePreferredAudioRoute(after: .milliseconds(350), updateWebOutputs: true)
        case .outputDeviceSelected(deviceID: let deviceID):
            handleOutputDeviceSelected(deviceID: deviceID)
        case .widgetAction(let message):
            Task { await handleWidgetAction(message: message) }
        }
    }
    
    func stop() {
        isManagingCallAudioSession = false

        Task {
            await hangup()
        }
        
        audioRouteTasks.forEach { $0.cancel() }
        audioRouteTasks.removeAll()
        elementCallService.tearDownCallSession()
        resetCallAudioRoute()
        UIDevice.current.isProximityMonitoringEnabled = false
    }
    
    // MARK: - Private
    
    private func handleWidgetAction(message: String) async {
        if timeoutTask != nil,
           let decodedMessage = try? DecodedWidgetMessage.decode(message: message),
           decodedMessage.hasLoaded {
            // This means that the call room was joined succesfully, we can stop the timeout task
            timeoutTask = nil
        }
        await widgetDriver.handleMessage(message)
    }
    
    private func setupCall() {
        Task { [weak self] in
            guard let self else { return }
            
            let baseURL = if let baseURLOverride = configuration.elementCallBaseURLOverride {
                baseURLOverride
            } else {
                configuration.elementCallBaseURL
            }
            
            // We only set the analytics configuration if analytics are enabled
            let analyticsConfiguration: ElementCallAnalyticsConfiguration? = if analyticsService.isEnabled {
                .init(posthogAPIHost: appSettings.elementCallPosthogAPIHost,
                      posthogAPIKey: appSettings.elementCallPosthogAPIKey,
                      sentryDSN: appSettings.elementCallPosthogSentryDSN)
            } else {
                nil
            }
            let rageshakeURL: String? = if case let .url(baseURL) = appSettings.bugReportRageshakeURL.publisher.value {
                baseURL.absoluteString
            } else {
                nil
            }
            
            switch await widgetDriver.start(baseURL: baseURL,
                                            clientID: configuration.clientID,
                                            colorScheme: configuration.colorScheme,
                                            voiceOnly: configuration.voiceOnly,
                                            rageshakeURL: rageshakeURL,
                                            analyticsConfiguration: analyticsConfiguration) {
            case .success(let url):
                state.url = url
            case .failure(let error):
                MXLog.error("Failed starting ElementCall Widget Driver with error: \(error)")
                state.bindings.alertInfo = .init(id: UUID(),
                                                 title: L10n.errorUnknown,
                                                 primaryButton: .init(title: L10n.actionOk) {
                                                     self.actionsSubject.send(.dismiss)
                                                 })
                return
            }
            
            prefersEarpieceAudioRoute = true
            isManagingCallAudioSession = true
            UIDevice.current.isProximityMonitoringEnabled = true
            prepareCallAudioSession(reason: "call start")
            
            await elementCallService.setupCallSession(roomID: configuration.roomProxy.id,
                                                      roomDisplayName: configuration.roomProxy.infoPublisher.value.displayName ?? configuration.roomProxy.id)
            enforcePreferredAudioRoute(after: .milliseconds(500))
            enforcePreferredAudioRoute(after: .seconds(1))
        }
        
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            MXLog.error("Failed to join Element Call: Timeout")
            state.bindings.alertInfo = .init(id: UUID(),
                                             title: L10n.commonError,
                                             message: L10n.errorUnknown,
                                             primaryButton: .init(title: L10n.actionDismiss) { [weak self] in self?.actionsSubject.send(.dismiss) })
            timeoutTask = nil
        }
    }
    
    /// This should always match the web app value
    private static let earpieceID = "earpiece-id"
    private static let placeholderOutputID = "dummy"
    
    private func handleOutputDeviceSelected(deviceID: String) {
        guard deviceID != Self.placeholderOutputID else {
            MXLog.info("Ignoring placeholder call output device selection")
            return
        }

        let isEarpiece = deviceID == Self.earpieceID || deviceID.localizedCaseInsensitiveContains("earpiece")
        MXLog.info("Selected call output device: \(deviceID). Is earpiece: \(isEarpiece)")
        prefersEarpieceAudioRoute = isEarpiece
        setCallAudioRoute(toEarpiece: isEarpiece, reason: "user selected \(deviceID)")
        enforcePreferredAudioRoute(after: .milliseconds(250))
        enforcePreferredAudioRoute(after: .seconds(1))
        UIDevice.current.isProximityMonitoringEnabled = isEarpiece
    }

    private func prepareCallAudioSession(activate: Bool = false, reason: String) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // Keep the session non-mixable so ringtones and notification sounds don't play
            // over an active Silent call. WebKit normally activates the session after media
            // permission is granted; native code only reactivates it after an interruption.
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try audioSession.setPrefersNoInterruptionsFromSystemAlerts(true)
            if activate {
                try audioSession.setActive(true)
            }
            MXLog.info("Prepared call audio session - \(reason)")
        } catch {
            MXLog.error("Failed preparing call audio session - \(reason): \(error)")
        }
    }
    
    private func setCallAudioRoute(toEarpiece: Bool, reason: String) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.overrideOutputAudioPort(toEarpiece ? .none : .speaker)
            logCurrentAudioRoute(context: "\(toEarpiece ? "receiver route" : "speaker route") - \(reason)")
        } catch {
            MXLog.error("Failed changing call audio route to \(toEarpiece ? "earpiece" : "speaker"): \(error)")
        }
    }
    
    private func enforcePreferredAudioRoute(after delay: Duration, updateWebOutputs: Bool = false) {
        audioRouteTasks.append(Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if isCurrentAudioRouteSpeaker == !prefersEarpieceAudioRoute {
                logCurrentAudioRoute(context: "route already matches preference")
            } else {
                setCallAudioRoute(toEarpiece: prefersEarpieceAudioRoute, reason: "route enforcement")
            }

            if updateWebOutputs {
                await updateOutputsListOnWeb()
            }
        })
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard isManagingCallAudioSession else { return }

        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            MXLog.warning("Received call audio interruption without a valid interruption type")
            return
        }

        switch type {
        case .began:
            let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt
            let reason = reasonValue.flatMap { AVAudioSession.InterruptionReason(rawValue: $0) }
            MXLog.info("Call audio session interruption began. Reason: \(String(describing: reason))")
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            MXLog.info("Call audio session interruption ended. Should resume: \(shouldResume)")

            guard shouldResume else {
                MXLog.warning("Call audio session interruption ended without permission to resume")
                return
            }

            restoreCallAudioSession(after: .milliseconds(100))
            restoreCallAudioSession(after: .milliseconds(600), updateWebOutputs: true)
            restoreCallAudioSession(after: .seconds(2))
        @unknown default:
            MXLog.warning("Received an unknown call audio interruption type")
        }
    }

    private func restoreCallAudioSession(after delay: Duration, updateWebOutputs: Bool = false) {
        audioRouteTasks.append(Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, isManagingCallAudioSession else { return }

            prepareCallAudioSession(activate: true, reason: "interruption recovery")
            setCallAudioRoute(toEarpiece: prefersEarpieceAudioRoute, reason: "interruption recovery")

            if updateWebOutputs {
                await updateOutputsListOnWeb()
            }
        })
    }
    
    private var isCurrentAudioRouteSpeaker: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            output.portType == .builtInSpeaker
        }
    }
    
    private func resetCallAudioRoute() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setPrefersNoInterruptionsFromSystemAlerts(false)
        } catch {
            MXLog.error("Failed resetting system alert interruption preference: \(error)")
        }

        do {
            try audioSession.overrideOutputAudioPort(.none)
            logCurrentAudioRoute(context: "reset")
        } catch {
            MXLog.error("Failed resetting call output route: \(error)")
        }
    }
    
    private func logCurrentAudioRoute(context: String) {
        let audioSession = AVAudioSession.sharedInstance()
        let outputs = audioSession.currentRoute.outputs
            .map { "\($0.portName) (\($0.portType.rawValue), \($0.uid))" }
            .joined(separator: ", ")
        MXLog.info("Call audio route \(context): \(outputs)")
    }
    
    private func handleBackwardsNavigation() async {
        guard state.url != nil,
              isPictureInPictureAllowed,
              let requestPictureInPictureHandler = state.bindings.requestPictureInPictureHandler else {
            actionsSubject.send(.dismiss)
            return
        }
        
        switch await requestPictureInPictureHandler() {
        case .success:
            actionsSubject.send(.pictureInPictureStarted)
        case .failure:
            actionsSubject.send(.dismiss)
        }
    }
    
    private func setAudioEnabled(_ enabled: Bool) async {
        let message = ElementCallWidgetMessage(direction: .toWidget,
                                               action: .mediaState,
                                               data: .init(audioEnabled: enabled),
                                               widgetId: widgetDriver.widgetID)
        await postMessageToWidget(message)
    }
    
    func hangup() async {
        let message = ElementCallWidgetMessage(direction: .fromWidget,
                                               action: .hangup,
                                               widgetId: widgetDriver.widgetID)
        
        await postMessageToWidget(message)
    }
    
    private func postMessageToWidget(_ message: ElementCallWidgetMessage) async {
        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            MXLog.error("Failed encoding widget message with error: \(error)")
            return
        }
        
        guard let json = String(data: data, encoding: .utf8) else {
            MXLog.error("Invalid data for widget message")
            return
        }
        
        await postJSONToWidget(json)
    }
    
    private func postJSONToWidget(_ json: String) async {
        do {
            let message = "postMessage(\(json), '*')"
            let result = try await state.bindings.javaScriptEvaluator?(message)
            MXLog.debug("Evaluated javascript: \(json) with result: \(String(describing: result))")
        } catch {
            MXLog.error("Received javascript evaluation error: \(error)")
        }
    }
    
    /// This function updates the list of available audio outputs on the web side
    /// however since we actually handle switching the audio output through the OS,
    /// this is only used to inform the webview when the speaker is selected,
    /// so that the option to use the earpiece can be displayed.
    private func updateOutputsListOnWeb() async {
        guard let currentOutput = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            return
        }
        
        let deviceList = if currentOutput.portType == .builtInSpeaker {
            // This allows the webview to display the earpiece option
            "{id: '\(currentOutput.uid)', name: '\(currentOutput.portName)', forEarpiece: true, isSpeaker: true}"
        } else {
            // Doesn't matter because the switch is handled through the OS
            "{id: 'dummy', name: 'dummy'}"
        }
        
        let selectEarpiece = if currentOutput.portType == .builtInSpeaker, prefersEarpieceAudioRoute {
            "window.controls.setOutputDevice('\(Self.earpieceID)');"
        } else {
            ""
        }
        let javaScript = "\(selectEarpiece)window.controls.setAvailableOutputDevices([\(deviceList)])"
        do {
            let result = try await state.bindings.javaScriptEvaluator?(javaScript)
            MXLog.debug("Evaluated  with result: \(String(describing: result))")
        } catch {
            MXLog.error("Received javascript evaluation error: \(error)")
        }
    }
}
