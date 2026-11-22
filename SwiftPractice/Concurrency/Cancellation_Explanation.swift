// ============================================================================
// Cancellation_Explanation.swift
// Отмена задач: кооперативная модель, withTaskCancellationHandler,
// таймауты и дедлайны, очистка ресурсов, отмена в AsyncStream
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: кооперативная отмена
//  2. Как проверять отмену
//  3. withTaskCancellationHandler: мост отмены к не-async API
//  4. Таймауты и дедлайны (гонка двух задач)
//  5. Очистка ресурсов, shield (защита критической секции)
//  6. Отмена и AsyncStream / URLSession / continuation
//  7. Production-пример: загрузка файла с таймаутом, отменой и retry
//  8. Архитектурный анализ, ошибки, best practices
//
// Типы в неймспейсе `CancellationLesson`.
// ============================================================================

import Foundation

enum CancellationLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // `task.cancel()` НЕ останавливает код. Он лишь ставит флаг isCancelled в
    // задаче и во ВСЕХ её дочерних (структурно). Задача должна сама
    // периодически проверять флаг и завершаться. Это КООПЕРАТИВНАЯ отмена.
    //
    // Почему так: принудительная остановка посреди кода оставила бы
    // неосвобождённые ресурсы, блокировки, полузаписанные данные.
    //
    // Что реагирует на отмену САМО:
    //   Task.sleep, URLSession.data/bytes, AsyncStream-итерация,
    //   withTaskGroup.next() и большинство async-API Apple.
    // Что НЕ реагирует:
    //   ваши циклы вычислений, синхронный код, блокирующие вызовы.
    //
    // Отмена — не обязательно ошибка. Решаете вы: бросить CancellationError
    // или вернуть частичный результат.

    // ========================================================================
    // 2. КАК ПРОВЕРЯТЬ ОТМЕНУ
    // ========================================================================

    static func checkingDemo() async {
        let task = Task {
            var processed = 0
            for i in 1...1_000_000 {
                // (A) Бросающая проверка: удобна внутри throws-функций
                try Task.checkCancellation()                 // кидает CancellationError

                // (B) Флаг: если нужно вернуть частичный результат
                // if Task.isCancelled { return processed }

                // (C) Уступить поток: даёт шанс другим задачам и отмене
                if i % 1000 == 0 { await Task.yield() }
                processed += 1
            }
            return processed
        }
        try? await Task.sleep(for: .milliseconds(5))
        task.cancel()
        do { _ = try await task.value } catch { print("отменено:", error is CancellationError) }
    }

    // Частота проверок: в горячем цикле проверяй не на каждой итерации, а
    // каждые N (стоимость проверки мала, но не нулевая).

    // Статический доступ: `Task.isCancelled` работает внутри любого async-
    // контекста для ТЕКУЩЕЙ задачи. У экземпляра задачи — `task.isCancelled`.

    // ========================================================================
    // 3. withTaskCancellationHandler
    // ========================================================================
    //
    // Нужен, когда внутри задачи ждёшь что-то, что само не знает про отмену:
    // старый callback-API, сокет, NSOperation, DispatchWorkItem, continuation.
    // `onCancel` вызывается НЕМЕДЛЕННО при отмене, на ПРОИЗВОЛЬНОМ потоке,
    // параллельно с `operation` -> код в onCancel должен быть потокобезопасным.

    /// Старый API с возможностью отмены.
    final class LegacyRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var handler: ((Result<String, Error>) -> Void)?

        func start(_ completion: @escaping (Result<String, Error>) -> Void) {
            lock.withLock { handler = completion }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                finish(.success("данные"))
            }
        }
        func cancel() { finish(.failure(CancellationError())) }

        private func finish(_ result: Result<String, Error>) {
            // Вызываем handler РОВНО ОДИН раз: забираем и обнуляем под замком
            let h: ((Result<String, Error>) -> Void)? = lock.withLock {
                defer { handler = nil }
                return handler
            }
            h?(result)
        }
    }

    /// Мост: отмена Task -> cancel() старого API; continuation резюмируется
    /// ровно один раз (либо результатом, либо ошибкой отмены).
    static func fetchLegacy() async throws -> String {
        let request = LegacyRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.start { continuation.resume(with: $0) }
            }
        } onCancel: {
            request.cancel()               // потокобезопасно; приведёт к resume(.failure)
        }
    }

    // ВАЖНО: если Task уже отменена ДО входа в withTaskCancellationHandler,
    // onCancel вызывается сразу при входе — учитывай это в своём API.

    // ========================================================================
    // 4. ТАЙМАУТЫ И ДЕДЛАЙНЫ
    // ========================================================================
    //
    // В стандартной библиотеке нет `withTimeout`. Реализуем как ГОНКУ двух
    // дочерних задач в группе: работа vs таймер. Кто первым закончил — тот
    // и результат; вторую отменяем.

    struct TimeoutError: Error, Equatable {}

    static func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TimeoutError()                      // таймер сработал первым
            }
            // Берём ПЕРВЫЙ завершившийся результат (или ошибку)
            defer { group.cancelAll() }                   // отменяем проигравшую
            guard let first = try await group.next() else { throw TimeoutError() }
            return first
        }
    }
    // Работает, только если operation РЕАГИРУЕТ на отмену. Если внутри
    // блокирующий код — таймаут не сработает: группа дождётся завершения всех
    // детей. Поэтому в operation используй отменяемые API.

    /// Дедлайн — абсолютный момент, а не длительность. Общий бюджет времени
    /// на ВСЮ цепочку операций (а не на каждую по отдельности).
    struct Deadline: Sendable {
        let instant: ContinuousClock.Instant
        init(after duration: Duration) { instant = .now + duration }
        var remaining: Duration { instant - .now }
        var isExpired: Bool { remaining <= .zero }
        func check() throws { if isExpired { throw TimeoutError() } }
    }

    static func pipeline(deadline: Deadline) async throws -> String {
        try deadline.check()
        let a = try await withTimeout(deadline.remaining) { try await step("A") }
        try deadline.check()
        let b = try await withTimeout(deadline.remaining) { try await step("B") }
        return a + b                                  // оба шага делят ОДИН бюджет
    }
    static func step(_ name: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(20)); return name
    }

    // URLSession имеет собственные таймауты (timeoutIntervalForRequest/Resource);
    // withTimeout нужен для произвольной async-логики (БД, цепочки, SDK).

    // ========================================================================
    // 5. ОЧИСТКА РЕСУРСОВ И ЗАЩИТА КРИТИЧЕСКИХ СЕКЦИЙ
    // ========================================================================

    // defer выполняется и при отмене (CancellationError — обычный throw).
    static func withTempFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }   // уберём в любом случае
        try await Task.sleep(for: .seconds(1))                   // тут может прилететь отмена
    }

    // Критическая секция, которую НЕЛЬЗЯ прерывать (запись транзакции):
    // выполни её в НЕОТМЕНЯЕМОЙ задаче. Task { } НЕ наследует отмену родителя
    // (в отличие от дочерних); но если дождаться `.value` из отменённого
    // родителя, сам await вернётся только после завершения.
    static func commitTransaction() async {
        await Task {                                   // неструктурная: отмена родителя не передаётся
            // запись на диск / атомарная операция
            try? await Task.sleep(for: .milliseconds(5))
        }.value
    }
    // Не злоупотребляй: потеря отмены = зависшие задачи. Применяй для
    // коротких атомарных операций.

    // ========================================================================
    // 6. ОТМЕНА И ПОТОКИ / CONTINUATION
    // ========================================================================

    // AsyncStream: отмена потребителя -> onTermination(.cancelled) у источника.
    static func cancellableStream() -> AsyncStream<Int> {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let producer = Task {
            var i = 0
            while !Task.isCancelled {
                continuation.yield(i); i += 1
                try? await Task.sleep(for: .milliseconds(10))
            }
            continuation.finish()
        }
        continuation.onTermination = { reason in
            print("поток закрыт:", reason)
            producer.cancel()                         // отмена потребителя -> стоп производителя
        }
        return stream
    }

    static func streamDemo() async {
        let consumer = Task {
            for await value in cancellableStream() where value >= 3 { break }   // break = отмена
        }
        await consumer.value
    }

    // Continuation: НИКОГДА не оставляй без resume при отмене — задача
    // зависнет навсегда. Всегда связывай с withTaskCancellationHandler (п. 3).

    // ========================================================================
    // 7. PRODUCTION-ПРИМЕР: загрузка с таймаутом, отменой и retry
    // ========================================================================
    //
    //  ViewModel.start()  ──▶ Task (хранится)  ──▶ Downloader.download()
    //     │                                           │
    //     └─ cancel() при уходе с экрана ◀── withTimeout + retry + checkCancellation

    struct DownloadError: Error { let message: String }

    protocol Transport: Sendable { func fetch(_ attempt: Int) async throws -> Data }

    struct Downloader: Sendable {
        let transport: any Transport
        let timeout: Duration
        let maxAttempts: Int

        func download() async throws -> Data {
            var lastError: Error = DownloadError(message: "нет попыток")
            for attempt in 1...maxAttempts {
                try Task.checkCancellation()               // не начинаем новую попытку после отмены
                do {
                    return try await CancellationLesson.withTimeout(timeout) {
                        try await transport.fetch(attempt)
                    }
                } catch is CancellationError {
                    throw CancellationError()              // отмену НЕ ретраим
                } catch {
                    lastError = error
                    // экспоненциальный backoff; Task.sleep сам бросит при отмене
                    try await Task.sleep(for: .milliseconds(10 * (1 << attempt)))
                }
            }
            throw lastError
        }
    }

    struct FlakyTransport: Transport {
        func fetch(_ attempt: Int) async throws -> Data {
            if attempt < 3 { try await Task.sleep(for: .seconds(5)) }   // зависает -> таймаут
            return Data("ok".utf8)
        }
    }

    @MainActor
    final class DownloadViewModel {
        enum State: Equatable { case idle, loading, done(Int), failed(String), cancelled }
        private(set) var state: State = .idle
        private var task: Task<Void, Never>?
        private let downloader: Downloader
        init(downloader: Downloader) { self.downloader = downloader }

        func start() {
            task?.cancel()
            state = .loading
            task = Task {
                do {
                    let data = try await downloader.download()
                    state = .done(data.count)
                } catch is CancellationError {
                    state = .cancelled                    // не показываем как ошибку
                } catch {
                    state = .failed("\(error)")
                }
            }
        }
        func cancel() { task?.cancel() }
        deinit { task?.cancel() }
    }

    // ========================================================================
    // 8. АРХИТЕКТУРНЫЙ АНАЛИЗ, ОШИБКИ, BEST PRACTICES
    // ========================================================================
    //
    // ПРИНЦИПЫ:
    //  - Каждая долгая async-операция должна быть отменяемой и очищать за собой.
    //  - Владелец хранит Task и отменяет её (deinit / смена входных данных /
    //    уход с экрана). В SwiftUI `.task {}` делает это сам.
    //  - Отмена — штатный путь: не логируй как ошибку, не показывай алерт.
    //  - Таймаут и дедлайн — свойства политики (Downloader), не бизнес-логики.
    //
    // ВЫБОР:
    //  таймаут одной операции  -> withTimeout(duration)
    //  общий бюджет цепочки    -> Deadline
    //  сетевой запрос          -> URLSession timeouts + отмена Task
    //  старый callback API     -> withTaskCancellationHandler + continuation
    //
    // ОШИБКИ:
    //  1. Думать, что cancel() прервёт код: нужны проверки.
    //  2. Ретраить после отмены (бесконечные "зомби"-попытки).
    //  3. withCheckedContinuation без обработки отмены -> зависание.
    //  4. Двойной resume в onCancel + в успехе -> crash. Нужна защита
    //     "ровно один раз" (замок, как в LegacyRequest).
    //  5. Таймаут вокруг блокирующего (неотменяемого) кода — не сработает.
    //  6. Забытая Task в свойстве без cancel -> работа после закрытия экрана.
    //  7. Показ "Ошибка" на CancellationError / URLError.cancelled.
    //  8. Тяжёлый цикл без checkCancellation/yield.
    //  9. Использование Task.detached «чтобы не отменялось» без причины.
    //
    // BEST PRACTICES:
    //  - checkCancellation на границах шагов и в горячих циклах (каждые N)
    //  - `defer` для освобождения ресурсов
    //  - в onCancel — только быстрые потокобезопасные действия
    //  - тесты отмены: стартуй, отмени, проверь, что ресурсы освобождены и
    //    состояние = .cancelled (см. Testing_Explanation)

    static func run() async throws {
        await checkingDemo()
        print((try? await fetchLegacy()) ?? "—")

        let legacy = Task { try await fetchLegacy() }
        legacy.cancel()
        print("legacy cancel:", (try? await legacy.value) == nil)

        do { _ = try await withTimeout(.milliseconds(20)) { try await Task.sleep(for: .seconds(1)) } }
        catch { print("таймаут:", error is TimeoutError) }

        print(try await pipeline(deadline: Deadline(after: .seconds(1))))
        await streamDemo()

        let downloader = Downloader(transport: FlakyTransport(), timeout: .milliseconds(30), maxAttempts: 3)
        print((try await downloader.download()).count)
    }
}
