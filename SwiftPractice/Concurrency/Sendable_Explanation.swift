// ============================================================================
// Sendable_Explanation.swift
// Sendable, @Sendable, nonisolated, where T: Sendable, @unchecked, sending
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: изоляция, data race, зачем Sendable
//  2. Sendable: правила соответствия для struct/enum/class/actor/замыканий
//  3. @Sendable замыкания
//  4. nonisolated (и nonisolated(unsafe))
//  5. where T: Sendable — generics
//  6. @unchecked Sendable: когда и как безопасно
//  7. Production-пример: потокобезопасный кэш и сервис
//  8. Архитектурный анализ, ошибки, best practices
//  9. Связь с остальными механизмами
//
// Типы в неймспейсе `SendableLesson`.
// ============================================================================

import Foundation

enum SendableLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // DATA RACE: два потока одновременно обращаются к одной памяти и хотя бы
    // один пишет. Результат — непредсказуемость, крэши, порча данных.
    //
    // Swift Concurrency решает это на уровне КОМПИЛЯТОРА через ИЗОЛЯЦИЮ:
    //  - actor изолирует своё состояние (доступ только через await)
    //  - @MainActor — глобальный actor главного потока
    //  - Sendable — маркер "значение МОЖНО безопасно передать через границу
    //    изоляции" (из одной изоляции в другую: main -> actor, Task -> Task).
    //
    // Граница изоляции пересекается при:
    //  - вызове actor-метода снаружи (await)
    //  - Task { } / Task.detached { } / group.addTask { }
    //  - передаче значения в @Sendable замыкание
    //  - возврате результата из другой изоляции
    //
    // Strict concurrency: Swift 5 = предупреждения (включается флагом
    // SWIFT_STRICT_CONCURRENCY=complete), Swift 6 mode = ОШИБКИ.

    // ------------------------------------------------------------------------
    // 2. SENDABLE: КОГДА ТИП БЕЗОПАСНО ПЕРЕДАВАТЬ
    // ------------------------------------------------------------------------

    // (a) struct/enum: Sendable, если ВСЕ хранимые свойства Sendable.
    //     Для internal-типов компилятор выводит это сам; для public — пиши явно.
    struct Point: Sendable { let x: Double; let y: Double }

    enum Event: Sendable {
        case started
        case progress(Double)
        case failed(String)            // String — Sendable, ок
    }

    // struct с НЕ-Sendable полем -> не Sendable:
    final class NotSafe { var counter = 0 }          // изменяемый class
    // struct Bad: Sendable { let box: NotSafe }     // ОШИБКА: stored property 'box'
    //                                               // of Sendable struct has non-Sendable type

    // (b) final class: Sendable, если все свойства `let` и Sendable
    //     (immutable class). Должен быть final и без изменяемого состояния.
    final class Config: Sendable {
        let apiURL: URL
        let timeout: TimeInterval
        init(apiURL: URL, timeout: TimeInterval) { self.apiURL = apiURL; self.timeout = timeout }
    }

    // (c) actor: ВСЕГДА Sendable (сам синхронизирует доступ).
    actor Counter {
        private var value = 0
        func increment() -> Int { value += 1; return value }
    }

    // (d) Класс с изменяемым состоянием + своя синхронизация -> @unchecked
    //     (раздел 6). (e) Глобальный actor-изолированный класс (@MainActor)
    //     тоже Sendable: доступ идёт через main.
    @MainActor
    final class ScreenModel { var title = "" }   // Sendable неявно, т.к. изолирован

    // (f) Функциональные типы: Sendable только при @Sendable (см. раздел 3).
    // (g) Метатипы, Optional/Array/Dictionary/Tuple Sendable-элементов — Sendable.

    // Демонстрация: передача через границу изоляции
    static func crossBoundaryDemo() async {
        let point = Point(x: 1, y: 2)               // Sendable
        let counter = Counter()
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<5 {
                // point копируется в дочернюю задачу — безопасно
                group.addTask { _ = point; return await counter.increment() }
            }
            for await _ in group {}
        }
        print(await counter.increment())            // 6: гонки нет
    }

    // ------------------------------------------------------------------------
    // 3. @Sendable ЗАМЫКАНИЯ
    // ------------------------------------------------------------------------
    //
    // Замыкание, помеченное @Sendable, может быть выполнено параллельно/в
    // другой изоляции. Компилятор тогда запрещает:
    //  - захватывать изменяемые `var` (кроме Sendable-копий через capture list)
    //  - захватывать не-Sendable значения
    //  - (в Swift 6) использовать self не-Sendable класса
    // Сигнатуры Task.init, Task.detached, DispatchQueue.async (в SDK 6),
    // withTaskGroup.addTask уже требуют @Sendable.

    static func sendableClosureDemo() {
        var localCounter = 0
        // DispatchQueue.global().async { localCounter += 1 }   // ПРЕДУПРЕЖДЕНИЕ/ОШИБКА:
        //   mutation of captured var in concurrently-executing code

        // Решение 1: передать копию значения через capture list
        let snapshot = localCounter
        let work: @Sendable () -> Void = { [snapshot] in print("копия:", snapshot) }
        work()
        localCounter += 1

        // Решение 2: изменяемое состояние -> в actor/Mutex, а не в var
    }

    /// API, принимающий @Sendable-замыкание: контракт "выполню в другом потоке".
    static func scheduleBackground(_ job: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).async(execute: job)
    }

    // ------------------------------------------------------------------------
    // 4. NONISOLATED
    // ------------------------------------------------------------------------
    //
    // По умолчанию члены actor / @MainActor-типа изолированы: чтобы вызвать
    // снаружи, нужен await (или main). `nonisolated` СНИМАЕТ изоляцию с
    // конкретного члена — его можно вызывать синхронно из любого контекста.
    // Условие: член не должен трогать изолированное изменяемое состояние.
    //
    // Типичные применения:
    //  - реализация протоколов с синхронными требованиями (Hashable,
    //    Equatable, CustomStringConvertible, Identifiable)
    //  - константы `let` (они Sendable и неизменяемы)
    //  - чистые функции без доступа к состоянию

    actor UserSession {
        nonisolated let id: UUID                 // let + Sendable: доступ без await
        private var token: String?

        init(id: UUID = UUID(), token: String? = nil) {
            self.id = id
            self.token = token
        }

        // Синхронное требование протокола -> nonisolated
        nonisolated var description: String { "Session(\(id))" }   // только let-данные!

        func updateToken(_ t: String) { token = t }               // изолирован: await
        func hasToken() -> Bool { token != nil }                  // изолирован
    }

    // Расширение actor-типа, помеченное nonisolated, для протокола — см.
    // extension в конце файла (extension допустим только на уровне файла).

    @MainActor
    final class ViewModelExample {
        var title = "Загрузка"                       // изолирован на main
        nonisolated let analyticsName = "profile"    // let: безопасно отовсюду
        // nonisolated-метод: чистая функция, не читает `title`
        nonisolated func format(_ n: Int) -> String { "№\(n)" }
    }

    // nonisolated(unsafe) — "я сам отвечаю за безопасность". Для глобальных
    // переменных/статиков, которые инициализируются один раз до конкурентного
    // доступа и дальше только читаются. Любая запись из разных потоков = UB.
    nonisolated(unsafe) static var legacyGlobalConfig = "prod"

    // Swift 6.x: nonisolated async-функции по умолчанию (SE-0461,
    // NonisolatedNonsendingByDefault) выполняются в изоляции ВЫЗЫВАЮЩЕГО.
    // Если нужно явно уйти в параллельный пул — @concurrent.
    // @concurrent static func heavy() async -> Int { ... }

    // ------------------------------------------------------------------------
    // 5. where T: Sendable — GENERICS
    // ------------------------------------------------------------------------
    //
    // Универсальный код, который передаёт T между изоляциями, обязан
    // потребовать `T: Sendable`, иначе компилятор не пропустит.

    /// Выполнить работу параллельно над массивом: элементы и результат
    /// пересекают границы задач => оба должны быть Sendable.
    static func parallelMap<Input: Sendable, Output: Sendable>(
        _ items: [Input],
        transform: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        await withTaskGroup(of: (Int, Output).self) { group in
            for (i, item) in items.enumerated() {
                group.addTask { (i, await transform(item)) }
            }
            var results = [(Int, Output)]()
            for await r in group { results.append(r) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)   // восстановили порядок
        }
    }

    /// `where`-форма: условное соответствие. Box<T> Sendable, только если T Sendable.
    struct Box<T> { var value: T }

    /// Репозиторий-обёртка: ограничение через where в extension.
    protocol Repository {
        associatedtype Item
        func all() async throws -> [Item]
    }

    // `sending` (Swift 6): значение передаётся с ПЕРЕДАЧЕЙ владения — не
    // обязано быть Sendable, но вызывающий больше не вправе его использовать.
    // Полезно для не-Sendable, но "изолированных на момент передачи" объектов.
    static func consume(_ value: sending NotSafe) async { value.counter += 1 }

    // ========================================================================
    // 6. @unchecked Sendable
    // ========================================================================
    //
    // Говорит компилятору: "Не проверяй, я сам гарантирую потокобезопасность".
    // Допустимо, когда синхронизация реализована вручную (lock, serial queue,
    // атомики), либо тип обёртывает уже потокобезопасный ObjC/C-API.
    // Ответственность на вас: ошибка = настоящий data race, который
    // компилятор больше не поймает.

    final class LockedCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Key: Value] = [:]    // изменяемое — защищено lock

        func value(for key: Key) -> Value? { lock.withLock { storage[key] } }
        func set(_ value: Value, for key: Key) { lock.withLock { storage[key] = value } }
    }
    // Современная альтернатива: Synchronization.Mutex (iOS 18+/macOS 15+):
    //   final class Cache: Sendable { let state = Mutex<[Key: Value]>([:]) }
    // — тогда @unchecked не нужен, компилятор доверяет Mutex.

    // ========================================================================
    // 7. PRODUCTION-ПРИМЕР
    // ========================================================================
    //
    // Сервис изображений: кэш (actor), сетевой клиент (Sendable struct),
    // UI-модель (@MainActor). Данные между слоями — Sendable struct.

    struct ImageKey: Hashable, Sendable { let url: URL; let size: Int }
    struct ImageData: Sendable { let bytes: Data }

    /// Клиент без состояния -> Sendable struct, замыкание помечено @Sendable.
    struct ImageDownloader: Sendable {
        let download: @Sendable (URL) async throws -> Data
        static let stub = ImageDownloader { _ in Data([1, 2, 3]) }
    }

    /// Actor — единственное место изменяемого состояния. Дедупликация
    /// одновременных запросов: два вызова на один ключ ждут одну Task.
    actor ImageService {
        private let downloader: ImageDownloader
        private var cache: [ImageKey: ImageData] = [:]
        private var inFlight: [ImageKey: Task<ImageData, Error>] = [:]

        init(downloader: ImageDownloader) { self.downloader = downloader }

        func image(for key: ImageKey) async throws -> ImageData {
            if let hit = cache[key] { return hit }
            if let running = inFlight[key] { return try await running.value }

            // Task наследует изоляцию actor'а -> безопасен доступ к состоянию
            let task = Task<ImageData, Error> {
                ImageData(bytes: try await downloader.download(key.url))
            }
            inFlight[key] = task
            defer { inFlight[key] = nil }          // ВАЖНО: actor reentrancy!
            let result = try await task.value
            cache[key] = result
            return result
        }
    }

    @MainActor
    final class AvatarViewModel {
        private(set) var imageSize = 0
        private let service: ImageService
        init(service: ImageService) { self.service = service }

        func load(_ url: URL) async {
            // ImageKey/ImageData — Sendable => пересекают границу main <-> actor
            if let data = try? await service.image(for: .init(url: url, size: 64)) {
                imageSize = data.bytes.count
            }
        }
    }

    // ========================================================================
    // 8. АРХИТЕКТУРНЫЙ АНАЛИЗ, ОШИБКИ, BEST PRACTICES
    // ========================================================================
    //
    // ЧТО ВЫБРАТЬ ДЛЯ ИЗМЕНЯЕМОГО ОБЩЕГО СОСТОЯНИЯ:
    //   actor              — по умолчанию (async-доступ, компилятор следит)
    //   @MainActor class   — всё, что связано с UI
    //   Mutex / lock + @unchecked — синхронный доступ, горячий путь, нельзя await
    //   struct + Sendable  — данные, пересекающие границы (предпочтительно)
    //
    // ПЛЮСЫ Sendable: гонки ловятся на этапе компиляции; чёткие границы
    //   модулей; масштабируемость больших команд.
    // МИНУСЫ: "вирусность" (Sendable тянется по цепочке), миграция legacy,
    //   многословность generic-кода, @unchecked обходит защиту.
    //
    // ОШИБКИ:
    //  1. Лепить @unchecked Sendable, чтобы "убрать красные ошибки" без
    //     реальной синхронизации. Это замалчивание бага, а не решение.
    //  2. Actor reentrancy: после `await` состояние actor МОГЛО измениться.
    //     Проверяй инварианты заново (см. inFlight выше).
    //  3. Делать class с var Sendable "потому что final".
    //  4. Захват `self` не-Sendable класса в Task.detached.
    //  5. Делать всё @MainActor, включая сетевую логику — блокирует UI.
    //  6. public struct без явного `: Sendable` — вывод не работает для public.
    //
    // BEST PRACTICES:
    //  - модели и события — иммутабельные struct/enum: Sendable бесплатно
    //  - изменяемое общее состояние — actor
    //  - UI-слой — @MainActor; сервисы — nonisolated/свой actor
    //  - включай SWIFT_STRICT_CONCURRENCY=complete заранее, фикси
    //    предупреждения по модулям (снизу вверх: Core -> Data -> UI)
    //  - @preconcurrency import для старых SDK как временная мера

    // ========================================================================
    // 9. СВЯЗЬ С ДРУГИМИ МЕХАНИЗМАМИ
    // ========================================================================
    //  AsyncStream<Element>: Element должен быть Sendable (SDK-события — struct).
    //  Combine: Publisher не Sendable по умолчанию; передача через границы —
    //   через async-обёртки/`values`.
    //  Closures: @Sendable — контракт на захват (см. Closures_Explanation).
    //  Protocols: `protocol Repo: Sendable`, `@MainActor protocol`.
    //  SwiftUI: View и @Observable-модели обычно @MainActor.
    //  Clean Architecture: Domain-модели = Sendable struct; репозитории =
    //   Sendable struct/actor; ViewModel = @MainActor.

    static func run() async {
        await crossBoundaryDemo()
        sendableClosureDemo()
        let squares = await parallelMap([1, 2, 3]) { $0 * $0 }
        print(squares)

        let service = ImageService(downloader: .stub)
        let vm = await AvatarViewModel(service: service)
        await vm.load(URL(string: "https://example.com/a.png")!)
        print(await vm.imageSize)

        let session = UserSession()
        print(session.description)                    // без await: nonisolated
    }
}

// ============================================================================
// EXTENSIONS (только на уровне файла)
// ============================================================================

// Соответствие протоколу с синхронными требованиями: члены должны быть
// nonisolated, иначе actor-изоляция их не пропустит.
extension SendableLesson.UserSession: Hashable, CustomStringConvertible {
    nonisolated static func == (l: SendableLesson.UserSession, r: SendableLesson.UserSession) -> Bool {
        l.id == r.id                                  // читаем только let
    }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// Условное соответствие: Box<T> Sendable, только если T Sendable.
extension SendableLesson.Box: Sendable where T: Sendable {}
