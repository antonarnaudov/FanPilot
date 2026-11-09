import Foundation

public enum HelperConnectionError: Error, CustomStringConvertible {
    case unavailable(String)
    case timeout
    case badReply
    case rejected(String)

    public var description: String {
        switch self {
        case .unavailable(let reason): return "helper not reachable (\(reason))"
        case .timeout: return "helper did not answer"
        case .badReply: return "helper sent an unreadable reply"
        case .rejected(let message): return message
        }
    }
}

/// Async client for the helper's XPC service.
public final class HelperConnection: @unchecked Sendable {
    /// A LaunchDaemon (the real install) needs `privileged`; a development
    /// LaunchAgent does not.
    public let privileged: Bool
    private var connection: NSXPCConnection?
    private let lock = NSLock()

    public init(privileged: Bool = true) {
        self.privileged = privileged
    }

    deinit { connection?.invalidate() }

    private func current() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let connection = NSXPCConnection(
            machServiceName: FanPilot.helperLabel, options: privileged ? .privileged : [])
        connection.remoteObjectInterface = NSXPCInterface(with: FanPilotHelperProtocol.self)
        connection.invalidationHandler = { [weak self, weak connection] in self?.reset(ifCurrent: connection) }
        connection.interruptionHandler = { [weak self, weak connection] in self?.reset(ifCurrent: connection) }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// Drops the connection, but only if it's still the one a handler belongs to.
    private func reset(ifCurrent expected: NSXPCConnection?) {
        lock.lock()
        guard let expected, connection === expected else {
            lock.unlock()
            return
        }
        connection = nil
        lock.unlock()
        expected.invalidate()
    }

    private func reset() {
        lock.lock()
        let old = connection
        connection = nil
        lock.unlock()
        old?.invalidate()
    }

    public func invalidate() { reset() }

    private func call<T: Sendable>(
        timeout: TimeInterval = 4,
        _ body: @escaping (FanPilotHelperProtocol, @escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once(continuation)
            let proxy = current().remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(HelperConnectionError.unavailable(error.localizedDescription)))
            }
            guard let helper = proxy as? FanPilotHelperProtocol else {
                once.resume(.failure(HelperConnectionError.unavailable("no proxy")))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(HelperConnectionError.timeout))
            }
            body(helper) { once.resume($0) }
        }
    }

    public func version() async throws -> String {
        try await call { helper, done in helper.version { done(.success($0)) } }
    }

    public func state() async throws -> HelperState {
        let data: Data = try await call { helper, done in helper.state { done(.success($0)) } }
        guard let state = try? FanPilotJSON.decoder.decode(HelperState.self, from: data) else {
            throw HelperConnectionError.badReply
        }
        return state
    }

    public func config() async throws -> FanPilotConfig {
        let data: Data = try await call { helper, done in helper.config { done(.success($0)) } }
        guard let config = try? FanPilotJSON.decoder.decode(FanPilotConfig.self, from: data) else {
            throw HelperConnectionError.badReply
        }
        return config
    }

    public func setConfig(_ config: FanPilotConfig) async throws {
        let data = try FanPilotJSON.encoder.encode(config)
        let error: String? = try await call { helper, done in helper.setConfig(data) { done(.success($0)) } }
        if let error { throw HelperConnectionError.rejected(error) }
    }
}

/// Resumes a continuation at most once (reply, error handler and timeout race).
private final class Once<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
