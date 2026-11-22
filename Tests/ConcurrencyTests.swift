// ConcurrencyTests.swift — actor, TaskGroup, Cancellation, ManualClock.

import Testing
import Foundation
@testable import SwiftPractice

@Suite("Concurrency")
struct ConcurrencyTests {

    // MARK: TaskGroup

    @Test("boundedMap не превышает лимит параллелизма и сохраняет порядок")
    func boundedMapRespectsLimit() async throws {
        let probe = TaskGroupLesson.ConcurrencyProbe()
        let out = try await TaskGroupLesson.boundedMap(Array(1...30), limit: 4) { n in
            await probe.enter()
            try await Task.sleep(for: .milliseconds(5))
            await probe.leave()
            return n * 2
        }
        #expect(out == (1...30).map { $0 * 2 })
        #expect(await probe.peak <= 4)
    }

    @Test("boundedMap: ошибка одного элемента отменяет операцию")
    func boundedMapFailsFast() async {
        await #expect(throws: URLError.self) {
            _ = try await TaskGroupLesson.allOrNothing([1, 13, 5])
        }
    }

    @Test("bestEffort возвращает частичный результат")
    func bestEffortPartial() async {
        let r = await TaskGroupLesson.bestEffort([1, 13, 5])
        #expect(r.ok == [1, 5])
        #expect(r.failed == [13])
    }

    // MARK: Actor

    @Test("Исправленный кошелёк не уходит в минус при гонке")
    func fixedWalletNeverNegative() async {
        let wallet = ActorLesson.FixedWallet()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<10 { g.addTask { _ = await wallet.spend(30) } }
        }
        #expect(await wallet.current >= 0)
    }

    @Test("Баг reentrancy воспроизводится в BuggyWallet (документируем)")
    func buggyWalletShowsReentrancy() async {
        let wallet = ActorLesson.BuggyWallet()
        async let a = wallet.spend(80)
        async let b = wallet.spend(80)
        _ = await (a, b)
        #expect(await wallet.current < 0)       // баланс ушёл в минус: именно это и показываем
    }

    @Test("TokenManager делает ровно один refresh при 20 параллельных запросах")
    func singleRefresh() async throws {
        let calls = Counter()
        let manager = ActorLesson.TokenManager(
            initial: .init(value: "old", expiresAt: .distantPast),
            refresh: {
                await calls.increment()
                try await Task.sleep(for: .milliseconds(30))
                return .init(value: "new", expiresAt: .distantFuture)
            })
        let values = try await withThrowingTaskGroup(of: String.self) { g in
            for _ in 0..<20 { g.addTask { try await manager.validToken().value } }
            var all: [String] = []
            for try await v in g { all.append(v) }
            return all
        }
        #expect(values.allSatisfy { $0 == "new" })
        #expect(await calls.value == 1)
    }

    @Test("Downloader дедуплицирует одновременные запросы одного URL")
    func downloaderDedup() async throws {
        let dl = ActorLesson.Downloader()
        let url = URL(string: "https://example.com/x")!
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<10 { g.addTask { _ = try? await dl.data(for: url) } }
        }
        #expect(await dl.networkCalls == 1)
    }

    // MARK: Cancellation / Timeout

    @Test("withTimeout бросает TimeoutError, если операция зависла")
    func timeoutFires() async {
        await #expect(throws: CancellationLesson.TimeoutError.self) {
            try await CancellationLesson.withTimeout(.milliseconds(20)) {
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    @Test("withTimeout возвращает результат, если успели")
    func timeoutNotFired() async throws {
        let v = try await CancellationLesson.withTimeout(.seconds(1)) { 42 }
        #expect(v == 42)
    }

    @Test("Мост withTaskCancellationHandler: отмена Task отменяет legacy-запрос")
    func legacyBridgeCancels() async {
        let task = Task { try await CancellationLesson.fetchLegacy() }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    // MARK: TaskLocal

    @Test("TaskLocal наследуется структурными задачами, но не detached")
    func taskLocalInheritance() async {
        await TaskLocalLesson.Trace.$requestID.withValue("req-1") {
            let inherited = await Task { TaskLocalLesson.Trace.requestID }.value
            let detached = await Task.detached { TaskLocalLesson.Trace.requestID }.value
            #expect(inherited == "req-1")
            #expect(detached == nil)
        }
    }

    // MARK: ManualClock (детерминированное время)

    @Test("retry с ManualClock не тратит реальное время")
    func retryWithManualClock() async throws {
        let clock = TestingLesson.ManualClock()
        let attempts = Counter()
        let task = Task {
            try await TestingLesson.retry(attempts: 3, delay: .seconds(60), clock: clock) { () async throws -> String in
                if await attempts.increment() < 3 { throw URLError(.timedOut) }
                return "ok"
            }
        }
        // ждём, пока задача уснёт на часах (событие, а не время)
        while clock.sleeperCount == 0 { await Task.yield() }
        await clock.advance(by: .seconds(60))
        while clock.sleeperCount == 0 { await Task.yield() }
        await clock.advance(by: .seconds(60))
        #expect(try await task.value == "ok")
        #expect(await attempts.value == 3)
    }

    @MainActor
    @Test("Debounce ViewModel: отменяет устаревший ввод и срабатывает после паузы")
    func debounceViewModel() async {
        struct API: TestingLesson.SuggestionsAPI {
            func suggestions(for query: String) async throws -> [String] { [query + "!"] }
        }
        let clock = TestingLesson.ManualClock()
        let vm = TestingLesson.SuggestionsViewModel(api: API(), clock: clock, debounce: .milliseconds(300))

        vm.queryChanged("s")
        vm.queryChanged("sw")                                   // первая задача отменена
        while clock.sleeperCount == 0 { await Task.yield() }
        await clock.advance(by: .milliseconds(299))
        #expect(vm.state == .idle)                              // пауза ещё не прошла
        await clock.advance(by: .milliseconds(1))
        await vm.currentTask?.value
        #expect(vm.state == .loaded(["sw!"]))
    }
}

/// Простой счётчик для тестов (actor вместо @unchecked Sendable).
actor Counter {
    private(set) var value = 0
    @discardableResult func increment() -> Int { value += 1; return value }
}
