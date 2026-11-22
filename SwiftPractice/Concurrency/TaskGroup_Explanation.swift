// ============================================================================
// TaskGroup_Explanation.swift
// withTaskGroup, withThrowingTaskGroup, withDiscardingTaskGroup,
// ограничение параллелизма, async let, порядок результатов
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: структурная конкурентность
//  2. async let vs TaskGroup
//  3. TaskGroup: сбор результатов, порядок, ранний выход
//  4. ОГРАНИЧЕНИЕ ПАРАЛЛЕЛИЗМА (скользящее окно)
//  5. withDiscardingTaskGroup: долгоживущие задачи без накопления результатов
//  6. Ошибки в группе, частичный успех, отмена
//  7. Production-пример: массовая загрузка превью с лимитом и прогрессом
//  8. Архитектурный анализ, ошибки, best practices
//
// Типы в неймспейсе `TaskGroupLesson`.
// ============================================================================

import Foundation

enum TaskGroupLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // Структурная конкурентность: время жизни дочерних задач ПРИВЯЗАНО к
    // области, где они созданы. Функция не вернётся, пока ВСЕ дочерние задачи
    // не завершены. Следствия:
    //  - нет "утёкших" задач; нельзя забыть дождаться
    //  - отмена родителя автоматически отменяет детей
    //  - ошибка ребёнка может отменить остальных (в throwing-группе)
    //  - приоритет и task-local значения наследуются
    //
    // Неструктурные задачи (Task { }, Task.detached) — исключение, их
    // жизненный цикл ведёте вы сами.

    // ========================================================================
    // 2. async let vs TaskGroup
    // ========================================================================
    //
    //  async let : ФИКСИРОВАННОЕ число задач, известное при написании кода;
    //              разные типы результатов; самый короткий синтаксис.
    //  TaskGroup : ДИНАМИЧЕСКОЕ число задач (по размеру массива); один тип
    //              результата; полный контроль (порядок, лимит, ранний выход).

    struct Profile: Sendable { let name: String }
    struct Settings: Sendable { let theme: String }
    struct Feed: Sendable { let items: [Int] }

    static func loadScreen() async throws -> (Profile, Settings, Feed) {
        async let profile = fetchProfile()           // стартуют ОДНОВРЕМЕННО
        async let settings = fetchSettings()
        async let feed = fetchFeed()
        // Результаты ждём вместе; если одна упадёт — остальные отменятся
        return try await (profile, settings, feed)
        // Если выйти из области без await — async let отменяется неявно.
    }
    static func fetchProfile() async throws -> Profile { try await Task.sleep(for: .milliseconds(10)); return Profile(name: "A") }
    static func fetchSettings() async throws -> Settings { Settings(theme: "dark") }
    static func fetchFeed() async throws -> Feed { Feed(items: [1, 2, 3]) }

    // ========================================================================
    // 3. TASKGROUP: БАЗА
    // ========================================================================

    /// Результаты приходят в порядке ЗАВЕРШЕНИЯ, не добавления!
    /// Если порядок важен — возвращайте (индекс, значение) и сортируйте.
    static func squaresOrdered(_ input: [Int]) async -> [Int] {
        await withTaskGroup(of: (Int, Int).self) { group in
            for (index, value) in input.enumerated() {
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(.random(in: 1...10)))
                    return (index, value * value)
                }
            }
            var buffer = [Int?](repeating: nil, count: input.count)   // заранее выделили
            for await (index, value) in group { buffer[index] = value }
            return buffer.compactMap { $0 }
        }
    }

    /// Ранний выход: первый подходящий результат, остальные отменяем.
    /// Применение: гонка зеркал/серверов, поиск в нескольких источниках.
    static func firstSuccess(from sources: [@Sendable () async throws -> String]) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for source in sources {
                group.addTask { try? await source() }
            }
            for await result in group {
                if let result {
                    group.cancelAll()                  // кооперативная отмена остальных
                    return result
                }
            }
            return nil
        }
    }

    // ========================================================================
    // 4. ОГРАНИЧЕНИЕ ПАРАЛЛЕЛИЗМА — скользящее окно
    // ========================================================================
    //
    // Проблема: addTask для 5000 элементов запускает ВСЕ сразу ->
    // 5000 одновременных сетевых запросов, всплеск памяти, throttling сервера,
    // исчерпание файловых дескрипторов.
    //
    // Решение: держим в группе не более `limit` задач. Как только одна
    // завершилась (`group.next()`), добавляем следующую.

    static func boundedMap<Input: Sendable, Output: Sendable>(
        _ items: [Input],
        limit: Int,
        transform: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        precondition(limit > 0)
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var results = [Output?](repeating: nil, count: items.count)
            var next = 0

            // 1) Заполняем окно
            while next < min(limit, items.count) {
                let i = next
                group.addTask { (i, try await transform(items[i])) }
                next += 1
            }
            // 2) Завершилась одна -> добавляем следующую
            while let (index, value) = try await group.next() {
                results[index] = value
                if next < items.count {
                    let i = next
                    group.addTask { (i, try await transform(items[i])) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    /// Проверка лимита: счётчик одновременно идущих задач.
    actor ConcurrencyProbe {
        private var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    static func boundedDemo() async throws {
        let probe = ConcurrencyProbe()
        let out = try await boundedMap(Array(1...20), limit: 4) { n in
            await probe.enter()
            try await Task.sleep(for: .milliseconds(10))
            await probe.leave()
            return n * 2
        }
        print(out.count, "пик параллелизма:", await probe.peak)   // <= 4
    }

    // ========================================================================
    // 5. withDiscardingTaskGroup (Swift 5.9+)
    // ========================================================================
    //
    // Обычная группа ХРАНИТ результаты завершённых задач, пока вы их не
    // вычитаете (`next()`/for await). Для "вечных" серверов/слушателей
    // это утечка памяти: задач миллионы, результаты (Void!) копятся.
    //
    // withDiscardingTaskGroup: результаты ОТБРАСЫВАЮТСЯ сразу; дочерние
    // задачи возвращают Void. Если ребёнок бросает ошибку — группа
    // отменяется целиком (throwing-вариант).
    //
    // Применение: обработчик соединений сервера, "для каждого события
    // запусти обработку", параллельные независимые side-effect'ы.

    static func handleEvents(_ events: AsyncStream<Int>) async {
        await withDiscardingTaskGroup { group in
            for await event in events {
                group.addTask {                         // каждое событие — своя задача
                    try? await Task.sleep(for: .milliseconds(5))
                    _ = event * 2                       // обработка
                }
            }                                           // вышли из for -> ждём оставшиеся
        }
    }

    static func discardingThrowingDemo() async {
        do {
            try await withThrowingDiscardingTaskGroup { group in
                group.addTask { try await Task.sleep(for: .milliseconds(5)) }
                group.addTask { throw URLError(.timedOut) }        // отменит соседей
            }
        } catch {
            print("группа отменена из-за:", error)
        }
    }

    // ========================================================================
    // 6. ОШИБКИ, ЧАСТИЧНЫЙ УСПЕХ, ОТМЕНА
    // ========================================================================

    /// Режим "всё или ничего": первая ошибка -> отмена остальных -> throw.
    static func allOrNothing(_ ids: [Int]) async throws -> [Int] {
        try await boundedMap(ids, limit: 8) { id in
            if id == 13 { throw URLError(.badServerResponse) }
            return id
        }
    }

    /// Режим "что получится": каждая задача возвращает Result; группа не падает.
    static func bestEffort(_ ids: [Int]) async -> (ok: [Int], failed: [Int]) {
        await withTaskGroup(of: (Int, Bool).self) { group in
            for id in ids { group.addTask { (id, id != 13) } }
            var ok: [Int] = [], failed: [Int] = []
            for await (id, success) in group { if success { ok.append(id) } else { failed.append(id) } }
            return (ok.sorted(), failed.sorted())
        }
    }

    // Важно:
    //  - Выход из `withTaskGroup` с бросанием ошибки из тела вызывает отмену
    //    всех незавершённых детей и ожидание их завершения.
    //  - Отмена КООПЕРАТИВНА: задача, не проверяющая отмену, доработает до конца.
    //  - `group.addTaskUnlessCancelled` — не добавлять, если группа уже отменена.
    //  - `group.waitForAll()` — дождаться всех без чтения результатов.

    // ========================================================================
    // 7. PRODUCTION-ПРИМЕР: массовая загрузка превью с лимитом и прогрессом
    // ========================================================================
    //
    // Задача: открыть галерею с 500 превью. Нужно:
    //  - не более 6 одновременных загрузок
    //  - прогресс для UI
    //  - ошибка одного превью НЕ ломает остальные (placeholder)
    //  - отмена при закрытии экрана

    struct Thumbnail: Sendable { let id: Int; let bytes: Int?; var isPlaceholder: Bool { bytes == nil } }

    protocol ThumbnailLoader: Sendable { func load(id: Int) async throws -> Int }
    struct FakeLoader: ThumbnailLoader {
        func load(id: Int) async throws -> Int {
            try await Task.sleep(for: .milliseconds(2))
            if id % 50 == 0 { throw URLError(.cannotConnectToHost) }
            return id * 10
        }
    }

    struct ThumbnailService: Sendable {
        let loader: any ThumbnailLoader
        let concurrency: Int

        /// Прогресс — через AsyncStream: UI слушает, сервис пишет.
        func loadAll(ids: [Int]) -> (thumbnails: Task<[Thumbnail], Never>, progress: AsyncStream<Double>) {
            let (progressStream, progress) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let loader = self.loader
            let limit = concurrency
            let task = Task<[Thumbnail], Never> {
                defer { progress.finish() }
                let done = Counter()
                var results = [Thumbnail?](repeating: nil, count: ids.count)
                await withTaskGroup(of: (Int, Thumbnail).self) { group in
                    var next = 0
                    func addNext() {
                        guard next < ids.count else { return }
                        let index = next; next += 1
                        let id = ids[index]
                        _ = group.addTaskUnlessCancelled {
                            // Ошибка превращается в placeholder — группа не падает
                            let bytes = try? await loader.load(id: id)
                            return (index, Thumbnail(id: id, bytes: bytes))
                        }
                    }
                    for _ in 0..<limit { addNext() }
                    for await (index, thumb) in group {
                        results[index] = thumb
                        let finished = await done.increment()
                        progress.yield(Double(finished) / Double(ids.count))
                        addNext()
                    }
                }
                return results.compactMap { $0 }
            }
            return (task, progressStream)
        }
    }

    actor Counter { private var n = 0; func increment() -> Int { n += 1; return n } }

    @MainActor
    final class GalleryViewModel {
        private(set) var progress = 0.0
        private(set) var thumbnails: [Thumbnail] = []
        private var loadTask: Task<Void, Never>?
        private let service: ThumbnailService
        init(service: ThumbnailService) { self.service = service }

        func load(ids: [Int]) {
            loadTask?.cancel()
            loadTask = Task {
                let (work, stream) = service.loadAll(ids: ids)
                // onCancel: отмена VM-задачи пробрасывается во внутреннюю
                await withTaskCancellationHandler {
                    for await p in stream { progress = p }
                    thumbnails = await work.value
                } onCancel: { work.cancel() }
            }
        }
        func close() { loadTask?.cancel() }       // закрыли экран -> отмена всей цепочки
    }

    // ========================================================================
    // 8. АРХИТЕКТУРНЫЙ АНАЛИЗ, ОШИБКИ, BEST PRACTICES
    // ========================================================================
    //
    // ВЫБОР:
    //   1–5 разнотипных запросов  -> async let
    //   N однотипных, N невелико  -> TaskGroup
    //   N велико / внешний ресурс -> TaskGroup с лимитом (boundedMap)
    //   вечный обработчик событий  -> withDiscardingTaskGroup
    //   нужно пережить функцию     -> Task { } (неструктурная; осознанно)
    //
    // ПЛЮСЫ: нет утечек задач, автоматическая отмена, предсказуемый
    //   приоритет, проверка Sendable.
    // МИНУСЫ: порядок завершения != порядок добавления; один тип результата;
    //   лимит приходится писать вручную; отмена кооперативна.
    //
    // ОШИБКИ:
    //  1. Запуск тысяч задач без лимита (DoS на себя/сервер).
    //  2. Расчёт, что результаты придут по порядку.
    //  3. Мутация общей переменной из детей (data race) — собирай в цикле
    //     `for await` в родителе (там последовательно).
    //  4. Игнор отмены в длинных детях: нет checkCancellation/yield.
    //  5. Обычная группа в бесконечном цикле -> рост памяти (нужна discarding).
    //  6. Проглоченные ошибки: `try?` без учёта, что часть данных потеряна.
    //  7. Много мелких задач (1000 × микро-работа): накладные расходы
    //     больше выигрыша — батчи по N элементов.
    //  8. Блокирующие вызовы (sleep(), семафоры) внутри детей — голодание пула.
    //
    // BEST PRACTICES:
    //  - лимит ~ число ядер для CPU-работы; 4–8 для сети
    //  - возвращай (индекс, значение), если важен порядок
    //  - ошибку на уровне элемента превращай в Result/placeholder, если
    //    цель — "максимум полезного"
    //  - обязательно тестируй отмену и лимит (ConcurrencyProbe)

    static func run() async throws {
        print(try await loadScreen().0.name)
        print(await squaresOrdered([1, 2, 3, 4]))
        try await boundedDemo()
        await discardingThrowingDemo()
        print(await bestEffort([1, 13, 5]))

        let service = ThumbnailService(loader: FakeLoader(), concurrency: 6)
        let (task, progress) = service.loadAll(ids: Array(1...100))
        for await p in progress where p == 1 { print("прогресс 100%") }
        let thumbs = await task.value
        print(thumbs.filter(\.isPlaceholder).count, "плейсхолдеров")
    }
}
