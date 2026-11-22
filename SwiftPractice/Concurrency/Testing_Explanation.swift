// ============================================================================
// Testing_Explanation.swift
// Тестирование async-кода: Clock как зависимость, свой ManualClock
// (аналог TestClock), тесты actor, AsyncStream, отмены, XCTest и Swift Testing
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: почему async-тесты бывают flaky и как этого избежать
//  2. Clock как зависимость
//  3. ManualClock: детерминированное время (свой TestClock)
//  4. Что тестировать: debounce, retry, таймаут — без реального ожидания
//  5. Тесты actor, AsyncStream, отмены
//  6. XCTest и Swift Testing: синтаксис
//  7. Production-пример: тестируемая ViewModel
//  8. Архитектурный анализ, ошибки, best practices
//
// Типы в неймспейсе `TestingLesson`. Сами тесты — в каталоге Tests/ репозитория.
// ============================================================================

import Foundation

enum TestingLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // Причины flaky-тестов с async:
    //  - реальное время: `sleep(0.5)` в тесте -> медленно и нестабильно на CI
    //  - гонки: тест проверяет состояние раньше, чем задача его записала
    //  - скрытые зависимости: Date(), UUID(), URLSession.shared, Task.sleep
    //  - общее состояние между тестами (singleton)
    //
    // Принципы:
    //  1. Время, случайность, идентификаторы, сеть — ЗАВИСИМОСТИ (DI).
    //  2. Ждём события, а не времени: await результата, а не sleep.
    //  3. Тест управляет временем сам (ManualClock.advance).
    //  4. Каждая проверка детерминирована; тест не зависит от порядка.

    // ========================================================================
    // 2. Clock КАК ЗАВИСИМОСТЬ
    // ========================================================================
    //
    // Протокол Clock (Swift 5.7+): `now`, `sleep(until:tolerance:)`,
    // associatedtype Instant/Duration. Реализации: ContinuousClock (идёт и
    // во сне устройства), SuspendingClock (не идёт во сне).
    //
    // Вместо Task.sleep(for:) пишем clock.sleep(for:) и ВНЕДРЯЕМ clock:
    // в production — ContinuousClock, в тестах — ManualClock.
    // Тип clock: `any Clock<Duration>` (primary associated types, 5.7+)
    // либо generic `<C: Clock<Duration>>`.

    struct Debouncer<C: Clock<Duration>>: Sendable {
        let clock: C
        let interval: Duration
        // см. Closures_Explanation/AsyncSequence_Explanation — идея та же
        func wait() async throws { try await clock.sleep(for: interval) }
    }

    // ========================================================================
    // 3. ManualClock — ТЕСТОВЫЕ ЧАСЫ
    // ========================================================================
    //
    // Время стоит, пока тест не вызвал `advance(by:)`. Все спящие задачи,
    // чей срок наступил, просыпаются. Реализация полностью детерминирована.
    // Готовое решение: пакет swift-clocks (Point-Free): TestClock,
    // ImmediateClock. Ниже — минимальная своя версия для понимания механики.

    final class ManualClock: Clock, @unchecked Sendable {
        struct Instant: InstantProtocol {
            var offset: Duration
            func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
            func duration(to other: Instant) -> Duration { other.offset - offset }
            static func < (l: Instant, r: Instant) -> Bool { l.offset < r.offset }
        }
        typealias Duration = Swift.Duration

        private struct Sleeper { let id: UUID; let deadline: Instant; let continuation: CheckedContinuation<Void, Error> }

        private let lock = NSLock()
        private var _now = Instant(offset: .zero)
        private var sleepers: [Sleeper] = []
        // Отмена может прийти ДО регистрации спящего (onCancel срабатывает
        // сразу, если Task уже отменена). Запоминаем такие id, иначе задача
        // проспит до advance() — настоящий баг, который поймал юнит-тест.
        private var cancelledBeforeRegistration: Set<UUID> = []

        var now: Instant { lock.withLock { _now } }
        var minimumResolution: Duration { .zero }

        func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    enum Outcome { case registered, due, cancelled }
                    let outcome: Outcome = lock.withLock {
                        if cancelledBeforeRegistration.remove(id) != nil { return .cancelled }
                        if deadline <= _now { return .due }
                        sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                        return .registered
                    }
                    switch outcome {
                    case .registered: break
                    case .due: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                // Отмена: достаём конкретного спящего и будим с CancellationError
                let found: Sleeper? = lock.withLock {
                    guard let i = sleepers.firstIndex(where: { $0.id == id }) else {
                        cancelledBeforeRegistration.insert(id)   // ещё не зарегистрировался
                        return nil
                    }
                    return sleepers.remove(at: i)
                }
                found?.continuation.resume(throwing: CancellationError())
            }
        }

        /// Сдвинуть время и разбудить всех, чей дедлайн наступил (по порядку).
        func advance(by duration: Duration) async {
            let due: [Sleeper] = lock.withLock {
                _now = _now.advanced(by: duration)
                let ready = sleepers.filter { $0.deadline <= _now }.sorted { $0.deadline < $1.deadline }
                sleepers.removeAll { s in ready.contains { $0.id == s.id } }
                return ready
            }
            due.forEach { $0.continuation.resume() }
            await Task.yield()                  // даём разбуженным задачам исполниться
            await Task.yield()
        }

        /// Сколько задач сейчас спит — удобно в проверках.
        var sleeperCount: Int { lock.withLock { sleepers.count } }
    }

    // ========================================================================
    // 4. ЧТО ТЕСТИРУЕМ БЕЗ РЕАЛЬНОГО ОЖИДАНИЯ
    // ========================================================================

    /// retry с паузами между попытками — зависит от Clock, не от Task.sleep.
    static func retry<T: Sendable, C: Clock<Duration>>(
        attempts: Int, delay: Duration, clock: C,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<attempts {
            do { return try await operation() }
            catch {
                lastError = error
                if attempt < attempts - 1 { try await clock.sleep(for: delay) }
            }
        }
        throw lastError ?? CancellationError()
    }

    /// Таймаут на Clock: тест "operation зависла" занимает 0 мс реального времени.
    static func timeout<T: Sendable, C: Clock<Duration>>(
        after duration: Duration, clock: C,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await clock.sleep(for: duration); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // ========================================================================
    // 5. ТЕСТЫ ACTOR, ASYNCSTREAM, ОТМЕНЫ
    // ========================================================================
    //
    // ACTOR: тестируй как обычный объект, но через await. Для гонок —
    //   запусти N конкурентных вызовов через TaskGroup и проверь инвариант.
    //
    // ASYNCSTREAM: подставь источник через makeStream(): тест вручную
    //   `yield`'ит события и читает результат. Для "первых N событий"
    //   используй `.prefix(n)`, чтобы цикл завершился.
    //
    // ОТМЕНА: запусти Task, отмени, `await task.value` (или result),
    //   проверь состояние и освобождение ресурсов.
    //
    // ЖДАТЬ УСЛОВИЕ без sleep: приём "ждать значение из потока":
    static func firstElement<S: AsyncSequence>(of sequence: S, where predicate: (S.Element) -> Bool) async throws -> S.Element? {
        for try await e in sequence where predicate(e) { return e }
        return nil
    }

    // ========================================================================
    // 6. XCTest И SWIFT TESTING — СИНТАКСИС
    // ========================================================================
    //
    // XCTest (async-тесты поддерживаются):
    //
    //   final class RetryTests: XCTestCase {
    //       func testRetriesThenSucceeds() async throws {
    //           let clock = ManualClock()
    //           let counter = Counter()
    //           async let result = TestingLesson.retry(attempts: 3, delay: .seconds(1), clock: clock) {
    //               if await counter.next() < 3 { throw TestError.fail }
    //               return "ok"
    //           }
    //           await clock.advance(by: .seconds(1))     // первая пауза
    //           await clock.advance(by: .seconds(1))     // вторая пауза
    //           let value = try await result
    //           XCTAssertEqual(value, "ok")
    //       }
    //   }
    //
    // Swift Testing (Xcode 16+, `import Testing`):
    //
    //   @Suite struct RetryTests {
    //       @Test func retriesThenSucceeds() async throws { ... #expect(value == "ok") }
    //       @Test(arguments: [1, 2, 3]) func parametrized(n: Int) { #expect(n > 0) }
    //   }
    //   Плюсы: параметризация, теги, параллельный запуск по умолчанию,
    //   `#expect`/`#require`, `confirmation` для событий, `.timeLimit`.
    //   (см. каталог Tests/ — там оба стиля)
    //
    // ЖДАТЬ СОБЫТИЯ:
    //   XCTest: XCTestExpectation + `await fulfillment(of:timeout:)`.
    //   Swift Testing: `await confirmation { confirm in ... confirm() }`.
    //
    // MAIN ACTOR: тест, обращающийся к @MainActor-типу, сам помечай
    //   `@MainActor` (`@MainActor func test...`).

    // ========================================================================
    // 7. PRODUCTION-ПРИМЕР: тестируемая ViewModel
    // ========================================================================
    //
    // Что делает VM тестируемой:
    //   - все зависимости через init (репозиторий-протокол, Clock)
    //   - состояние — наблюдаемое значение (enum), а не побочные эффекты
    //   - нет Task.sleep / Date() / URLSession.shared внутри
    //   - `Task` хранится -> тест может её дождаться (`await vm.currentTask?.value`)

    protocol SuggestionsAPI: Sendable { func suggestions(for query: String) async throws -> [String] }

    @MainActor
    final class SuggestionsViewModel {
        enum State: Equatable { case idle, loading, loaded([String]), failed }
        private(set) var state: State = .idle
        private(set) var currentTask: Task<Void, Never>?

        private let api: any SuggestionsAPI
        private let clock: any Clock<Duration>
        private let debounce: Duration

        init(api: any SuggestionsAPI, clock: any Clock<Duration>, debounce: Duration = .milliseconds(300)) {
            self.api = api; self.clock = clock; self.debounce = debounce
        }

        func queryChanged(_ query: String) {
            currentTask?.cancel()                          // новая замена старой
            guard !query.isEmpty else { state = .idle; return }
            currentTask = Task { [api, clock, debounce] in
                do {
                    try await clock.sleep(for: debounce)   // debounce на ВНЕДРЁННЫХ часах
                    state = .loading
                    state = .loaded(try await api.suggestions(for: query))
                } catch is CancellationError {
                    // устарел — молча
                } catch {
                    state = .failed
                }
            }
        }
    }

    // Тест (псевдокод):
    //   let clock = ManualClock()
    //   let vm = SuggestionsViewModel(api: StubAPI(), clock: clock)
    //   vm.queryChanged("sw")
    //   vm.queryChanged("swi")                       // отменяет первую
    //   await clock.advance(by: .milliseconds(299))
    //   XCTAssertEqual(vm.state, .idle)              // debounce ещё не истёк
    //   await clock.advance(by: .milliseconds(1))
    //   await vm.currentTask?.value
    //   XCTAssertEqual(vm.state, .loaded([...]))     // 0 мс реального времени

    // ========================================================================
    // 8. АРХИТЕКТУРНЫЙ АНАЛИЗ, ОШИБКИ, BEST PRACTICES
    // ========================================================================
    //
    // ПИРАМИДА: много быстрых юнит-тестов бизнес-логики (struct/reducer/UseCase),
    //   меньше — ViewModel с подменой зависимостей, мало — интеграционные/UI.
    //
    // ВНЕДРЯЙ КАК ЗАВИСИМОСТЬ: Clock, Date/UUID-генераторы, сеть (протокол),
    //   хранилище, аналитика, Random.
    //
    // ПЛЮСЫ ManualClock: скорость (0 мс), детерминизм, возможность тестировать
    //   длинные таймауты (минуты) мгновенно, проверка точных границ.
    // МИНУСЫ: нужна дисциплина DI; Clock в сигнатурах/generic'ах;
    //   `any Clock<Duration>` — existential (мелкая цена).
    //
    // ОШИБКИ:
    //  1. `try await Task.sleep` в тесте "чтобы дождаться".
    //  2. Проверка состояния без ожидания завершения задачи -> гонка.
    //  3. Singleton'ы и глобальное состояние между тестами.
    //  4. Тест, зависящий от реальной сети.
    //  5. Не вызвали advance -> тест висит вечно (ставь `.timeLimit`).
    //  6. Проверка точного порядка, который не гарантирован (TaskGroup).
    //  7. Забыли @MainActor на тесте для @MainActor-типа.
    //  8. @unchecked Sendable в тестовых двойниках без реальной защиты
    //     (используй actor или Mutex).
    //
    // BEST PRACTICES:
    //  - Тестовые двойники: Stub (отдаёт данные), Spy (запоминает вызовы),
    //    Fake (рабочая упрощённая реализация), Mock (проверяет ожидания)
    //  - Один тест — одно поведение; имена `test_<что>_<когда>_<ожидание>`
    //  - Не тестируй приватное; тестируй наблюдаемое поведение
    //  - Тестируй отмену, ошибки и граничные случаи наряду с happy path
    //  - Прогоняй с Thread Sanitizer и `-strict-concurrency=complete`

    static func run() async throws {
        let clock = ManualClock()
        let task = Task { try await retry(attempts: 2, delay: .seconds(5), clock: clock) { () async throws -> String in
            throw URLError(.cannotFindHost) } }
        try? await Task.sleep(for: .milliseconds(20))      // даём задаче уснуть на ManualClock
        await clock.advance(by: .seconds(5))
        _ = try? await task.value
        print("спящих:", clock.sleeperCount)               // 0
    }
}
