//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import Combine
import EmbeddedElementCall
import SFSafeSymbols
import SwiftUI
import WebKit

struct CallScreen: View {
    @ObservedObject var context: CallScreenViewModel.Context

    var body: some View {
        ElementNavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.compound.bgCanvasDefault.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar { toolbar }
        }
        .alert(item: $context.alertInfo)
    }

    @ViewBuilder
    var content: some View {
        if context.viewState.url == nil {
            ProgressView()
        } else {
            CallView(url: context.viewState.url, viewModelContext: context)
                // This URL is stable, forces view reloads if this representable is ever reused for another url
                .id(context.viewState.url)
                .ignoresSafeArea()
        }
    }

    var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { context.send(viewAction: .navigateBack) } label: {
                Image(systemSymbol: .chevronBackward)
                    .fontWeight(.semibold)
            }
        }
    }
}

private struct CallView: UIViewRepresentable {
    /// The top-level view this representable displays. It wraps the web view when picture in picture isn't running.
    typealias WebViewWrapper = UIView

    let url: URL?
    let viewModelContext: CallScreenViewModel.Context

    func makeUIView(context: Context) -> WebViewWrapper {
        context.coordinator.webViewWrapper
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModelContext: viewModelContext)
    }

    func updateUIView(_ callWebView: WebViewWrapper, context: Context) {
        if let url {
            context.coordinator.load(url)
        }
    }

    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, AVPictureInPictureControllerDelegate {
        private weak var viewModelContext: CallScreenViewModel.Context?

        private var webView: WKWebView!
        private var pictureInPictureController: AVPictureInPictureController?
        private let pictureInPictureViewController: AVPictureInPictureVideoCallViewController
        private var routePickerView: AVRoutePickerView!

        /// The view to be shown in the app. This will contain the web view when picture in picture isn't running.
        let webViewWrapper = WebViewWrapper(frame: .zero)

        private var url: URL!

        init(viewModelContext: CallScreenViewModel.Context) {
            self.viewModelContext = viewModelContext
            pictureInPictureViewController = AVPictureInPictureVideoCallViewController()
            pictureInPictureViewController.preferredContentSize = PiPSize.portrait.size

            super.init()

            DispatchQueue.main.async { // Avoid `Publishing changes from within view update` warnings
                viewModelContext.javaScriptEvaluator = self.evaluateJavaScript
                viewModelContext.requestPictureInPictureHandler = self.requestPictureInPicture
            }

            let configuration = WKWebViewConfiguration()

            let userContentController = WKUserContentController()
            CallScreenJavaScriptMessageName.allCases.forEach {
                userContentController.add(WKScriptMessageHandlerWrapper(self), name: $0.rawValue)
            }

            // Required to allow a webview that uses file URL to load its own assets
            configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            configuration.userContentController = userContentController
            configuration.allowsInlineMediaPlayback = true
            configuration.allowsPictureInPictureMediaPlayback = true

            if let script = viewModelContext.viewState.script {
                let userScript = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
                configuration.userContentController.addUserScript(userScript)
            }

            let silentCallUserScript = WKUserScript(source: Self.silentCallUIScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            configuration.userContentController.addUserScript(silentCallUserScript)

            webView = WKWebView(frame: .zero, configuration: configuration)
            webView.uiDelegate = self
            webView.navigationDelegate = self
            webView.isInspectable = true
            webView.scrollView.contentInsetAdjustmentBehavior = .never // Let Element Call manage the safe areas within the web view.

            webView.customUserAgent = UserAgentBuilder.makeASCIIUserAgent()

            // https://stackoverflow.com/a/77963877/730924
            webView.allowsLinkPreview = true

            // Try matching Element Call colors
            webView.isOpaque = false
            webView.backgroundColor = .compound.bgCanvasDefault
            webView.scrollView.backgroundColor = .compound.bgCanvasDefault

            // This button is always hidden and is only used to be programmaticaly tapped
            routePickerView = AVRoutePickerView(frame: .zero)
            routePickerView.isHidden = true
            routePickerView.isUserInteractionEnabled = false
            webView.addSubview(routePickerView)

            webViewWrapper.addMatchedSubview(webView)

            if AVPictureInPictureController.isPictureInPictureSupported() {
                let pictureInPictureController = AVPictureInPictureController(contentSource: .init(activeVideoCallSourceView: webViewWrapper,
                                                                                                   contentViewController: pictureInPictureViewController))
                pictureInPictureController.delegate = self
                self.pictureInPictureController = pictureInPictureController
                viewModelContext.send(viewAction: .pictureInPictureIsAvailable(pictureInPictureController))
            }
        }

        func load(_ url: URL) {
            self.url = url
            // The only file URL we allow is the one coming from our own local ElementCall bundle, so it's okay to allow read permission only to our local EC bundle
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: EmbeddedElementCall.bundle.bundleURL)
            } else {
                let request = URLRequest(url: url)
                webView.load(request)
            }
        }

        func evaluateJavaScript(_ script: String) async throws -> Any? {
            // After testing different scenarios it seems that when using async/await version of these
            // methods wkwebView expects JavaScript to return with a value (something other than Void),
            // if there is no value returning from the JavaScript that you evaluate you will have a crash.
            try await withCheckedThrowingContinuation { [weak self] continuaton in
                self?.webView.evaluateJavaScript(script) { result, error in
                    if let error {
                        continuaton.resume(throwing: error)
                    } else {
                        // The completion is called on the main thread which the continuation
                        // also resumes on, so the result never actually crosses threads.
                        nonisolated(unsafe) let result = result
                        continuaton.resume(returning: result)
                    }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let handlerID = CallScreenJavaScriptMessageName(rawValue: message.name) else {
                return
            }

            switch handlerID {
            case .widgetAction:
                guard let message = message.body as? String else { return }
                viewModelContext?.send(viewAction: .widgetAction(message: message))
            case .showNativeOutputDevicePicker:
                DispatchQueue.main.async {
                    self.tapRoutePickerView()
                }
            case .onOutputDeviceSelect:
                guard let deviceID = message.body as? String else { return }
                viewModelContext?.send(viewAction: .outputDeviceSelected(deviceID: deviceID))
            case .onBackButtonPressed:
                viewModelContext?.send(viewAction: .navigateBack)
            case .onPipMediaOrientationUpdate:
                guard let orientation = message.body as? String else { return }
                switch orientation {
                case "portrait":
                    pictureInPictureViewController.preferredContentSize = PiPSize.portrait.size
                case "landscape":
                    pictureInPictureViewController.preferredContentSize = PiPSize.landscape.size
                default:
                    break
                }
            case .forwardLogs:
                guard let body = message.body as? [String: String],
                      let level = body["level"],
                      let logMessage = body["message"] else { return }

                switch level {
                case "log", "debug":
                    MXLog.debug("[SilentCall]: \(logMessage)")
                case "info":
                    MXLog.info("[SilentCall]: \(logMessage)")
                case "warn":
                    MXLog.warning("[SilentCall]: \(logMessage)")
                case "error":
                    MXLog.error("[SilentCall]: \(logMessage)")
                default:
                    break
                }
            }
        }

        /// This function is called by the webview output routing button
        /// it allows to open the OS output selector using the hidden button.
        private func tapRoutePickerView() {
            guard let button = routePickerView.subviews.first(where: { $0 is UIButton }) as? UIButton else {
                return
            }

            button.sendActions(for: .touchUpInside)
        }

        // MARK: - WKUIDelegate

        func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
            // Allow if the origin is local, otherwise don't allow permissions for domains different than what the call was started on
            guard origin.protocol == "file" || origin.host == url.host else {
                return .deny
            }

            viewModelContext?.send(viewAction: .mediaCapturePermissionGranted)
            return .grant
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let navigationURL = navigationAction.request.url {
                // Do not allow navigation to a different URL scheme.
                if navigationURL.scheme != url.scheme {
                    return .cancel
                }

                // Allow any content from the main URL.
                if navigationURL.host == url.host {
                    return .allow
                }
            }

            // Additionally allow any embedded content such as captchas.
            if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
                return .allow
            }

            // Otherwise the request is invalid.
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(Self.silentCallUIScript, completionHandler: nil)
            viewModelContext?.send(viewAction: .urlChanged(webView.url))
        }

        // MARK: - Picture in Picture

        func requestPictureInPicture() async -> Result<Void, CallScreenError> {
            guard let pictureInPictureController,
                  pictureInPictureController.isPictureInPicturePossible,
                  case .success(true) = await webViewCanEnterPictureInPicture() else {
                return .failure(.pictureInPictureNotAvailable)
            }

            pictureInPictureController.startPictureInPicture()
            return .success(())
        }

        func stopPictureInPicture() {
            pictureInPictureController?.stopPictureInPicture()
        }

        nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { @MainActor in
                // We move the view via the delegate so it works when you background the app without calling requestPictureInPicture
                pictureInPictureViewController.view.addMatchedSubview(webView)
                _ = try? await evaluateJavaScript("controls.enablePip()")
            }
        }

        nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { @MainActor in
                // Double check that the controller is definitely showing a page that supports picture in picture.
                // This is necessary as it doesn't get checked when backgrounding the app or tapping a notification.
                guard case .success(true) = await webViewCanEnterPictureInPicture() else {
                    MXLog.error("Picture in picture started on a webpage that doesn't support it. Ending the call.")
                    viewModelContext?.send(viewAction: .endCall)
                    return
                }
            }
        }

        nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { await viewModelContext?.send(viewAction: .pictureInPictureWillStop) }
        }

        nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { @MainActor in
                webViewWrapper.addMatchedSubview(webView)
                _ = try? await evaluateJavaScript("controls.disablePip()")
            }
        }

        /// Whether the web view can do picture in picture or not (e.g. it is showing an error or the page didn't load).
        private func webViewCanEnterPictureInPicture() async -> Result<Bool, CallScreenError> {
            do {
                guard let canEnterPictureInPicture = try await evaluateJavaScript("controls.canEnterPip()") as? Bool else {
                    MXLog.error("canEnterPip returned an unexpected value, skipping picture in picture.")
                    return .failure(.pictureInPictureNotAvailable)
                }
                MXLog.info("canEnterPip returned \(canEnterPictureInPicture)")
                return .success(canEnterPictureInPicture)
            } catch {
                MXLog.error("Error checking canEnterPip: \(error)")
                return .failure(.pictureInPictureNotAvailable)
            }
        }

        private static let silentCallUIScript = #"""
        (function() {
            const css = `
            html,
            body,
            #root {
              background: #062a3a !important;
            }

            body {
              color-scheme: dark !important;
            }

            .inRoom {
              position: relative !important;
              background:
                linear-gradient(180deg, rgba(25, 25, 25, 0.96) 0, rgba(25, 25, 25, 0.96) 88px, rgba(25, 25, 25, 0) 122px),
                linear-gradient(180deg, #a8adb6 0%, #587f9d 36%, #00607d 100%) !important;
              overflow: hidden !important;
            }

            .silent-encryption-stream {
              position: fixed !important;
              left: 50% !important;
              top: 61% !important;
              width: 100% !important;
              z-index: 5 !important;
              display: none !important;
              flex-direction: column !important;
              align-items: center !important;
              gap: 4px !important;
              pointer-events: none !important;
              opacity: 0.48 !important;
              transform: translate(-50%, -50%) !important;
              overflow: hidden !important;
              color: rgba(21, 85, 224, 0.72) !important;
              font: 600 11px/1.15 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace !important;
              letter-spacing: 0 !important;
              white-space: nowrap !important;
              text-shadow:
                0 0 8px rgba(255, 255, 255, 0.7),
                0 1px 2px rgba(6, 42, 58, 0.28) !important;
            }

            .silent-call-connected .silent-encryption-stream {
              display: flex !important;
            }

            .silent-encryption-stream span {
              display: block !important;
              width: 100% !important;
              text-align: center !important;
              animation: silentEncryptionWave 8s ease-in-out infinite alternate !important;
            }

            .silent-encryption-stream span:nth-child(2) {
              animation-duration: 11s !important;
              animation-delay: -2s !important;
              opacity: 0.72 !important;
            }

            .silent-encryption-stream span:nth-child(3) {
              animation-duration: 10s !important;
              animation-delay: -4s !important;
              opacity: 0.82 !important;
            }

            @keyframes silentEncryptionWave {
              0% {
                transform: translateX(-2%) translateY(0);
                filter: blur(0.6px);
                opacity: 0.36;
              }
              42% {
                transform: translateX(2%) translateY(-3px);
                filter: blur(0);
                opacity: 0.78;
              }
              100% {
                transform: translateX(-1%) translateY(3px);
                filter: blur(1px);
                opacity: 0.42;
              }
            }

            .header {
              min-height: calc(env(safe-area-inset-top) + 82px) !important;
              padding: calc(env(safe-area-inset-top) + 8px) 58px 8px !important;
              background: rgba(25, 25, 25, 0.96) !important;
              box-shadow: 0 10px 18px rgba(0, 0, 0, 0.24) !important;
            }

            .header .leftNav,
            .header .rightNav {
              height: auto !important;
              margin: 0 !important;
              justify-content: center !important;
            }

            .header .rightNav {
              position: absolute !important;
              right: 12px !important;
              bottom: 12px !important;
              width: 32px !important;
              height: 32px !important;
              border-radius: 999px !important;
              background: rgba(255, 255, 255, 0.16) !important;
              box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.24) !important;
            }

            .roomHeaderInfo {
              display: flex !important;
              flex-direction: column !important;
              align-items: center !important;
              justify-content: center !important;
              gap: 4px !important;
              width: 100% !important;
              min-width: 0 !important;
            }

            .roomHeaderInfo::before {
              content: attr(data-silent-call-status);
              color: rgba(255, 255, 255, 0.82);
              font: 400 14px/18px system-ui, sans-serif;
            }

            .roomAvatar,
            .participantsLine,
            .nameLine > svg {
              display: none !important;
            }

            .nameLine {
              display: flex !important;
              justify-content: center !important;
              width: 100% !important;
              min-width: 0 !important;
            }

            [data-testid="roomHeader_roomName"] {
              color: #fff !important;
              font: 400 17px/22px system-ui, sans-serif !important;
              max-width: 100% !important;
              text-align: center !important;
              white-space: nowrap !important;
              overflow: hidden !important;
              text-overflow: ellipsis !important;
            }

            .fixedGrid,
            .scrollingGrid {
              inset-inline: 0 !important;
            }

            [data-testid="footer-container"] {
              position: fixed !important;
              left: 0 !important;
              right: 0 !important;
              bottom: 0 !important;
              z-index: 100000 !important;
              display: flex !important;
              justify-content: center !important;
              align-items: center !important;
              min-height: calc(env(safe-area-inset-bottom) + 74px) !important;
              padding: 12px 16px calc(env(safe-area-inset-bottom) + 10px) !important;
              border-radius: 6px 6px 0 0 !important;
              background: linear-gradient(180deg, #1555e0 0%, #0d3fb4 100%) !important;
              box-shadow: 0 -10px 24px rgba(21, 85, 224, 0.34) !important;
            }

            [data-testid="footer-container"] .settingsLogoContainer,
            [data-testid="footer-container"] .layout,
            [data-testid="footer-container"] fieldset,
            [data-testid="footer-container"] .logo,
            [data-testid="incall_screenshare"],
            [data-testid="footer-container"] .shareScreen,
            [data-testid="footer-container"] .raiseHand {
              display: none !important;
            }

            [data-testid="footer-container"] .buttons {
              display: flex !important;
              align-items: center !important;
              justify-content: space-between !important;
              gap: 18px !important;
              width: min(100%, 360px) !important;
            }

            [data-testid="footer-container"] button {
              width: 44px !important;
              height: 44px !important;
              min-width: 44px !important;
              min-height: 44px !important;
              border-radius: 999px !important;
              padding: 0 !important;
              color: #fff !important;
              background: rgba(30, 30, 30, 0.24) !important;
              box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.26) !important;
            }

            [data-testid="footer-container"] button svg {
              width: 24px !important;
              height: 24px !important;
            }

            [data-testid="footer-container"] button[data-kind="primary"] {
              background: rgba(30, 30, 30, 0.28) !important;
            }

            [data-testid="incall_leave"] {
              background: rgba(30, 30, 30, 0.24) !important;
              box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.26) !important;
            }

            [data-testid="incall_leave"] svg,
            [data-testid="incall_leave"] svg * {
              color: #ff2f4f !important;
              fill: #ff2f4f !important;
              stroke: #ff2f4f !important;
            }

            @media (max-width: 360px) {
              [data-testid="footer-container"] .buttons {
                gap: 12px !important;
              }

              [data-testid="footer-container"] button {
                width: 42px !important;
                height: 42px !important;
                min-width: 42px !important;
                min-height: 42px !important;
              }
            }
            `;

            const streamHtml = `
            <span>#10&#36;&amp;0U0101A?! 11111E&#36;1U100111 0 @UE11 0101#</span>
            <span>%C EEU1!%0!? *&#36;C&#36;A 1 0000&#36;!1!A#10*#?!U0&#36;</span>
            <span>0111%:*!1%A&amp;E# 1#0L^#11#:C1?0:0 0@0*?0U0 &#36;10</span>
            `;

            const apply = function() {
                try {
                    if (!document.head || !document.body) return true;
                    let style = document.getElementById('silent-call-ui');
                    if (!style) {
                        style = document.createElement('style');
                        style.id = 'silent-call-ui';
                        document.head.appendChild(style);
                    }
                    if (style.textContent !== css) {
                        style.textContent = css;
                    }

                    const callRoot = document.querySelector('.inRoom') || document.body;
                    const mediaConnected = Array.from(document.querySelectorAll('video, audio')).some(function(media) {
                        return media.srcObject || media.readyState >= 2;
                    });
                    const pageText = (document.body && document.body.innerText || '').toLowerCase();
                    const hasFooterControls = Boolean(document.querySelector('[data-testid="footer-container"] button'));
                    const looksPending = /\b(connecting|waiting|ringing|calling|invite|invited|accept)\b|join call|join now/.test(pageText);
                    const callConnected = mediaConnected || (hasFooterControls && !looksPending);

                    document.documentElement.classList.toggle('silent-call-connected', callConnected);
                    document.body.classList.toggle('silent-call-connected', callConnected);

                    let stream = document.getElementById('silent-encryption-stream');
                    if (callConnected) {
                        if (!stream) {
                            stream = document.createElement('div');
                            stream.id = 'silent-encryption-stream';
                            stream.className = 'silent-encryption-stream';
                            stream.setAttribute('aria-hidden', 'true');
                            stream.innerHTML = streamHtml;
                        }
                        if (stream.parentElement !== callRoot) {
                            callRoot.appendChild(stream);
                        }
                    } else if (stream) {
                        stream.remove();
                    }

                    const headerInfo = document.querySelector('.roomHeaderInfo');
                    if (headerInfo) {
                        const status = callConnected ? 'Connected' : /\b(waiting|invite|invited)\b|join call|join now/.test(pageText) ? 'Waiting...' : 'Connecting...';
                        headerInfo.setAttribute('data-silent-call-status', status);
                    }
                    document.documentElement.classList.add('silent-call-ui');
                    document.body.classList.add('silent-call-ui-body');
                    return true;
                } catch (error) {
                    console.warn('Silent call UI skipped', error);
                    return false;
                }
            };

            apply();
            if (!window.__silentCallUiStatusTimer) {
                window.__silentCallUiStatusTimer = setInterval(apply, 1000);
            }
            setTimeout(apply, 250);
            setTimeout(apply, 1000);
            return true;
        })();
        """#
    }

    /// Avoids retain loops between the configuration and webView coordinator
    private class WKScriptMessageHandlerWrapper: NSObject, WKScriptMessageHandler {
        private weak var coordinator: Coordinator?

        init(_ coordinator: Coordinator) {
            self.coordinator = coordinator
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            coordinator?.userContentController(userContentController, didReceive: message)
        }
    }

    private enum PiPSize {
        case portrait
        case landscape

        var size: CGSize {
            switch self {
            case .portrait:
                .init(width: 1080, height: 1920)
            case .landscape:
                .init(width: 1920, height: 1080)
            }
        }

    }
}

// MARK: - Previews

struct CallScreen_Previews: PreviewProvider {
    static let viewModel = makeViewModel()

    static var previews: some View {
        CallScreen(context: viewModel.context)
    }

    static func makeViewModel() -> CallScreenViewModel {
        let clientProxy = ClientProxyMock()
        clientProxy.deviceID = "call-device-id"

        let roomProxy = JoinedRoomProxyMock()

        let widgetDriver = ElementCallWidgetDriverMock()
        widgetDriver.messagePublisher = .init()
        widgetDriver.actions = PassthroughSubject<ElementCallWidgetDriverAction, Never>().eraseToAnyPublisher()
        widgetDriver.startBaseURLClientIDColorSchemeVoiceOnlyRageshakeURLAnalyticsConfigurationReturnValue = .success(URL.userDirectory)

        roomProxy.elementCallWidgetDriverDeviceIDReturnValue = widgetDriver

        return CallScreenViewModel(elementCallService: ElementCallServiceMock(.init()),
                                   configuration: .init(roomProxy: roomProxy,
                                                        clientProxy: clientProxy,
                                                        clientID: "io.element.elementx",
                                                        elementCallBaseURL: "https://call.element.io",
                                                        elementCallBaseURLOverride: nil,
                                                        voiceOnly: false,
                                                        colorScheme: .light),
                                   allowPictureInPicture: false,
                                   appSettings: .volatile(),
                                   analyticsService: AnalyticsServiceMock(.init()))
    }
}
