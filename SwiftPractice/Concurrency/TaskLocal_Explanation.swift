// ============================================================================
// TaskLocal_Explanation.swift
// @TaskLocal: неявный контекст задачи — трассировка запросов, логирование
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: что такое task-local значение и как оно наследуется
//  2. Синтаксис: объявление, withValue, чтение
//  3. Правила наследования (структурные vs неструктурные задачи)
//  4. Сценарии: request-id, логгер, feature-flags, тест-подмена
//  5. Production-пример: сквозная трассировка запроса через слои
//  6. Архитектурный анализ, ошибки, best practices
//
// Типы в неймспейсе `TaskLocalLesson`.
// ============================================================================

import Foundation

enum TaskLocalLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // Проблема: нужно сопроводить ВЕСЬ вызов (десятки функций глубоко)
    // служебным контекстом — идентификатором запроса, пользователем для
    // логов, уровнем детализации. Тащить параметр `requestID` через каждую
    // сигнатуру — шум и нарушение границ слоёв.
    //
    // @TaskLocal — значение, привязанное к ТЕКУЩЕЙ ЗАДАЧЕ и видимое всему
    // коду, исполняемому внутри её области `withValue { ... }`, включая
    // дочерние задачи. Аналог thread-local, но для задач (потоки меняются
    // между await, поэтому thread-local тут бессмысленен).
    //
    // Значение:
    //  - ограничено ОБЛАСТЬЮ (scope): за пределами блока — прежнее
    //  - неизменяемо внутри блока (можно только перекрыть вложенным withValue)
    //  - автоматически наследуется структурными дочерними задачами
    //    (async let, TaskGroup.addTask) и Task { }

    // ========================================================================
    // 2. СИНТАКСИС
    // ========================================================================

    enum Trace {
        // static + @TaskLocal; значение по умолчанию задаётся при объявлении.
        @TaskLocal static var requestID: String?
        @TaskLocal static var verbose = false
    }

    static func basicDemo() async {
        print(Trace.requestID ?? "нет")                       // нет

        await Trace.$requestID.withValue("req-42") {          // входим в область
            print(Trace.requestID ?? "нет")                   // req-42
            await inner()
        }
        print(Trace.requestID ?? "нет")                       // нет: вышли из области
    }
    static func inner() async { print("inner видит:", Trace.requestID ?? "нет") }

    // Вложенное перекрытие
    // withValue с синхронным замыканием не требует await (есть sync-перегрузка).
    static func nestedDemo() {
        Trace.$requestID.withValue("outer") {
            Trace.$requestID.withValue("inner") {
                print(Trace.requestID ?? "")                  // inner
            }
            print(Trace.requestID ?? "")                      // outer
        }
    }

    // ========================================================================
    // 3. ПРАВИЛА НАСЛЕДОВАНИЯ
    // ========================================================================
    //
    //  async let, group.addTask  -> НАСЛЕДУЕТ (структурные дети)
    //  Task { }                  -> НАСЛЕДУЕТ копию значения на момент создания
    //  Task.detached { }         -> НЕ НАСЛЕДУЕТ (чистый лист)
    //  DispatchQueue.async       -> НЕ НАСЛЕДУЕТ (это не задача Swift)
    //  Continuation/callback     -> значение берётся из задачи, которая
    //                               await'ит; из чужого потока оно недоступно.

    static func inheritanceDemo() async {
        await Trace.$requestID.withValue("req-1") {
            async let a: String? = { Trace.requestID }()                  // наследует
            let b = await Task { Trace.requestID }.value                   // наследует
            let c = await Task.detached { Trace.requestID }.value          // НЕ наследует -> nil
            let d = await withTaskGroup(of: String?.self) { g in
                g.addTask { Trace.requestID }                              // наследует
                return await g.next() ?? nil
            }
            print(await a ?? "nil", b ?? "nil", c ?? "nil", d ?? "nil")   // req-1 req-1 nil req-1
        }
    }

    // ========================================================================
    // 4. СЦЕНАРИИ
    // ========================================================================

    // --- A. Логгер, который сам добавляет request-id ---
    struct Logger {
        let subsystem: String
        func log(_ message: String) {
            let id = Trace.requestID.map { "[\($0)] " } ?? ""
            print("\(subsystem): \(id)\(message)")
        }
    }

    // --- B. Подмена зависимости в тестах/превью без изменения сигнатур ---
    // Осторожно: это "скрытая зависимость". Хорошо для Clock/UUID/Date
    // в тестах, плохо как замена нормального DI.
    struct Environment: Sendable {
        var now: @Sendable () -> Date = { Date() }
        var uuid: @Sendable () -> UUID = { UUID() }
    }
    enum Dependencies {
        @TaskLocal static var environment = Environment()
    }

    static func makeOrderID() -> String {
        "order-\(Dependencies.environment.uuid().uuidString.prefix(4))"
    }

    static func testOverrideDemo() async {
        var fake = Environment()
        fake.uuid = { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
        Dependencies.$environment.withValue(fake) {
            print(makeOrderID())                         // order-0000 — детерминированно
        }
    }

    // --- C. Feature-flag/уровень логов на время операции ---
    static func debugOperation() async {
        Trace.$verbose.withValue(true) {
            if Trace.verbose { print("подробный режим для всей цепочки") }
        }
    }

    // ========================================================================
    // 5. PRODUCTION-ПРИМЕР: сквозная трассировка запроса
    // ========================================================================
    //
    //  Интерактор (создаёт trace-id)
    //      └─ UseCase ── Repository ── HTTPClient (добавляет X-Request-ID)
    //                                 └─ Logger (печатает id)
    //  Все слои ничего не знают про id в сигнатурах — он в контексте задачи.

    struct HTTPClient: Sendable {
        func send(path: String) async -> [String: String] {
            var headers = ["path": path]
            if let id = Trace.requestID { headers["X-Request-ID"] = id }   // автоматом
            Logger(subsystem: "http").log("GET \(path)")
            return headers
        }
    }

    struct Repository: Sendable {
        let client: HTTPClient
        func orders() async -> [String: String] {
            Logger(subsystem: "repo").log("загрузка заказов")
            return await client.send(path: "/orders")
        }
    }

    struct UseCase: Sendable {
        let repository: Repository
        func execute() async -> [String: String] {
            Logger(subsystem: "usecase").log("start")
            return await repository.orders()
        }
    }

    /// Точка входа операции: создаём id ОДИН раз.
    static func performUserAction(_ useCase: UseCase) async -> [String: String] {
        await Trace.$requestID.withValue("req-\(UUID().uuidString.prefix(6))") {
            // Параллельные ветки внутри получают тот же id
            async let first = useCase.execute()
            async let second = useCase.execute()
            let (r, _) = await (first, second)
            return r
        }
    }

    // ========================================================================
    // 6. АРХИТЕКТУРНЫЙ АНАЛИЗ, ОШИБКИ, BEST PRACTICES
    // ========================================================================
    //
    // ПОДХОДИТ ДЛЯ: сквозные (cross-cutting) данные: трассировка, логирование,
    //   метрики, locale/timezone операции, тестовые подмены Date/UUID/Clock,
    //   идентификатор пользователя для аудита.
    // НЕ ПОДХОДИТ ДЛЯ: бизнес-данных и обязательных зависимостей — они
    //   должны быть явными параметрами/DI (иначе скрытые связи и ошибки в
    //   runtime вместо compile-time).
    //
    // ПЛЮСЫ: чистые сигнатуры, автоматическая передача по дереву задач,
    //   безопасность (неизменяемость в scope), потокобезопасность.
    // МИНУСЫ: неявность ("магия"), нет значения вне области, не
    //   передаётся через Task.detached и GCD, небольшая стоимость при
    //   множестве значений, трудно искать, откуда пришло значение.
    //
    // ОШИБКИ:
    //  1. Ждать значение в Task.detached / DispatchQueue / delegate-колбэке.
    //  2. Использовать вместо DI для обязательных зависимостей.
    //  3. Пытаться присвоить: `Trace.requestID = "x"` — нельзя, только withValue.
    //  4. Хранить большие объекты (копируется ссылка, но задерживается жизнь).
    //  5. Забыть, что в замыкании, сохранённом и вызванном ПОЗЖЕ, значение
    //     из момента вызова, а не создания.
    //
    // BEST PRACTICES:
    //  - значения Sendable и маленькие (id, флаги)
    //  - сеттить на границе операции (интерактор, обработчик события)
    //  - читать только в инфраструктурных слоях (логгер, HTTP-клиент)
    //  - для конкурирующих систем (swift-log, OpenTelemetry) используют
    //    ровно этот механизм (ServiceContext)

    static func run() async {
        await basicDemo()
        nestedDemo()
        await inheritanceDemo()
        await testOverrideDemo()
        await debugOperation()
        let useCase = UseCase(repository: Repository(client: HTTPClient()))
        print(await performUserAction(useCase))
    }
}
