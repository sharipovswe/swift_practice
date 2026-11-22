// ============================================================================
// Closures_Explanation.swift
// MARK 12: Замыкания (Closures)
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: что такое замыкание, захват контекста
//  2. Синтаксис: сокращения, trailing closure, capture list
//  3. Сценарии: HOF, @escaping, [weak self], @autoclosure, struct-of-closures,
//     async-замыкания, @Sendable
//  4. Production: DI через замыкания, debounce, retry, event handlers
//  5. Архитектурный анализ: замыкание vs протокол vs async/await
//  6. Ошибки (retain cycle!) и best practices
//  7. Связь с SOLID, Clean Architecture, concurrency
//
// Типы в неймспейсе `ClosuresLesson`.
// ============================================================================

import Foundation

enum ClosuresLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // Замыкание — блок кода, который можно передавать как значение и который
    // "захватывает" (capture) переменные из окружающего контекста.
    // Функции и методы — частный случай замыканий (именованные).
    // Тип замыкания: `(Параметры) -> Результат`, это ссылочный тип:
    // функция + "коробка" с захваченными переменными (context).
    //
    // Захват:
    //  - ПО ССЫЛКЕ: замыкание держит саму переменную (не копию значения),
    //    поэтому видит последующие изменения и может менять её.
    //  - Захваченный reference-type объект удерживается СИЛЬНОЙ ссылкой
    //    (ARC +1) -> отсюда retain cycle, см. раздел 6.
    //
    // Escaping vs non-escaping:
    //  - non-escaping (по умолчанию): замыкание не переживёт вызов функции.
    //    Компилятор оптимизирует (стек, без heap-аллокации), `self.` не нужен.
    //  - @escaping: замыкание сохраняется/вызывается ПОСЛЕ возврата из функции
    //    (completion, хранение в свойстве, асинхронная очередь). Требует
    //    явного `self.` и внимания к циклам ссылок.

    // ------------------------------------------------------------------------
    // 2. БАЗОВЫЙ СИНТАКСИС
    // ------------------------------------------------------------------------

    static func syntaxDemo() {
        // Полная форма
        let add1 = { (a: Int, b: Int) -> Int in
            return a + b
        }
        // Вывод типов + неявный return (однострочное выражение)
        let add2: (Int, Int) -> Int = { a, b in a + b }
        // Shorthand-аргументы $0, $1 — только для очень коротких замыканий
        let add3: (Int, Int) -> Int = { $0 + $1 }
        // Оператор как функция
        let add4: (Int, Int) -> Int = (+)
        print(add1(1, 2), add2(1, 2), add3(1, 2), add4(1, 2))

        // Trailing closure: замыкание-последний аргумент выносится за скобки.
        let sorted = [3, 1, 2].sorted { $0 > $1 }
        // Higher-Order Functions: map / filter / reduce / compactMap / flatMap
        let squares = (1...5).map { $0 * $0 }
        let evens = squares.filter { $0 % 2 == 0 }
        let sum = squares.reduce(0, +)
        let nums = ["1", "x", "3"].compactMap { Int($0) }        // [1, 3], nil отбрасываются
        let flat = [[1, 2], [3]].flatMap { $0 }                  // [1, 2, 3]
        print(sorted, squares, evens, sum, nums, flat)

        // Захват по ссылке
        var counter = 0
        let increment = { counter += 1 }       // захватил переменную, не значение
        increment(); increment()
        print(counter)                          // 2

        // Фабрика замыканий: каждое имеет СВОЁ захваченное состояние.
        func makeCounter() -> () -> Int {
            var count = 0
            return { count += 1; return count }
        }
        let c1 = makeCounter(), c2 = makeCounter()
        print(c1(), c1(), c2())                 // 1 2 1
    }

    // Capture list: фиксируем ЗНАЧЕНИЕ на момент создания (а не ссылку).
    static func captureListDemo() {
        var x = 10
        let byRef = { print("ref:", x) }
        let byValue = { [x] in print("value:", x) }   // копия x == 10
        x = 99
        byRef()      // ref: 99
        byValue()    // value: 10
    }

    // ========================================================================
    // 3. ПРАКТИЧЕСКИЕ СЦЕНАРИИ
    // ========================================================================

    // ------------------------------------------------------------------------
    // Сценарий A. @escaping completion + [weak self] — классика UIKit-эпохи.
    // ------------------------------------------------------------------------

    final class LegacyProfileLoader {
        private(set) var name = ""
        private var onUpdate: ((String) -> Void)?       // хранится -> нужно @escaping

        func subscribe(_ handler: @escaping (String) -> Void) {
            onUpdate = handler                          // замыкание пережило вызов
        }

        func load(completion: @escaping (Result<String, Error>) -> Void) {
            DispatchQueue.global().async { [weak self] in
                // weak: если загрузчик уже уничтожен — просто выходим,
                // и не продлеваем его жизнь ради фонового колбэка.
                guard let self else { return }
                self.name = "Элшод"
                DispatchQueue.main.async {
                    completion(.success(self.name))
                    self.onUpdate?(self.name)
                }
            }
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий B. @autoclosure — ленивое вычисление аргумента.
    // ------------------------------------------------------------------------
    // Так устроены assert, ??, &&. Дорогое выражение не вычисляется, если
    // не нужно. Применение: логгер, который не строит строку при выключенном
    // уровне логирования.

    static func log(_ message: @autoclosure () -> String, enabled: Bool) {
        guard enabled else { return }       // message() НЕ вызван — строка не собрана
        print(message())
    }

    // ------------------------------------------------------------------------
    // Сценарий C. Замыкания как строительные блоки: композиция функций.
    // ------------------------------------------------------------------------

    static func compose<A, B, C>(_ f: @escaping (A) -> B, _ g: @escaping (B) -> C) -> (A) -> C {
        { g(f($0)) }
    }

    /// Каррирование/частичное применение: фиксируем часть аргументов.
    static func multiplier(_ k: Int) -> (Int) -> Int { { $0 * k } }

    // ------------------------------------------------------------------------
    // Сценарий D. STRUCT-OF-CLOSURES вместо протокола (Point-Free стиль).
    // ------------------------------------------------------------------------
    // Зависимость = struct с замыканиями. Плюсы против протокола:
    //  - мок = просто подставить замыкание, без отдельного класса
    //  - можно переопределить ОДИН метод, остальные оставить live
    //  - легко компоновать/декорировать
    // Минусы: нет автодополнения "реализуй все методы", хуже читается стек
    // вызовов, нет именованных параметров в замыканиях.

    struct APIClient {
        var fetchUser: @Sendable (_ id: Int) async throws -> String
        var track: @Sendable (_ event: String) -> Void

        static let live = APIClient(
            fetchUser: { id in "user-\(id)" },       // реальный сетевой вызов
            track: { print("analytics:", $0) }
        )
        static let mock = APIClient(
            fetchUser: { _ in "Mock" },
            track: { _ in }
        )
    }

    // ------------------------------------------------------------------------
    // Сценарий E. Async-замыкания, @Sendable, @MainActor.
    // ------------------------------------------------------------------------
    // `@Sendable` — замыкание может исполняться в другой изоляции/потоке,
    // поэтому не имеет права захватывать изменяемое несинхронизированное
    // состояние (см. Sendable_Explanation).
    // `@MainActor () -> Void` — замыкание гарантированно исполняется на main.

    static func runInBackground(_ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global().async(execute: work)
    }

    static func onMain(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }

    /// Асинхронный параметр-замыкание: `() async throws -> T`.
    static func measure<T>(_ label: String, _ operation: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        defer { print("\(label): \(ContinuousClock.now - start)") }
        return try await operation()
    }

    // ------------------------------------------------------------------------
    // Сценарий F. Отложенное выполнение: debounce на замыканиях + Task.
    // ------------------------------------------------------------------------
    // Поиск по мере ввода: запускаем запрос, только если пользователь не
    // печатал 300 мс. Предыдущая задача отменяется.

    @MainActor
    final class Debouncer {
        private var task: Task<Void, Never>?
        private let delay: Duration
        init(delay: Duration = .milliseconds(300)) { self.delay = delay }

        func call(_ action: @escaping @MainActor () async -> Void) {
            task?.cancel()                                  // отменяем прошлую
            task = Task { [delay] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }     // отменили во сне
                await action()
            }
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий G. Lazy closure-свойство и результирующий builder (@resultBuilder).
    // ------------------------------------------------------------------------

    /// Замыкание для инициализации свойства: настройка "на месте".
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.locale = Locale(identifier: "ru_RU")
        return f                                   // вызывается один раз (lazy static)
    }()

    // ========================================================================
    // 4. PRODUCTION-ПРИМЕР: Event bus + ViewModel с обработчиками
    // ========================================================================
    //
    // Сценарий: экран оплаты. Coordinator хочет знать о результате, но
    // ViewModel не должен знать про навигацию (SRP, Clean Architecture).
    // Решение: ViewModel принимает замыкания-"выходы" (output closures).

    @MainActor
    final class PaymentViewModel {
        // Выходы (callbacks наружу). Их ставит Coordinator.
        var onFinish: ((_ receiptID: String) -> Void)?
        var onCancel: (() -> Void)?

        // Входная зависимость — замыкание (мок в тестах за одну строку).
        private let pay: (_ amount: Int) async throws -> String
        private(set) var isLoading = false

        init(pay: @escaping (_ amount: Int) async throws -> String) {
            self.pay = pay
        }

        func confirm(amount: Int) {
            guard !isLoading else { return }
            isLoading = true
            // Task наследует изоляцию @MainActor. [weak self]: если экран закрыт
            // во время оплаты, не удерживаем ViewModel.
            Task { [weak self] in
                guard let self else { return }
                defer { self.isLoading = false }
                do {
                    let id = try await self.pay(amount)
                    self.onFinish?(id)
                } catch {
                    self.onCancel?()
                }
            }
        }
    }

    @MainActor
    final class PaymentCoordinator {
        func start() -> PaymentViewModel {
            let vm = PaymentViewModel(pay: { amount in "RCPT-\(amount)" })
            // [weak self] обязателен: coordinator -> vm -> замыкание -> coordinator
            // иначе цикл ссылок и утечка обоих.
            vm.onFinish = { [weak self] id in self?.showReceipt(id) }
            vm.onCancel = { [weak self] in self?.dismiss() }
            return vm
        }
        private func showReceipt(_ id: String) { print("чек", id) }
        private func dismiss() { print("закрыть") }
    }

    // ========================================================================
    // 5. АРХИТЕКТУРНЫЙ АНАЛИЗ: замыкание, протокол или async/await?
    // ========================================================================
    //
    //  Замыкание:   одна простая операция; одноразовый колбэк; DI одного
    //               метода; HOF (map/filter); конфигурация "на месте".
    //  Протокол:    несколько связанных методов; нужна именованная роль;
    //               несколько реализаций с состоянием; документируемый контракт.
    //  async/await: любой одноразовый асинхронный результат — вместо
    //               completion handler (нет "ада колбэков", нет утечек
    //               через self, ошибки через throws).
    //  AsyncStream: повторяющиеся события вместо callback-свойств.
    //
    // ПЛЮСЫ: компактность, локальность логики, гибкость, мощные HOF.
    // МИНУСЫ: retain cycles, трудно отлаживать стек, "callback hell",
    //         нет именованных параметров, нестабильный тип при хранении
    //         (@escaping в свойствах), сложнее отменять.
    //
    // ИЗБЫТОЧНО: замыкание на 40 строк с вложенными замыканиями — выноси в
    // именованный метод; десять замыканий в init вместо протокола.

    // ========================================================================
    // 6. ТИПИЧНЫЕ ОШИБКИ И BEST PRACTICES
    // ========================================================================

    // ОШИБКА 1: RETAIN CYCLE.
    final class LeakyScreen {
        var handler: (() -> Void)?
        var title = "Hi"
        func setup() {
            handler = { print(self.title) }                // self -> handler -> self: УТЕЧКА
        }
        func setupFixed() {
            handler = { [weak self] in print(self?.title ?? "") }   // цикл разорван
        }
        deinit { print("LeakyScreen deinit") }
    }
    // Когда weak НЕ нужен: non-escaping замыкания (map, filter, sorted),
    // `Task {}` без хранения ссылки на себя в самом себе, одноразовые
    // замыкания, которые не хранит сам self. `unowned` — только когда жизнь
    // self гарантированно длиннее замыкания (иначе crash).

    // ОШИБКА 2: [weak self] + guard let self ВНУТРИ длинной асинхронной цепочки
    //   делает self сильным на всё время выполнения — это нормально для
    //   короткой работы, но не для бесконечных циклов (AsyncStream-loop).
    // ОШИБКА 3: захват изменяемого состояния в @Sendable -> data race.
    // ОШИБКА 4: вызов completion дважды / ни разу (нарушает контракт).
    //   Гарантируй ровно один вызов на всех путях выхода.
    // ОШИБКА 5: замыкание хранится в свойстве без отписки — копит память.
    //
    // Best practices:
    //  - typealias для часто используемых сигнатур: typealias Handler = (Result<T,Error>) -> Void
    //  - completion вызывай на предсказуемой очереди и документируй её
    //  - новые API проектируй как async, completion-версию давай обёрткой
    //  - длинные замыкания выноси в методы; в замыканиях — вызов метода
    //  - для событий-потоков — AsyncStream/Combine, а не `var onChange`

    // ========================================================================
    // 7. ВЗАИМОДЕЙСТВИЕ С ДРУГИМИ МЕХАНИЗМАМИ
    // ========================================================================
    //  SOLID: DIP — зависимость как замыкание; OCP — поведение передаётся
    //         параметром (strategy без класса); SRP — выходы вместо навигации.
    //  Clean Architecture: UseCase = `(Input) async throws -> Output`;
    //         Presenter/ViewModel выставляет onXxx для Coordinator.
    //  Concurrency: @Sendable, @MainActor, `sending`; Task { } — замыкание;
    //         withCheckedContinuation — мост callback -> async.
    //  SwiftUI: Button(action:), .task { }, onChange, Binding(get:set:),
    //         ViewBuilder — всё замыкания.
    //  Combine: sink { }, map { }, tryMap { } — замыкания, их захват
    //         тоже требует [weak self] (см. AnyPublisher_Explanation).

    static func run() async {
        syntaxDemo()
        captureListDemo()
        log("дорогая строка \((1...3).map { $0 })", enabled: false)
        print(compose(multiplier(2), multiplier(5))(3))     // 30

        let api = APIClient.mock
        print((try? await api.fetchUser(1)) ?? "")

        let leaky = LeakyScreen()
        leaky.setupFixed()
        _ = try? await measure("sleep") { try await Task.sleep(for: .milliseconds(10)) }
    }
}
