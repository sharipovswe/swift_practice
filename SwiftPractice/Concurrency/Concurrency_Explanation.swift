// ============================================================================
// Concurrency_Explanation.swift
// DispatchQueue, Task { }, @escaping, @MainActor, actor, async/await
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: модели многопоточности в iOS (GCD vs Swift Concurrency)
//  2. DispatchQueue: serial/concurrent, QoS, sync/async, barrier, group
//  3. Task: неструктурные и структурные задачи, отмена, приоритеты
//  4. @escaping в асинхронном коде
//  5. @MainActor: главный поток на уровне типов
//  6. Миграция GCD -> async/await (мост)
//  7. Production-пример: ViewModel + сервис + отмена
//  8. Архитектурный анализ, ошибки, best practices
//
// Типы в неймспейсе `ConcurrencyLesson`.
// ============================================================================

import Foundation

enum ConcurrencyLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // GCD (Grand Central Dispatch) — очереди + пул потоков ОС. Вы описываете
    // КУДА выполнить код (очередь). Безопасность — на вашей совести.
    //
    // Swift Concurrency (async/await, Task, actor) — вы описываете ЧТО и
    // какие у него ЗАВИСИМОСТИ; компилятор проверяет изоляцию. Задачи
    // исполняются на кооперативном пуле потоков (число потоков ≈ число ядер),
    // `await` — точка приостановки, поток НЕ блокируется, а освобождается.
    //
    // Нельзя блокировать кооперативный пул: семафоры, sleep(), sync-ожидание
    // внутри async-кода -> голодание пула и взаимные блокировки.

    // ------------------------------------------------------------------------
    // 2. DISPATCHQUEUE
    // ------------------------------------------------------------------------

    static func dispatchQueueDemo() {
        // Главная очередь: serial, исполняется на main thread. Только UI.
        // DispatchQueue.main.async { label.text = "..." }

        // Глобальные concurrent-очереди с QoS (Quality of Service):
        //  .userInteractive  — анимации, ввод (мгновенно)
        //  .userInitiated    — результат нужен пользователю "сейчас" (секунды)
        //  .utility          — прогресс-бар, загрузки (секунды-минуты)
        //  .background       — синхронизация, бэкап (минуты, можно не спешить)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = (1...1_000).reduce(0, +)               // тяжёлая работа
            DispatchQueue.main.async { print("на main:", result) }
        }

        // Собственная serial-очередь = "замок": операции идут строго по одной.
        let serial = DispatchQueue(label: "com.app.storage")           // serial по умолчанию
        let concurrent = DispatchQueue(label: "com.app.reader", attributes: .concurrent)
        _ = (serial, concurrent)

        // sync блокирует вызывающий поток до завершения. Вызов serial.sync
        // из этой же serial-очереди = DEADLOCK. main.sync из main = DEADLOCK.

        // DispatchGroup: дождаться набора независимых задач.
        let group = DispatchGroup()
        for i in 0..<3 {
            group.enter()
            DispatchQueue.global().async {
                _ = i * i
                group.leave()                                    // enter/leave парные!
            }
        }
        group.notify(queue: .main) { print("все задачи готовы") }

        // Barrier: читатели параллельно, писатель эксклюзивно (reader-writer lock).
        let q = DispatchQueue(label: "rw", attributes: .concurrent)
        // Под strict concurrency компилятор предупредит о захвате `storage` —
        // для реального кода инкапсулируйте в класс (как ThreadSafeArray ниже).
        var storage = [String: Int]()
        func read(_ k: String) -> Int? { q.sync { storage[k] } }
        func write(_ k: String, _ v: Int) { q.async(flags: .barrier) { storage[k] = v } }
        write("a", 1); _ = read("a")
    }

    /// Классический потокобезопасный контейнер на GCD. Сегодня то же
    /// выражается через actor/Mutex, но в legacy-коде встречается постоянно.
    final class ThreadSafeArray<T: Sendable>: @unchecked Sendable {
        private var items: [T] = []
        private let queue = DispatchQueue(label: "threadsafe.array", attributes: .concurrent)

        func append(_ item: T) { queue.async(flags: .barrier) { self.items.append(item) } }
        var snapshot: [T] { queue.sync { items } }
    }

    // ------------------------------------------------------------------------
    // 3. TASK
    // ------------------------------------------------------------------------

    static func taskDemo() async {
        // (1) Task { } — НЕСТРУКТУРНАЯ задача. Наследует: actor-изоляцию,
        //     приоритет, task-local значения. Запускается сразу, без await.
        //     Ссылку держать не обязательно, но тогда отменить нельзя.
        let handle = Task {
            try await Task.sleep(for: .seconds(1))
            return "готово"
        }
        handle.cancel()                                   // кооперативная отмена
        _ = try? await handle.value                       // бросит CancellationError

        // (2) Task.detached — НЕ наследует изоляцию и приоритет. Нужен редко:
        //     когда явно нужно уйти с текущего actor (напр., тяжёлый CPU).
        let heavy = Task.detached(priority: .utility) { (1...1_000).reduce(0, +) }
        print(await heavy.value)

        // (3) async let — СТРУКТУРНЫЙ параллелизм фиксированного числа задач.
        async let a = fetchNumber(1)
        async let b = fetchNumber(2)
        print(try! await a + b)                           // выполнялись одновременно
        // Выход из области без await -> задачи автоматически отменяются.

        // (4) TaskGroup — динамическое число задач (см. ErrorHandling).
        let total = await withTaskGroup(of: Int.self) { g in
            for i in 1...5 { g.addTask { i } }
            return await g.reduce(0, +)
        }
        print(total)

        // Отмена кооперативна: сама не прерывает код. Проверяй:
        //   try Task.checkCancellation()  /  Task.isCancelled  /  await Task.yield()
        // Системные API (URLSession.data, Task.sleep) реагируют на отмену сами.
    }

    static func fetchNumber(_ n: Int) async throws -> Int {
        try await Task.sleep(for: .milliseconds(10))
        return n
    }

    // Хранимая задача + отмена в deinit: типичный паттерн жизненного цикла.
    @MainActor
    final class SearchController {
        private var searchTask: Task<Void, Never>?
        private(set) var results: [String] = []

        func search(_ query: String) {
            searchTask?.cancel()                           // новая замена старой
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(250))   // debounce
                guard !Task.isCancelled else { return }
                let r = await Self.runSearch(query)
                guard !Task.isCancelled else { return }          // проверка после await!
                results = r                                      // уже на main (наследуем @MainActor)
            }
        }
        // nonisolated: поиск не должен идти на main thread
        nonisolated private static func runSearch(_ q: String) async -> [String] { [q + "1", q + "2"] }

        deinit { searchTask?.cancel() }
    }

    // ------------------------------------------------------------------------
    // 4. @ESCAPING В АСИНХРОННОМ КОДЕ
    // ------------------------------------------------------------------------
    //
    // @escaping — замыкание вызывается ПОСЛЕ возврата функции. Всё, что
    // попадает в DispatchQueue.async, Task, хранится в свойстве — escaping.
    // Следствия:
    //  1) нужен `self.` (в классах) -> видно захват
    //  2) риск retain cycle -> [weak self]
    //  3) в Swift 6 такое замыкание, уходящее в другой поток, обязано быть
    //     @Sendable
    //
    // С async/await @escaping почти не нужен: продолжение после await — это
    // не замыкание, а часть async-функции. Поэтому менее подвержено утечкам.

    final class Worker {
        private var completions: [() -> Void] = []         // хранение => escaping
        func onReady(_ f: @escaping () -> Void) { completions.append(f) }
        func fire() { completions.forEach { $0() }; completions.removeAll() }   // очистка = разрыв цикла
    }

    // non-escaping: можно передать неявно изменяемое состояние и не писать self.
    static func repeatTwice(_ f: () -> Void) { f(); f() }

    // ------------------------------------------------------------------------
    // 5. @MAINACTOR
    // ------------------------------------------------------------------------
    //
    // @MainActor — глобальный actor: всё помеченное исполняется на main thread,
    // гарантия проверяется КОМПИЛЯТОРОМ (вместо ручных `DispatchQueue.main`).
    //
    // Применяется к: классу/структуре/enum, методу, свойству, замыканию,
    // протоколу. Из другой изоляции вызывается через `await`.
    // SwiftUI: View.body и @Observable-ViewModel обычно @MainActor.

    @MainActor
    final class CounterViewModel {
        private(set) var count = 0                         // изолировано на main
        func increment() { count += 1 }                    // main -> sync

        nonisolated func pureCalc(_ n: Int) -> Int { n * 2 }  // не трогает count

        func loadRemote() async {
            // Тяжёлая часть — вне main:
            let value = await Task.detached { (1...1000).reduce(0, +) }.value
            count = value                                  // вернулись на main автоматически
        }
    }

    // Вызов снаружи:
    static func callFromOutside() async {
        let vm = await MainActor.run { CounterViewModel() }
        await vm.increment()                               // await: переключение на main
        print(await vm.count)
    }

    // Динамически перейти на main из async-кода:
    static func updateUI() async {
        await MainActor.run { print("UI-обновление на main") }
    }

    // `MainActor.assumeIsolated { }` — "я знаю, что мы на main": проверка в
    // runtime (crash при ошибке). Нужен при адаптации старых callback-API,
    // которые документированно вызываются на main.

    // ========================================================================
    // 6. МИГРАЦИЯ GCD -> ASYNC/AWAIT
    // ========================================================================

    final class LegacyAPI {
        func load(completion: @escaping @Sendable (Result<String, Error>) -> Void) {
            DispatchQueue.global().async { completion(.success("data")) }
        }
    }

    /// Обёртка в extension: старый API остаётся, новый — async.
    /// Continuation должна быть возобновлена РОВНО один раз.
    static func load(using api: LegacyAPI) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            api.load { cont.resume(with: $0) }
        }
        // withUnsafe...Continuation — без проверок (быстрее, опаснее);
        // Checked в debug сообщает о двойном/пропущенном resume.
    }

    // Сравнение: serial queue как защита состояния -> actor
    //   GCD:     queue.sync { state += 1 }
    //   actor:   await counter.increment()

    // ========================================================================
    // 7. PRODUCTION-ПРИМЕР: загрузка ленты с отменой и дедупликацией
    // ========================================================================

    struct Post: Sendable, Identifiable { let id: Int; let text: String }

    protocol FeedService: Sendable {
        func page(_ number: Int) async throws -> [Post]
    }

    struct FakeFeedService: FeedService {
        func page(_ number: Int) async throws -> [Post] {
            try await Task.sleep(for: .milliseconds(20))
            return (0..<3).map { Post(id: number * 10 + $0, text: "post \($0)") }
        }
    }

    @MainActor
    final class FeedViewModel {
        enum State { case idle, loading, loaded([Post]), failed(String) }

        private(set) var state: State = .idle
        private var loadTask: Task<Void, Never>?
        private var posts: [Post] = []
        private var nextPage = 0
        private let service: FeedService

        init(service: FeedService) { self.service = service }

        /// Вызывается из UI синхронно (кнопка, pull-to-refresh, .onAppear).
        /// Повторный вызов, пока идёт загрузка, игнорируется (дедупликация).
        func loadMore() {
            guard loadTask == nil else { return }
            state = .loading
            loadTask = Task { [weak self] in
                guard let self else { return }
                defer { self.loadTask = nil }
                do {
                    // `service` Sendable; вызов уходит с main, возвращаемся на main
                    let page = try await self.service.page(self.nextPage)
                    try Task.checkCancellation()
                    self.posts += page
                    self.nextPage += 1
                    self.state = .loaded(self.posts)
                } catch is CancellationError {
                    self.state = .idle
                } catch {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }

        func cancel() { loadTask?.cancel() }
    }

    // ========================================================================
    // 8. АРХИТЕКТУРНЫЙ АНАЛИЗ, ОШИБКИ, BEST PRACTICES
    // ========================================================================
    //
    // ЧТО КОГДА:
    //  async/await + actor  — весь новый код.
    //  DispatchQueue        — legacy, низкоуровневые C/ObjC API, барьеры на
    //                         горячем пути, DispatchSource, интеграция SDK.
    //  Task { }             — мост из синхронного мира (кнопка, lifecycle) в async.
    //  Task.detached        — редко; осознанный уход от изоляции.
    //  @MainActor           — UI-модели, координаторы навигации.
    //
    // ПЛЮСЫ Swift Concurrency: проверка изоляции компилятором, отмена по
    //   дереву задач, читаемый линейный код, нет callback hell.
    // МИНУСЫ: порог входа, actor reentrancy, "вирусность" async, сложнее
    //   отладка потоков, ограничения на старых ОС (iOS 13+ с back-deploy).
    //
    // ОШИБКИ:
    //  1. DispatchQueue.main.sync на main — deadlock.
    //  2. DispatchSemaphore/wait() внутри async — блокирует пул.
    //  3. Task { } в цикле без контроля -> тысячи задач; используй TaskGroup
    //     с ограничением параллелизма.
    //  4. Забыли проверить Task.isCancelled после await перед записью состояния.
    //  5. Предположили, что после await состояние actor не изменилось.
    //  6. `Task { self.x }` в долгоживущем объекте: Task удерживает self до конца.
    //  7. UI-обновления вне main (в Swift 6 — ошибка компиляции, в UIKit crash).
    //  8. Бросать work на Task.detached "для скорости" — теряете отмену и приоритет.
    //
    // BEST PRACTICES:
    //  - UI-типы @MainActor; тяжёлую работу — в nonisolated async / отдельный actor
    //  - хранимая Task + cancel при смене входных данных/deinit
    //  - дедупликация одинаковых запросов (inFlight-словарь в actor)
    //  - ограничивай параллелизм (окно из N задач в группе)
    //  - тестируй async-код напрямую (`async` тесты + контролируемые Clock)
    //  - внедряй Clock/время как зависимость для детерминированных тестов
    //
    // СВЯЗЬ: Sendable_Explanation (границы изоляции), AsyncStream_Explanation
    //  (потоки событий), Closures_Explanation (@escaping/[weak self]),
    //  ErrorHandling_Explanation (отмена и retry).

    static func run() async {
        dispatchQueueDemo()
        await taskDemo()
        await callFromOutside()
        await updateUI()
        let vm = await FeedViewModel(service: FakeFeedService())
        await vm.loadMore()
        try? await Task.sleep(for: .milliseconds(100))
        print(await vm.state)
    }
}
