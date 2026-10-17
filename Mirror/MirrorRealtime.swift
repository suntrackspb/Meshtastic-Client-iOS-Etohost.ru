import Foundation
import Network
import Observation

/// WebSocket-подписка на зеркало с автоматическим переподключением.
/// Падения сети не влияют на остальное приложение: радио-часть живёт независимо,
/// а здесь просто идут повторные попытки с экспоненциальной задержкой.
@MainActor
@Observable
final class MirrorRealtime {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case waiting(retryIn: Int)
        case offline
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let chat: ChatStore
    @ObservationIgnored private let nodes: NodesStore
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkAvailable = true

    init(chat: ChatStore, nodes: NodesStore) {
        self.chat = chat
        self.nodes = nodes
    }

    func start() {
        guard loop == nil, AppSettings.mirrorEnabled else { return }
        startPathMonitor()
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        attempt = 0
        state = .idle
    }

    /// Возврат в приложение: старый сокет после сна часто «живой» только на бумаге —
    /// не ждём таймаутов, а переподключаемся сразу.
    func resume() {
        guard AppSettings.mirrorEnabled else { return }
        startPathMonitor()
        reconnectNow()
    }

    /// Переподключиться сразу, не дожидаясь окончания паузы.
    func reconnectNow() {
        attempt = 0
        loop?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            guard networkAvailable else {
                state = .offline
                // Сразу после разблокировки сеть может кратко пропадать — проверяем часто.
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            state = .connecting
            await connectAndListen()
            if Task.isCancelled { break }

            attempt += 1
            // 1, 2, 4, 8, 15, 15… секунд: первые попытки быстрые.
            let delay = min(15, 1 << min(attempt - 1, 4))
            for remaining in stride(from: delay, to: 0, by: -1) {
                state = .waiting(retryIn: remaining)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
        }
    }

    private func connectAndListen() async {
        let task = URLSession.shared.webSocketTask(with: MirrorAPI.webSocketURL)
        self.task = task
        task.resume()

        // Пинг каждые 15 с; нет ответа — рвём сокет, чтобы не ждать системного таймаута в минуту.
        let pinger = Task { [weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let task, !Task.isCancelled else { return }
                let alive = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    let once = OnceFlag()
                    task.sendPing { error in
                        if once.claim() { continuation.resume(returning: error == nil) }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                        if once.claim() { continuation.resume(returning: false) }
                    }
                }
                if !alive {
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer { pinger.cancel() }

        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: continue
                }
                if state != .connected {
                    state = .connected
                    attempt = 0
                }
                handle(data)
            }
        } catch {
            task.cancel(with: .abnormalClosure, reason: nil)
        }
    }

    private func handle(_ data: Data) {
        guard let event = try? MirrorEvent.decode(data) else { return }
        switch event {
        case .initial(let messages): chat.ingestMirror(messages)
        case .newMessage(let message): chat.ingestMirror([message])
        case .relayUpdate(let id, let relay): chat.applyMirrorRelay(messageId: id, relay: relay)
        case .nodeUpdate(let node): nodes.upsertMirror([node])
        case .other: break
        }
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasAvailable = self.networkAvailable
                self.networkAvailable = available
                if available && !wasAvailable && self.loop != nil {
                    self.reconnectNow()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "mirror.path"))
        pathMonitor = monitor
    }
}

/// Потокобезопасный «сработать один раз» для continuation с таймаутом.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
