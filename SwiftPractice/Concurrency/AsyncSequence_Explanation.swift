// ============================================================================
// AsyncSequence_Explanation.swift
// Свои AsyncSequence/AsyncIteratorProtocol, операторы (map/debounce/chunk/
// merge) своими руками, swift-async-algorithms, мосты Combine <-> async
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: AsyncSequence и AsyncIteratorProtocol
//  2. Своя последовательность (pull-модель)
//  3. Встроенные операторы и ограничения
//  4. Операторы своими руками: debounce, throttle, chunked, merge
//  5. swift-async-algorithms: что даёт пакет и как подключить
//  6. Мосты: Combine <-> AsyncSequence, KVO/NotificationCenter -> async
//  7. Production-пример: пагинация + автопоиск как последовательности
//  8. Архитектурный анализ, ошибки, best practices
//
// Типы в неймспейсе `AsyncSequenceLesson`.
// ============================================================================

import Foundation
import Combine

enum AsyncSequenceLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // Sequence:       for x in seq { }       — next() синхронный
    // AsyncSequence:  for await x in seq { } — next() async (и может throws)
    //
    // Протоколы:
    //   protocol AsyncSequence { associatedtype Element; associatedtype AsyncIterator: AsyncIteratorProtocol
    //                            func makeAsyncIterator() -> AsyncIterator }
    //   protocol AsyncIteratorProtocol { mutating func next() async throws -> Element? }
    //
    // `next()` возвращает nil — конец. Бросает — конец с ошибкой.
    // Это PULL-модель: потребитель просит следующий элемент, производитель
    // отвечает, когда готов => естественный backpressure (в отличие от
    // PUSH-источников вроде callback, где нужен буфер — AsyncStream).
    //
    // `for await` = makeAsyncIterator() + цикл по next(). Отмена Task -> next()
    // должен вернуться (nil или throw) — реализуй поддержку отмены.

    // ========================================================================
    // 2. СВОЯ ПОСЛЕДОВАТЕЛЬНОСТЬ
    // ========================================================================

    /// Обратный отсчёт: каждые `interval` выдаёт число.
    struct Countdown: AsyncSequence {
        typealias Element = Int
        let from: Int
        let interval: Duration

        struct AsyncIterator: AsyncIteratorProtocol {
            var current: Int
            let interval: Duration

            mutating func next() async throws -> Int? {
                guard current > 0 else { return nil }             // конец
                try await Task.sleep(for: interval)               // бросит при отмене -> цикл завершится
                defer { current -= 1 }
                return current
            }
        }
        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(current: from, interval: interval) }
    }

    static func countdownDemo() async throws {
        for try await n in Countdown(from: 3, interval: .milliseconds(5)) { print(n) }   // 3 2 1
    }

    /// Пагинация как последовательность: «страница за страницей» по требованию.
    /// Загружаем следующую страницу ТОЛЬКО когда потребитель запросил элемент.
    struct Paged<Item: Sendable>: AsyncSequence {
        typealias Element = [Item]
        let fetch: @Sendable (_ page: Int) async throws -> [Item]     // пустая страница = конец

        struct AsyncIterator: AsyncIteratorProtocol {
            let fetch: @Sendable (Int) async throws -> [Item]
            var page = 0
            var finished = false
            mutating func next() async throws -> [Item]? {
                guard !finished else { return nil }
                try Task.checkCancellation()
                let items = try await fetch(page)
                if items.isEmpty { finished = true; return nil }
                page += 1
                return items
            }
        }
        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(fetch: fetch) }
    }

    static func pagedDemo() async throws {
        let paged = Paged<Int> { page in page < 3 ? Array((page * 2)..<(page * 2 + 2)) : [] }
        for try await chunk in paged { print("страница:", chunk) }
        // Ранний выход (`break`/`prefix`) -> следующие страницы НЕ грузятся.
    }

    // Проще: AsyncStream(unfolding:) / AsyncThrowingStream(unfolding:) когда не
    // нужен собственный тип; собственный тип — когда нужны Sendable-конформанс,
    // конфигурация и переиспользование.

    // ========================================================================
    // 3. ВСТРОЕННЫЕ ОПЕРАТОРЫ
    // ========================================================================
    //
    // В stdlib для AsyncSequence есть: map, filter, compactMap, flatMap(*),
    // prefix, drop(while:), first(where:), contains, reduce, min/max,
    // allSatisfy. НЕТ: debounce, throttle, merge, zip, combineLatest,
    // chunked, removeDuplicates — они в swift-async-algorithms (п. 5).

    static func builtinOperators() async {
        let numbers = AsyncStream<Int> { c in (1...10).forEach { c.yield($0) }; c.finish() }
        let result = await numbers
            .filter { $0 % 2 == 0 }
            .map { $0 * 10 }
            .prefix(3)                                   // 20 40 60, остальное не читаем
            .reduce(into: [Int]()) { $0.append($1) }
        print(result)
    }

    // ========================================================================
    // 4. ОПЕРАТОРЫ СВОИМИ РУКАМИ
    // ========================================================================
    // Цель: понять, как устроены операторы времени, и когда писать свои.

    /// Актор-хранилище "ожидающей" задачи для debounce.
    actor DebounceState {
        private var pending: Task<Void, Never>?
        func replace(with task: Task<Void, Never>) { pending?.cancel(); pending = task }
        func waitPending() async { await pending?.value }
        func cancel() { pending?.cancel() }
    }

    /// debounce: выдаёт элемент, только если за `interval` не пришло нового.
    /// Применение: поиск по мере ввода. Clock — параметр => тестируется
    /// ManualClock без реального ожидания (см. Testing_Explanation).
    static func debounce<S: AsyncSequence & Sendable, C: Clock>(
        _ source: S, for interval: C.Duration, clock: C
    ) -> AsyncStream<S.Element> where S.Element: Sendable {
        let (stream, continuation) = AsyncStream<S.Element>.makeStream()
        let state = DebounceState()

        let upstream = Task {
            do {
                for try await element in source {
                    // Новый элемент отменяет предыдущий "таймер"
                    await state.replace(with: Task {
                        try? await clock.sleep(for: interval)
                        if !Task.isCancelled { continuation.yield(element) }
                    })
                }
            } catch { /* ошибка источника: завершаем поток */ }
            await state.waitPending()                    // дожидаемся последнего элемента
            continuation.finish()
        }
        continuation.onTermination = { _ in
            upstream.cancel()
            Task { await state.cancel() }
        }
        return stream
    }

    /// chunked(by: n) — группировка в пачки (батч-запись в БД, батч-аналитика).
    struct Chunked<Base: AsyncSequence>: AsyncSequence {
        typealias Element = [Base.Element]
        let base: Base
        let size: Int

        struct AsyncIterator: AsyncIteratorProtocol {
            var base: Base.AsyncIterator
            let size: Int
            mutating func next() async throws -> [Base.Element]? {
                var chunk: [Base.Element] = []
                while chunk.count < size, let element = try await base.next() { chunk.append(element) }
                return chunk.isEmpty ? nil : chunk       // хвост меньше size отдаём как есть
            }
        }
        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: base.makeAsyncIterator(), size: size) }
    }

    /// merge двух последовательностей одного типа: элементы по мере готовности.
    static func merge<A: AsyncSequence & Sendable, B: AsyncSequence & Sendable>(
        _ a: A, _ b: B
    ) -> AsyncStream<A.Element> where A.Element == B.Element, A.Element: Sendable {
        let (stream, continuation) = AsyncStream<A.Element>.makeStream()
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { do { for try await x in a { continuation.yield(x) } } catch {} }
                group.addTask { do { for try await x in b { continuation.yield(x) } } catch {} }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    static func operatorsDemo() async throws {
        let chunks = Chunked(base: AsyncStream<Int> { c in (1...5).forEach { c.yield($0) }; c.finish() }, size: 2)
        for try await chunk in chunks { print("chunk:", chunk) }            // [1,2] [3,4] [5]

        let a = AsyncStream<Int> { c in c.yield(1); c.finish() }
        let b = AsyncStream<Int> { c in c.yield(2); c.finish() }
        var merged: [Int] = []
        for await x in merge(a, b) { merged.append(x) }
        print(merged.sorted())
    }

    // ========================================================================
    // 5. swift-async-algorithms (apple/swift-async-algorithms)
    // ========================================================================
    //
    // Официальный пакет Apple. Подключение (Package.swift):
    //   .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0")
    //   .product(name: "AsyncAlgorithms", package: "swift-async-algorithms")
    //   import AsyncAlgorithms
    //
    // Что даёт (тот же смысл, что наши самописные версии, но проверено):
    //   debounce(for:)            throttle(for:reducing:)
    //   merge(_:_:)               zip(_:_:)        combineLatest(_:_:)
    //   chunks(ofCount:) / chunked(by:) / chunked(byCount:andTime:)
    //   removeDuplicates()        adjacentPairs()    compacted()
    //   AsyncChannel<Element>     — канал с backpressure (send ЖДЁТ потребителя)
    //   AsyncThrowingChannel
    //   joined(), interspersed(with:), lazy
    //   Timer-последовательности: `AsyncTimerSequence.repeating(every:)`
    //
    // Пример использования (в проекте с пакетом):
    //   for await query in queryStream.debounce(for: .milliseconds(300)).removeDuplicates() {
    //       await search(query)
    //   }
    //
    // AsyncChannel vs AsyncStream:
    //   AsyncStream  — producer НЕ ждёт (буфер/потеря по политике)
    //   AsyncChannel — producer ЖДЁТ потребителя (настоящий backpressure)
    // Выбирай Channel, когда терять нельзя и производитель умеет ждать.
    //
    // Когда писать свой оператор: нужна специфичная семантика или нельзя
    // добавлять зависимость. Иначе — пакет.

    // ========================================================================
    // 6. МОСТЫ
    // ========================================================================

    /// Combine -> async: `.values` превращает любой Publisher в AsyncSequence.
    /// Failure = Never -> `for await`; иначе `for try await`.
    static func combineToAsync() async {
        let subject = PassthroughSubject<Int, Never>()
        let consumer = Task {
            var collected: [Int] = []
            for await v in subject.values { collected.append(v); if collected.count == 2 { break } }
            return collected
        }
        try? await Task.sleep(for: .milliseconds(20))      // даём подписаться
        subject.send(1); subject.send(2)
        print(await consumer.value)
    }

    /// async -> Combine: через Subject (hot) или Future (одно значение).
    static func asyncToCombine<S: AsyncSequence & Sendable>(_ seq: S) -> AnyPublisher<S.Element, Error>
    where S.Element: Sendable {
        let subject = PassthroughSubject<S.Element, Error>()
        let task = Task {
            do { for try await x in seq { subject.send(x) }; subject.send(completion: .finished) }
            catch { subject.send(completion: .failure(error)) }
        }
        return subject.handleEvents(receiveCancel: { task.cancel() }).eraseToAnyPublisher()
    }

    /// NotificationCenter уже даёт AsyncSequence:
    static func notificationsDemo() -> Task<Void, Never> {
        Task {
            let name = Notification.Name("DemoEvent")
            for await note in NotificationCenter.default.notifications(named: name) {
                print("получено:", note.name.rawValue)
                break
            }
        }
    }

    // ========================================================================
    // 7. PRODUCTION-ПРИМЕР: автопоиск + ленивая пагинация
    // ========================================================================
    //
    //   ввод пользователя ─▶ AsyncStream<String> ─▶ debounce ─▶ уникальные
    //                                                          │
    //                                    для каждого запроса ──▶ Paged<Result> (страницы по требованию)
    //
    // Принципы: UI-слой выставляет события (yield), слушатель — одна Task,
    // отмена Task при смене экрана гасит всю цепочку.

    struct SearchEngine: Sendable {
        let search: @Sendable (_ query: String, _ page: Int) async throws -> [String]

        func results(for query: String) -> Paged<String> {
            Paged { page in try await search(query, page) }
        }
    }

    @MainActor
    final class SearchModel {
        private(set) var results: [String] = []
        private(set) var currentQuery = ""
        private let input: AsyncStream<String>.Continuation
        private var listener: Task<Void, Never>?

        init(engine: SearchEngine, debounce interval: Duration = .milliseconds(250)) {
            let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
            input = continuation
            listener = Task { [weak self] in
                let debounced = AsyncSequenceLesson.debounce(stream, for: interval, clock: ContinuousClock())
                var lastQuery: String?
                for await query in debounced where query != lastQuery {   // removeDuplicates вручную
                    lastQuery = query
                    guard let self else { return }
                    self.currentQuery = query
                    self.results = []
                    do {
                        // Берём только первые 2 страницы: prefix — лениво, остальные не грузятся
                        for try await page in engine.results(for: query).prefix(2) {
                            self.results += page
                        }
                    } catch { /* показать ошибку в state */ }
                }
            }
        }

        func textChanged(_ text: String) { input.yield(text) }          // вызывается из UI
        func stop() { input.finish(); listener?.cancel() }
        deinit { listener?.cancel() }
    }

    // ========================================================================
    // 8. АРХИТЕКТУРНЫЙ АНАЛИЗ, ОШИБКИ, BEST PRACTICES
    // ========================================================================
    //
    // ВЫБОР:
    //   Один результат                        -> async функция
    //   Поток событий (push) от callback/SDK  -> AsyncStream
    //   Лениво генерируемые данные (pull)     -> собственный AsyncSequence /
    //                                            AsyncStream(unfolding:)
    //   Операторы времени/комбинирования      -> swift-async-algorithms
    //   Много подписчиков, горячий поток      -> Combine / hub (см. AsyncStream)
    //   Нужен backpressure без потерь         -> AsyncChannel
    //
    // ПЛЮСЫ: линейный код, отмена по Task, backpressure в pull-модели,
    //   композиция операторов, нет retain cycle через замыкания подписки.
    // МИНУСЫ: одноразовые (итератор — одноразовый, "горячие" источники
    //   делят элементы), нет встроенных time-операторов, больше шаблонного
    //   кода для кастомных типов, Sendable-ограничения на generic'и.
    //
    // ОШИБКИ:
    //  1. Два `for await` по одному AsyncStream — элементы делятся.
    //  2. Итератор не реагирует на отмену -> цикл не завершается.
    //  3. Не завершён поток (finish) -> for await висит вечно.
    //  4. Обычный `Task.sleep` внутри next() без проверки отмены — ok, он
    //     бросает; но синхронный цикл — нет.
    //  5. Утечка: Task слушателя удерживает self -> [weak self] + guard
    //     ВНУТРИ цикла.
    //  6. Хранить состояние итератора в самой Sequence (она может
    //     итерироваться повторно) — состояние только в Iterator.
    //  7. Игнорировать ошибки источника в merge/debounce — продумай политику.
    //
    // BEST PRACTICES:
    //  - Итератор = состояние; Sequence = конфигурация (immutable, Sendable)
    //  - Clock как параметр для тестируемых time-операторов
    //  - Явная политика буфера и завершения
    //  - Операторы — маленькие generic-функции/типы, покрытые тестами

    static func run() async throws {
        try await countdownDemo()
        try await pagedDemo()
        await builtinOperators()
        try await operatorsDemo()
        await combineToAsync()

        let engine = SearchEngine { query, page in page < 3 ? ["\(query)-\(page)a", "\(query)-\(page)b"] : [] }
        let model = await SearchModel(engine: engine, debounce: .milliseconds(20))
        await model.textChanged("s"); await model.textChanged("sw")
        try? await Task.sleep(for: .milliseconds(150))
        print(await model.results)
        await model.stop()
    }
}
