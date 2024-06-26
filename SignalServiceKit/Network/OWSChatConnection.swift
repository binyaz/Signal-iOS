//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalCoreKit

public enum OWSChatConnectionType: Int, CaseIterable, CustomDebugStringConvertible {
    case identified = 0
    case unidentified = 1

    public var debugDescription: String {
        switch self {
        case .identified:
            return "[type: identified]"
        case .unidentified:
            return "[type: unidentified]"
        }
    }
}

// MARK: -

public enum OWSChatConnectionState: Int, CustomDebugStringConvertible {
    case closed = 0
    case connecting = 1
    case open = 2

    public var debugDescription: String {
        switch self {
        case .closed:
            return "closed"
        case .connecting:
            return "connecting"
        case .open:
            return "open"
        }
    }
}

// MARK: -

public class OWSChatConnection: NSObject {
    // Track where Dependencies are used throughout this class.
    private struct GlobalDependencies: Dependencies {}

    public static let chatConnectionStateDidChange = Notification.Name("chatConnectionStateDidChange")

    fileprivate let serialQueue: DispatchQueue

    // TODO: Should we use a higher-priority queue?
    fileprivate static let messageProcessingQueue = DispatchQueue(label: "org.signal.chat-connection.message-processing")

    // MARK: -

    private let type: OWSChatConnectionType
    private let appExpiry: AppExpiry
    private let db: DB

    private static let socketReconnectDelaySeconds: TimeInterval = 5

    private var _currentWebSocket = AtomicOptional<WebSocketConnection>(nil, lock: .sharedGlobal)
    private var currentWebSocket: WebSocketConnection? {
        get {
            _currentWebSocket.get()
        }
        set {
            let oldValue = _currentWebSocket.swap(newValue)
            if oldValue != nil || newValue != nil {
                owsAssertDebug(oldValue?.id != newValue?.id)
            }

            oldValue?.reset()

            notifyStatusChange()
        }
    }

    // MARK: -

    public var currentState: OWSChatConnectionState {
        guard let currentWebSocket = self.currentWebSocket else {
            return .closed
        }
        switch currentWebSocket.state {
        case .open:
            return .open
        case .connecting:
            return .connecting
        case .disconnected:
            return .closed
        }
    }

    // This var is thread-safe.
    public var canMakeRequests: Bool {
        currentState == .open
    }

    // This var is thread-safe.
    public var hasEmptiedInitialQueue: Bool {
        guard let currentWebSocket = self.currentWebSocket else {
            return false
        }
        return currentWebSocket.hasEmptiedInitialQueue.get()
    }

    // We cache this value instead of consulting [UIApplication sharedApplication].applicationState,
    // because UIKit only provides a "will resign active" notification, not a "did resign active"
    // notification.
    private let appIsActive = AtomicBool(false, lock: .sharedGlobal)

    private static let unsubmittedRequestTokenCounter = AtomicUInt(lock: .sharedGlobal)
    public typealias UnsubmittedRequestToken = UInt
    // This method is thread-safe.
    public func makeUnsubmittedRequestToken() -> UnsubmittedRequestToken {
        let token = Self.unsubmittedRequestTokenCounter.increment()
        unsubmittedRequestTokens.insert(token)
        applyDesiredSocketState()
        return token
    }
    private let unsubmittedRequestTokens = AtomicSet<UnsubmittedRequestToken>(lock: .sharedGlobal)
    // This method is thread-safe.
    fileprivate func removeUnsubmittedRequestToken(_ token: UnsubmittedRequestToken) {
        owsAssertDebug(unsubmittedRequestTokens.contains(token))
        unsubmittedRequestTokens.remove(token)
        applyDesiredSocketState()
    }

    // MARK: - BackgroundKeepAlive

    private enum BackgroundKeepAliveRequestType {
        case didReceivePush
        case receiveMessage
        case receiveResponse

        var keepAliveDuration: TimeInterval {
            // If the app is in the background, it should keep the
            // websocket open if:
            switch self {
            case .didReceivePush:
                // Received a push notification in the last N seconds.
                return 20
            case .receiveMessage:
                // It has received a message over the socket in the last N seconds.
                return 15
            case .receiveResponse:
                // It has just received the response to a request.
                return 5
            }
            // There are many other cases as well not associated with a fixed duration,
            // such as if currentWebSocket.hasPendingRequests; see shouldSocketBeOpen().
        }
    }

    private struct BackgroundKeepAlive {
        let requestType: BackgroundKeepAliveRequestType
        let untilDate: Date
    }

    // This var should only be accessed with unfairLock acquired.
    private var _backgroundKeepAlive: BackgroundKeepAlive?
    private let unfairLock = UnfairLock()

    // This method is thread-safe.
    private func ensureBackgroundKeepAlive(_ requestType: BackgroundKeepAliveRequestType) {
        let keepAliveDuration = requestType.keepAliveDuration
        owsAssertDebug(keepAliveDuration > 0)
        let untilDate = Date().addingTimeInterval(keepAliveDuration)

        let didChange: Bool = unfairLock.withLock {
            if let oldValue = self._backgroundKeepAlive,
               oldValue.untilDate >= untilDate {
                return false
            }
            self._backgroundKeepAlive = BackgroundKeepAlive(requestType: requestType, untilDate: untilDate)
            return true
        }

        if didChange {
            var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(label: "applicationWillResignActive")
            applyDesiredSocketState {
                assertOnQueue(self.serialQueue)
                owsAssertDebug(backgroundTask != nil)
                backgroundTask = nil
            }
        }
    }

    // This var is thread-safe.
    private var hasBackgroundKeepAlive: Bool {
        unfairLock.withLock {
            guard let backgroundKeepAlive = self._backgroundKeepAlive else {
                return false
            }
            guard backgroundKeepAlive.untilDate >= Date() else {
                // Cull expired values.
                self._backgroundKeepAlive = nil
                return false
            }
            return true
        }
    }

    private var logPrefix: String {
        if let currentWebSocket = currentWebSocket {
            return currentWebSocket.logPrefix
        } else {
            return "[\(type)]"
        }
    }

    // MARK: -

    public init(type: OWSChatConnectionType, appExpiry: AppExpiry, db: DB) {
        AssertIsOnMainThread()

        self.serialQueue = DispatchQueue(label: "org.signal.chat-connection-\(type)")
        self.type = type
        self.appExpiry = appExpiry
        self.db = db

        super.init()

        AppReadiness.runNowOrWhenAppDidBecomeReadySync { [weak self] in
            guard let self = self else { return }
            self.observeNotifications()
            self.applyDesiredSocketState()
        }
    }

    // MARK: - Notifications

    // We want to observe these notifications lazily to avoid accessing
    // the data store in [application: didFinishLaunchingWithOptions:].
    private func observeNotifications() {
        AssertIsOnMainThread()

        appIsActive.set(CurrentAppContext().isMainAppAndActive)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidBecomeActive),
                                               name: .OWSApplicationDidBecomeActive,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationWillResignActive),
                                               name: .OWSApplicationWillResignActive,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(registrationStateDidChange),
                                               name: .registrationStateDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(localNumberDidChange),
                                               name: .localNumberDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(isCensorshipCircumventionActiveDidChange),
                                               name: .isCensorshipCircumventionActiveDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(isSignalProxyReadyDidChange),
                                               name: .isSignalProxyReadyDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appExpiryDidChange),
                                               name: AppExpiryImpl.AppExpiryDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storiesEnabledStateDidChange), name: .storiesEnabledStateDidChange, object: nil)
    }

    // MARK: -

    private struct StateObservation {
        var currentState: OWSChatConnectionState
        var onOpen: [NSObject: CheckedContinuation<Void, Error>]
    }

    /// This lock is sometimes waited on within an async context; make sure *all* uses release the lock quickly.
    private let stateObservation = AtomicValue(
        StateObservation(currentState: .closed, onOpen: [:]),
        lock: .init()
    )

    private func notifyStatusChange() {
        let newState = self.currentState
        let (oldState, continuationsToResolve): (OWSChatConnectionState, [NSObject: CheckedContinuation<Void, Error>])
        (oldState, continuationsToResolve) = stateObservation.update {
            let oldState = $0.currentState
            if newState == oldState {
                return (oldState, [:])
            }
            $0.currentState = newState

            var continuationsToResolve: [NSObject: CheckedContinuation<Void, Error>] = [:]
            if case .open = newState {
                continuationsToResolve = $0.onOpen
                $0.onOpen = [:]
            }

            return (oldState, continuationsToResolve)
        }
        if newState != oldState {
            Logger.info("\(logPrefix): \(oldState) -> \(newState)")
        }
        for (_, waiter) in continuationsToResolve {
            waiter.resume()
        }
        NotificationCenter.default.postNotificationNameAsync(Self.chatConnectionStateDidChange, object: nil)
    }

    /// Only throws on cancellation.
    func waitForOpen() async throws {
        // There are three events that are relevant here:
        // A) The socket becomes open (or is already open)
        // B) The continuation is registered in the onOpen list
        // C) This task is cancelled.
        //
        // Let's exhaustively make sure all three are handled no matter the ordering:
        // - ABC: The continuation is resumed immediately at (1).
        // - ACB: The cancellation is ignored, and the continuation is resumed at (1). (This is fine.)
        // - BAC: The continuation is resumed within notifyStatusChange.
        // - BCA: The continuation is removed from the list and cancelled at (3).
        // - CAB: The cancellation is ignored, and the continuation is resumed at (1). (This is fine.)
        // - CBA: The cancellation is checked and propagated at (2).
        let cancellationToken = NSObject()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                // We are locking during an async task! *gasp*
                // This is only okay because *every* use of this lock does a short and finite amount of work.
                stateObservation.update {
                    if $0.currentState == .open {
                        continuation.resume() // (1)
                        return
                    }
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError()) // (2)
                        return
                    }
                    $0.onOpen[cancellationToken] = continuation
                }
            }
        }, onCancel: {
            stateObservation.update {
                let continuation = $0.onOpen.removeValue(forKey: cancellationToken)
                continuation?.resume(throwing: CancellationError()) // (3)
            }
        })
    }

    // MARK: - Message Sending

    public typealias RequestSuccess = (HTTPResponse) -> Void
    public typealias RequestFailure = (OWSHTTPError) -> Void
    fileprivate typealias RequestSuccessInternal = (HTTPResponse, RequestInfo) -> Void

    fileprivate func makeRequestInternal(_ request: TSRequest,
                                         unsubmittedRequestToken: UnsubmittedRequestToken,
                                         success: @escaping RequestSuccessInternal,
                                         failure: @escaping RequestFailure) {
        assertOnQueue(self.serialQueue)

        defer {
            removeUnsubmittedRequestToken(unsubmittedRequestToken)
        }

        var label = Self.label(forRequest: request,
                               connectionType: type,
                               requestInfo: nil)
        guard let requestUrl = request.url else {
            owsFailDebug("\(label) Missing requestUrl.")
            DispatchQueue.global().async {
                failure(.invalidRequest(requestUrl: request.url!))
            }
            return
        }
        guard let httpMethod = request.httpMethod.nilIfEmpty else {
            owsFailDebug("\(label) Missing httpMethod.")
            DispatchQueue.global().async {
                failure(.invalidRequest(requestUrl: requestUrl))
            }
            return
        }
        guard let currentWebSocket = currentWebSocket,
              currentWebSocket.state == .open else {
            owsFailDebug("\(label) Missing currentWebSocket.")
            DispatchQueue.global().async {
                failure(.networkFailure(requestUrl: requestUrl))
            }
            return
        }

        let requestInfo = RequestInfo(request: request,
                                      requestUrl: requestUrl,
                                      connectionType: type,
                                      success: success,
                                      failure: failure)
        label = Self.label(forRequest: request,
                           connectionType: type,
                           requestInfo: requestInfo)

        owsAssertDebug(requestUrl.scheme == nil)
        owsAssertDebug(requestUrl.host == nil)
        owsAssertDebug(!requestUrl.path.hasPrefix("/"))
        let requestBuilder = WebSocketProtoWebSocketRequestMessage.builder(verb: httpMethod,
                                                                           path: "/\(requestUrl)",
                                                                           requestID: requestInfo.requestId)

        let httpHeaders = OWSHttpHeaders()
        httpHeaders.addHeaderMap(request.allHTTPHeaderFields, overwriteOnConflict: false)

        if let existingBody = request.httpBody {
            requestBuilder.setBody(existingBody)
        } else {
            // TODO: Do we need body & headers for requests with no parameters?
            let jsonData: Data?
            do {
                jsonData = try JSONSerialization.data(withJSONObject: request.parameters, options: [])
            } catch {
                owsFailDebug("\(label) Error: \(error).")
                requestInfo.didFailInvalidRequest()
                return
            }

            if let jsonData = jsonData {
                requestBuilder.setBody(jsonData)
                // If we're going to use the json serialized parameters as our body, we should overwrite
                // the Content-Type on the request.
                httpHeaders.addHeader("Content-Type",
                                      value: "application/json",
                                      overwriteOnConflict: true)
            }
        }

        // Set User-Agent and Accept-Language headers.
        httpHeaders.addDefaultHeaders()

        for (key, value) in httpHeaders.headers {
            let header = String(format: "%@:%@", key, value)
            requestBuilder.addHeaders(header)
        }

        do {
            let requestProto = try requestBuilder.build()

            let messageBuilder = WebSocketProtoWebSocketMessage.builder()
            messageBuilder.setType(.request)
            messageBuilder.setRequest(requestProto)
            let messageData = try messageBuilder.buildSerializedData()

            guard currentWebSocket.state == .open else {
                owsFailDebug("\(label) Socket not open.")
                requestInfo.didFailInvalidRequest()
                return
            }

            Logger.info("\(label) Making request")

            currentWebSocket.sendRequest(requestInfo: requestInfo,
                                         messageData: messageData,
                                         delegate: self)
        } catch {
            owsFailDebug("\(label), Error: \(error).")
            requestInfo.didFailInvalidRequest()
            return
        }
    }

    private func processWebSocketResponseMessage(_ message: WebSocketProtoWebSocketResponseMessage,
                                                 currentWebSocket: WebSocketConnection) {
        assertOnQueue(serialQueue)

        let requestId = message.requestID
        let responseStatus = message.status
        let responseData: Data? = message.hasBody ? message.body : nil

        if DebugFlags.internalLogging,
           message.hasMessage,
           let responseMessage = message.message {
            Logger.info("received WebSocket response \(currentWebSocket.logPrefix), requestId: \(message.requestID), status: \(message.status), message: \(responseMessage)")
        } else {
            Logger.info("received WebSocket response \(currentWebSocket.logPrefix), requestId: \(message.requestID), status: \(message.status)")
        }

        ensureBackgroundKeepAlive(.receiveResponse)

        let headers = OWSHttpHeaders()
        headers.addHeaderList(message.headers, overwriteOnConflict: true)

        guard let requestInfo = currentWebSocket.popRequestInfo(forRequestId: requestId) else {
            Logger.warn("Received response to unknown request \(currentWebSocket.logPrefix)")
            return
        }
        requestInfo.complete(status: Int(responseStatus), headers: headers, data: responseData)

        // We may have been holding the websocket open, waiting for this response.
        // Check if we should close the websocket.
        applyDesiredSocketState()
    }

    // MARK: -

    fileprivate func processWebSocketRequestMessage(_ message: WebSocketProtoWebSocketRequestMessage,
                                                    currentWebSocket: WebSocketConnection) {
        assertOnQueue(self.serialQueue)

        let httpMethod = message.verb.nilIfEmpty ?? ""
        let httpPath = message.path.nilIfEmpty ?? ""
        owsAssertDebug(!httpMethod.isEmpty)
        owsAssertDebug(!httpPath.isEmpty)

        Logger.info("Got message \(currentWebSocket.logPrefix): verb: \(httpMethod), path: \(httpPath)")

        if httpMethod == "PUT",
           httpPath == "/api/v1/message" {

            // If we receive a message over the socket while the app is in the background,
            // prolong how long the socket stays open.
            //
            // TODO: NSE
            ensureBackgroundKeepAlive(.receiveMessage)

            handleIncomingMessage(message, currentWebSocket: currentWebSocket)
        } else if httpPath == "/api/v1/queue/empty" {
            // Queue is drained.
            handleEmptyQueueMessage(message, currentWebSocket: currentWebSocket)
        } else {
            Logger.warn("Unsupported WebSocket Request \(currentWebSocket.logPrefix)")

            sendWebSocketMessageAcknowledgement(message, currentWebSocket: currentWebSocket)
        }
    }

    private func handleIncomingMessage(_ message: WebSocketProtoWebSocketRequestMessage,
                                       currentWebSocket: WebSocketConnection) {
        assertOnQueue(self.serialQueue)

        var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(label: "handleIncomingMessage")

        let ackMessage = { (processingError: Error?, serverTimestamp: UInt64) in
            let ackBehavior = MessageProcessor.handleMessageProcessingOutcome(error: processingError)
            switch ackBehavior {
            case .shouldAck:
                self.sendWebSocketMessageAcknowledgement(message, currentWebSocket: currentWebSocket)
            case .shouldNotAck(let error):
                Logger.info("Skipping ack of message with serverTimestamp \(serverTimestamp) because of error: \(error)")
            }

            owsAssertDebug(backgroundTask != nil)
            backgroundTask = nil
        }

        let headers = OWSHttpHeaders()
        headers.addHeaderList(message.headers, overwriteOnConflict: true)

        var serverDeliveryTimestamp: UInt64 = 0
        if let timestampString = headers.value(forHeader: "x-signal-timestamp") {
            if let timestamp = UInt64(timestampString) {
                serverDeliveryTimestamp = timestamp
            } else {
                owsFailDebug("Invalidly formatted timestamp: \(timestampString)")
            }
        }

        if serverDeliveryTimestamp == 0 {
            owsFailDebug("Missing server delivery timestamp")
        }

        guard let encryptedEnvelope = message.body else {
            ackMessage(OWSGenericError("Missing encrypted envelope on message \(currentWebSocket.logPrefix)"), serverDeliveryTimestamp)
            return
        }
        let envelopeSource: EnvelopeSource = {
            switch self.type {
            case .identified:
                return .websocketIdentified
            case .unidentified:
                return .websocketUnidentified
            }
        }()

        Self.messageProcessingQueue.async {
            Self.messageProcessor.processReceivedEnvelopeData(
                encryptedEnvelope,
                serverDeliveryTimestamp: serverDeliveryTimestamp,
                envelopeSource: envelopeSource
            ) { error in
                self.serialQueue.async {
                    ackMessage(error, serverDeliveryTimestamp)
                }
            }
        }
    }

    private func handleEmptyQueueMessage(_ message: WebSocketProtoWebSocketRequestMessage,
                                         currentWebSocket: WebSocketConnection) {
        assertOnQueue(self.serialQueue)

        // Queue is drained.

        sendWebSocketMessageAcknowledgement(message, currentWebSocket: currentWebSocket)

        guard !currentWebSocket.hasEmptiedInitialQueue.get() else {
            owsFailDebug("Unexpected emptyQueueMessage \(currentWebSocket.logPrefix)")
            return
        }
        // We need to flush the message processing and serial queues
        // to ensure that all received messages are enqueued and
        // processed before we: a) mark the queue as empty. b) notify.
        //
        // The socket might close and re-open while we're
        // flushing the queues. Therefore we capture currentWebSocket
        // flushing to ensure that we handle this case correctly.
        Self.messageProcessingQueue.async { [weak self] in
            self?.serialQueue.async {
                guard let self = self else { return }
                if currentWebSocket.hasEmptiedInitialQueue.tryToSetFlag() {
                    self.notifyStatusChange()
                }

                // We may have been holding the websocket open, waiting to drain the
                // queue. Check if we should close the websocket.
                self.applyDesiredSocketState()
            }
        }
    }

    private func sendWebSocketMessageAcknowledgement(_ request: WebSocketProtoWebSocketRequestMessage,
                                                     currentWebSocket: WebSocketConnection) {
        assertOnQueue(self.serialQueue)

        do {
            try currentWebSocket.sendResponse(for: request,
                                              status: 200,
                                              message: "OK")
        } catch {
            owsFailDebugUnlessNetworkFailure(error)
        }
    }

    // This method is thread-safe.
    private func cycleSocket() {
        self.currentWebSocket = nil

        applyDesiredSocketState()
    }

    // This method is thread-safe.
    private var webSocketAuthenticationQueryItems: [URLQueryItem]? {
        switch type {
        case .unidentified:
            // UD socket is unauthenticated.
            return nil
        case .identified:
            let login = DependenciesBridge.shared.tsAccountManager.storedServerUsernameWithMaybeTransaction ?? ""
            let password = DependenciesBridge.shared.tsAccountManager.storedServerAuthTokenWithMaybeTransaction ?? ""
            owsAssertDebug(login.nilIfEmpty != nil)
            owsAssertDebug(password.nilIfEmpty != nil)
            return [
                URLQueryItem(name: "login", value: login),
                URLQueryItem(name: "password", value: password)
            ]
        }
    }

    // MARK: - Socket LifeCycle

    public static var canAppUseSocketsToMakeRequests: Bool {
        if FeatureFlags.deprecateREST {
            // When we deprecate REST, we will use web sockets in app extensions.
            return true
        }
        if !CurrentAppContext().isMainApp {
            return false
        }
        return true
    }

    // This var is thread-safe.
    public var shouldSocketBeOpen: Bool {
        desiredSocketState.shouldSocketBeOpen
    }

    private enum DesiredSocketState: Equatable {
        case closed(reason: String)
        case open(reason: String)

        public var shouldSocketBeOpen: Bool {
            switch self {
            case .closed:
                return false
            case .open:
                return true
            }
        }
    }

    // This method is thread-safe.
    private var desiredSocketState: DesiredSocketState {
        guard AppReadiness.isAppReady else {
            return .closed(reason: "!isAppReady")
        }

        guard DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
            return .closed(reason: "!isRegisteredAndReady")
        }

        guard !appExpiry.isExpired else {
            return .closed(reason: "appExpiry.isExpired")
        }

        guard Self.canAppUseSocketsToMakeRequests else {
            return .closed(reason: "!canAppUseSocketsToMakeRequests")
        }

        if let currentWebSocket, currentWebSocket.hasPendingRequests {
            return .open(reason: "hasPendingRequests")
        }

        if !unsubmittedRequestTokens.isEmpty {
            return .open(reason: "unsubmittedRequestTokens")
        }

        guard GlobalDependencies.webSocketFactory.canBuildWebSocket else {
            owsFailDebug("\(logPrefix) Could not build webSocket.")
            return .closed(reason: "couldNotBuildWebSocket")
        }

        if appIsActive.get() {
            // While app is active, keep web socket alive.
            return .open(reason: "appIsActive")
        }

        if hasBackgroundKeepAlive {
            // If app is doing any work in the background, keep web socket alive.
            return .open(reason: "hasBackgroundKeepAlive")
        }

        return .closed(reason: "default false")
    }

    // This method is thread-safe.
    public func didReceivePush() {
        owsAssertDebug(AppReadiness.isAppReady)

        self.ensureBackgroundKeepAlive(.didReceivePush)
    }

    private let lastDesiredSocketState = AtomicValue<DesiredSocketState>(.closed(reason: "App launched"), lock: .sharedGlobal)

    // This method aligns the socket state with the "desired" socket state.
    //
    // This method is thread-safe.
    private func applyDesiredSocketState(completion: (() -> Void)? = nil) {

        guard AppReadiness.isAppReady else {
            AppReadiness.runNowOrWhenAppDidBecomeReadySync { [weak self] in
                self?.applyDesiredSocketState(completion: completion)
            }
            return
        }

        serialQueue.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }

            let desiredSocketStateNew = self.desiredSocketState
            _ = self.lastDesiredSocketState.swap(desiredSocketStateNew)

            var shouldHaveBackgroundKeepAlive = false
            if desiredSocketStateNew.shouldSocketBeOpen {
                self.ensureWebsocketExists()

                if self.currentState != .open {
                    // If we want the socket to be open and it's not open,
                    // start up the reconnect timer immediately (don't wait for an error).
                    // There's little harm in it and this will make us more robust to edge
                    // cases.
                    self.ensureReconnectTimer()
                }

                // If we're keeping the webSocket open in the background,
                // ensure that the "BackgroundKeepAlive" state is active.
                shouldHaveBackgroundKeepAlive = !self.appIsActive.get()
            } else {
                self.clearReconnect()
                self.currentWebSocket = nil
            }

            if shouldHaveBackgroundKeepAlive {
                if nil == self.backgroundKeepAliveTimer {
                    // Start a new timer that will fire every second while the socket is open in the background.
                    // This timer will ensure we close the websocket when the time comes.
                    self.backgroundKeepAliveTimer = OffMainThreadTimer(timeInterval: 1, repeats: true) { [weak self] timer in
                        guard let self = self else {
                            timer.invalidate()
                            return
                        }
                        self.applyDesiredSocketState()
                    }
                }
                if nil == self.backgroundKeepAliveBackgroundTask {
                    self.backgroundKeepAliveBackgroundTask = OWSBackgroundTask(label: "BackgroundKeepAlive") { [weak self] (_) in
                        AssertIsOnMainThread()
                        self?.applyDesiredSocketState()
                    }
                }
            } else {
                self.backgroundKeepAliveTimer?.invalidate()
                self.backgroundKeepAliveTimer = nil
                self.backgroundKeepAliveBackgroundTask = nil
            }

            completion?()
        }
    }

    // This timer is used to check periodically whether we should
    // close the socket.
    private var backgroundKeepAliveTimer: OffMainThreadTimer?
    // This is used to manage the iOS "background task" used to
    // keep the app alive in the background.
    private var backgroundKeepAliveBackgroundTask: OWSBackgroundTask?

    private func ensureWebsocketExists() {
        assertOnQueue(serialQueue)

        // Try to reuse the existing socket (if any) if it is in a valid state.
        if let currentWebSocket = self.currentWebSocket {
            switch currentWebSocket.state {
            case .open:
                self.clearReconnect()
                return
            case .connecting:
                return
            case .disconnected:
                break
            }
        }

        let signalServiceType: SignalServiceType
        switch type {
        case .identified:
            signalServiceType = .mainSignalServiceIdentified
        case .unidentified:
            signalServiceType = .mainSignalServiceUnidentified
        }

        let request = WebSocketRequest(
            signalService: signalServiceType,
            urlPath: "v1/websocket/",
            urlQueryItems: webSocketAuthenticationQueryItems,
            extraHeaders: StoryManager.buildStoryHeaders()
        )

        guard let webSocket = GlobalDependencies.webSocketFactory.buildSocket(
            request: request,
            callbackScheduler: self.serialQueue
        ) else {
            owsFailDebug("Missing webSocket.")
            return
        }
        webSocket.delegate = self
        let newWebSocket = WebSocketConnection(connectionType: type, webSocket: webSocket)
        self.currentWebSocket = newWebSocket

        // `connect` could hypothetically call a delegate method (e.g. if
        // the socket failed immediately for some reason), so we update currentWebSocket
        // _before_ calling it, not after.
        webSocket.connect()

        self.serialQueue.asyncAfter(deadline: .now() + 30) { [weak self, weak newWebSocket] in
            guard let self, let newWebSocket, self.currentWebSocket?.id == newWebSocket.id else {
                return
            }

            if !newWebSocket.hasConnected.get() {
                Logger.warn("Websocket failed to connect.")
                self.cycleSocket()
            }
        }
    }

    // MARK: - Reconnect

    private var reconnectTimer: OffMainThreadTimer?

    // This method is thread-safe.
    private func ensureReconnectTimer() {
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            if let reconnectTimer = self.reconnectTimer {
                owsAssertDebug(reconnectTimer.isValid)
            } else {
                // TODO: It'd be nice to do exponential backoff.
                self.reconnectTimer = OffMainThreadTimer(timeInterval: Self.socketReconnectDelaySeconds,
                                                         repeats: true) { [weak self] timer in
                    guard let self = self else {
                        timer.invalidate()
                        return
                    }
                    self.applyDesiredSocketState()
                }
            }
        }
    }

    // This method is thread-safe.
    private func clearReconnect() {
        assertOnQueue(serialQueue)

        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    // MARK: - Notifications

    @objc
    private func applicationDidBecomeActive(_ notification: NSNotification) {
        AssertIsOnMainThread()

        appIsActive.set(true)

        applyDesiredSocketState()
    }

    @objc
    private func applicationWillResignActive(_ notification: NSNotification) {
        AssertIsOnMainThread()

        appIsActive.set(false)

        applyDesiredSocketState()
    }

    @objc
    private func registrationStateDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        applyDesiredSocketState()
    }

    @objc
    private func localNumberDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        cycleSocket()
    }

    @objc
    private func isCensorshipCircumventionActiveDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        cycleSocket()
    }

    @objc
    private func isSignalProxyReadyDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        guard SignalProxy.isEnabledAndReady else {
            // When we tear down the relay, everything gets canceled.
            return
        }
        // When we start the relay, we need to reconnect.
        cycleSocket()
    }

    @objc
    private func appExpiryDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        cycleSocket()
    }

    @objc
    private func storiesEnabledStateDidChange(_ notification: NSNotification) {
        AssertIsOnMainThread()

        cycleSocket()
    }
}

// MARK: -

extension OWSChatConnection {

    fileprivate static func label(forRequest request: TSRequest,
                                  connectionType: OWSChatConnectionType,
                                  requestInfo: RequestInfo?) -> String {

        var label = "\(connectionType), \(request)"
        if let requestInfo = requestInfo {
            label += ", [\(requestInfo.requestId)]"
        }
        return label
    }

    public func makeRequest(_ request: TSRequest,
                            unsubmittedRequestToken: UnsubmittedRequestToken) async throws -> HTTPResponse {
        guard !appExpiry.isExpired else {
            removeUnsubmittedRequestToken(unsubmittedRequestToken)

            guard let requestUrl = request.url else {
                owsFail("Missing requestUrl.")
            }
            throw OWSHTTPError.invalidAppState(requestUrl: requestUrl)
        }

        let connectionType = self.type

        let isIdentifiedConnection = connectionType == .identified
        let isIdentifiedRequest = request.shouldHaveAuthorizationHeaders && !request.isUDRequest
        owsAssertDebug(isIdentifiedConnection == isIdentifiedRequest)

        let (response, requestInfo) = try await withCheckedThrowingContinuation { continuation in
            self.serialQueue.async {
                self.makeRequestInternal(
                    request,
                    unsubmittedRequestToken: unsubmittedRequestToken,
                    success: { continuation.resume(returning: ($0, $1)) },
                    failure: { continuation.resume(throwing: $0) }
                )
            }
        }

        let label = Self.label(forRequest: request, connectionType: connectionType, requestInfo: requestInfo)
        Logger.info("\(label): Request Succeeded (\(response.responseStatusCode))")

        Self.outageDetection.reportConnectionSuccess()
        return response
    }
}

// MARK: -

private class RequestInfo {

    let request: TSRequest

    let requestUrl: URL

    let requestId: UInt64 = Cryptography.randomUInt64()

    let connectionType: OWSChatConnectionType

    let startDate = Date()

    var intervalSinceStartDateFormatted: String {
        startDate.formatIntervalSinceNow
    }

    // We use an enum to ensure that the completion handlers are
    // released as soon as the message completes.
    private enum Status {
        case incomplete(success: RequestSuccess, failure: RequestFailure)
        case complete
    }

    private let status: AtomicValue<Status>

    private let backgroundTask: OWSBackgroundTask

    typealias RequestSuccess = OWSChatConnection.RequestSuccessInternal
    typealias RequestFailure = OWSChatConnection.RequestFailure

    init(request: TSRequest,
         requestUrl: URL,
         connectionType: OWSChatConnectionType,
         success: @escaping RequestSuccess,
         failure: @escaping RequestFailure) {
        self.request = request
        self.requestUrl = requestUrl
        self.connectionType = connectionType
        self.status = AtomicValue(.incomplete(success: success, failure: failure), lock: .sharedGlobal)
        self.backgroundTask = OWSBackgroundTask(label: "ChatRequestInfo")
    }

    func complete(status: Int, headers: OWSHttpHeaders, data: Data?) {
        if (200...299).contains(status) {
            let response = HTTPResponseImpl(requestUrl: requestUrl,
                                            status: status,
                                            headers: headers,
                                            bodyData: data)
            didSucceed(response: response)
        } else {
            let error = HTTPUtils.preprocessMainServiceHTTPError(
                request: request,
                requestUrl: requestUrl,
                responseStatus: status,
                responseHeaders: headers,
                responseData: data
            )
            didFail(error: error)
        }
    }

    private func didSucceed(response: HTTPResponse) {
        // Ensure that we only complete once.
        switch status.swap(.complete) {
        case .complete:
            return
        case .incomplete(let success, _):
            success(response, self)
        }
    }

    // Returns true if the message timed out.
    func timeoutIfNecessary() -> Bool {
        return didFail(error: OWSHTTPError.networkFailure(requestUrl: requestUrl))
    }

    func didFailInvalidRequest() {
        didFail(error: OWSHTTPError.invalidRequest(requestUrl: requestUrl))
    }

    func didFailDueToNetwork() {
        didFail(error: OWSHTTPError.networkFailure(requestUrl: requestUrl))
    }

    @discardableResult
    private func didFail(error: Error) -> Bool {
        // Ensure that we only complete once.
        switch status.swap(.complete) {
        case .complete:
            return false
        case .incomplete(_, let failure):
            Logger.warn("\(error)")
            failure(error as! OWSHTTPError)
            return true
        }
    }
}

// MARK: -

extension OWSChatConnection: SSKWebSocketDelegate {

    public func websocketDidConnect(socket eventSocket: SSKWebSocket) {
        assertOnQueue(self.serialQueue)

        guard let currentWebSocket = self.currentWebSocket,
              currentWebSocket.id == eventSocket.id else {
            // Ignore events from obsolete web sockets.
            return
        }

        currentWebSocket.didConnect(delegate: self)

        // If socket opens, we know we're not de-registered.
        if type == .identified {
            let tsAccountManager = DependenciesBridge.shared.tsAccountManager
            if tsAccountManager.registrationStateWithMaybeSneakyTransaction.isDeregistered {
                DependenciesBridge.shared.db.write { tx in
                    DependenciesBridge.shared.registrationStateChangeManager.setIsDeregisteredOrDelinked(false, tx: tx)
                }
            }
        }

        outageDetection.reportConnectionSuccess()

        notifyStatusChange()
    }

    public func websocketDidDisconnectOrFail(socket eventSocket: SSKWebSocket, error: Error) {
        assertOnQueue(self.serialQueue)

        guard let currentWebSocket = self.currentWebSocket,
              currentWebSocket.id == eventSocket.id else {
            // Ignore events from obsolete web sockets.
            return
        }

        Logger.warn("Websocket did fail \(logPrefix): \(error)")

        self.currentWebSocket = nil

        if type == .identified, case WebSocketError.httpError(statusCode: 403, _) = error {
            DependenciesBridge.shared.db.write { tx in
                DependenciesBridge.shared.registrationStateChangeManager.setIsDeregisteredOrDelinked(true, tx: tx)
            }
        }

        if shouldSocketBeOpen {
            // If we should retry, use `ensureReconnectTimer` to reconnect after a delay.
            ensureReconnectTimer()
        } else {
            // Otherwise clean up and align state.
            applyDesiredSocketState()
        }

        outageDetection.reportConnectionFailure()
    }

    public func websocket(_ eventSocket: SSKWebSocket, didReceiveData data: Data) {
        assertOnQueue(self.serialQueue)
        let message: WebSocketProtoWebSocketMessage
        do {
            message = try WebSocketProtoWebSocketMessage(serializedData: data)
        } catch {
            owsFailDebug("Failed to deserialize message: \(error)")
            return
        }

        guard let currentWebSocket = self.currentWebSocket,
              currentWebSocket.id == eventSocket.id else {
            // Ignore events from obsolete web sockets.
            return
        }

        if !message.hasType {
            owsFailDebug("webSocket:didReceiveResponse: missing type.")
        } else if message.unwrappedType == .request {
            if let request = message.request {
                processWebSocketRequestMessage(request, currentWebSocket: currentWebSocket)
            } else {
                owsFailDebug("Missing request.")
            }
        } else if message.unwrappedType == .response {
            if let response = message.response {
                processWebSocketResponseMessage(response, currentWebSocket: currentWebSocket)
            } else {
                owsFailDebug("Missing response.")
            }
        } else {
            owsFailDebug("webSocket:didReceiveResponse: unknown.")
        }
    }
}

// MARK: -

extension OWSChatConnection: WebSocketConnectionDelegate {
    fileprivate func webSocketSendHeartBeat(_ webSocket: WebSocketConnection) {
        if shouldSocketBeOpen {
            webSocket.writePing()
        } else {
            Logger.warn("Closing web socket: \(logPrefix).")
            applyDesiredSocketState()
        }
    }

    fileprivate func webSocketRequestDidTimeout() {
        cycleSocket()
    }
}

// MARK: -

private protocol WebSocketConnectionDelegate: AnyObject {
    func webSocketSendHeartBeat(_ webSocket: WebSocketConnection)
    func webSocketRequestDidTimeout()
}

// MARK: -

private class WebSocketConnection {

    private let connectionType: OWSChatConnectionType

    private let webSocket: SSKWebSocket

    private let unfairLock = UnfairLock()

    public var id: UInt { webSocket.id }

    public let hasEmptiedInitialQueue = AtomicBool(false, lock: .sharedGlobal)

    public var state: SSKWebSocketState { webSocket.state }

    private var requestInfoMap = AtomicDictionary<UInt64, RequestInfo>(lock: .sharedGlobal)

    public var hasPendingRequests: Bool {
        !requestInfoMap.isEmpty
    }

    public let hasConnected = AtomicBool(false, lock: .sharedGlobal)

    public var logPrefix: String {
        "[\(connectionType): \(id)]"
    }

    init(connectionType: OWSChatConnectionType, webSocket: SSKWebSocket) {
        owsAssertDebug(!CurrentAppContext().isRunningTests)

        self.connectionType = connectionType
        self.webSocket = webSocket
    }

    deinit {
        reset()
    }

    private var heartbeatTimer: OffMainThreadTimer?

    func didConnect(delegate: WebSocketConnectionDelegate) {
        hasConnected.set(true)

        startHeartbeat(delegate: delegate)
    }

    private func startHeartbeat(delegate: WebSocketConnectionDelegate) {
        let heartbeatPeriodSeconds: TimeInterval = 30
        self.heartbeatTimer = OffMainThreadTimer(timeInterval: heartbeatPeriodSeconds,
                                                 repeats: true) { [weak self, weak delegate] timer in
            guard let self = self,
                  let delegate = delegate else {
                owsFailDebug("Missing self or delegate.")
                timer.invalidate()
                return
            }
            delegate.webSocketSendHeartBeat(self)
        }
    }

    func writePing() {
        webSocket.writePing()
    }

    func reset() {
        unfairLock.withLock {
            webSocket.delegate = nil
            webSocket.disconnect(code: nil)
        }

        heartbeatTimer?.invalidate()
        self.heartbeatTimer = nil

        let requestInfos = requestInfoMap.removeAllValues()
        failPendingMessages(requestInfos: requestInfos)
    }

    private func failPendingMessages(requestInfos: [RequestInfo]) {
        guard !requestInfos.isEmpty else {
            return
        }

        Logger.info("\(logPrefix): \(requestInfos.count).")

        for requestInfo in requestInfos {
            requestInfo.didFailDueToNetwork()
        }
    }

    // This method is thread-safe.
    fileprivate func sendRequest(requestInfo: RequestInfo,
                                 messageData: Data,
                                 delegate: WebSocketConnectionDelegate) {
        requestInfoMap[requestInfo.requestId] = requestInfo

        webSocket.write(data: messageData)

        let socketTimeoutSeconds: TimeInterval = 10
        DispatchQueue.global().asyncAfter(deadline: .now() + socketTimeoutSeconds) { [weak delegate, weak requestInfo] in
            guard let delegate = delegate,
                  let requestInfo = requestInfo else {
                return
            }

            if requestInfo.timeoutIfNecessary() {
                delegate.webSocketRequestDidTimeout()
            }
        }
    }

    fileprivate func popRequestInfo(forRequestId requestId: UInt64) -> RequestInfo? {
        requestInfoMap.removeValue(forKey: requestId)
    }

    fileprivate func sendResponse(for request: WebSocketProtoWebSocketRequestMessage,
                                  status: UInt32,
                                  message: String) throws {
        try webSocket.sendResponse(for: request, status: status, message: message)
    }
}
