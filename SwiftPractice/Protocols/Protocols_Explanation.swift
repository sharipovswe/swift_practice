// ============================================================================
// Protocols_Explanation.swift
// MARK 10: Протоколы (Protocols)
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория
//  2. Базовый синтаксис (требования, extension, default implementation)
//  3. Практические сценарии (DI, Strategy, associated type, some/any, PAT)
//  4. Production-пример: Repository + Clean Architecture + тестовые моки
//  5. Архитектурный анализ: когда протокол, когда избыточно
//  6. Ошибки и best practices
//  7. Связь с SOLID, Sendable, concurrency, SwiftUI
//
// Все типы в неймспейсе `ProtocolsLesson` (избегаем конфликтов имён в модуле).
// ============================================================================

import Foundation

enum ProtocolsLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // Протокол — КОНТРАКТ: набор требований (свойства, методы, init,
    // subscript, associated types), без реализации. Тип, который объявляет
    // соответствие, обязан их выполнить.
    //
    // Swift — "protocol-oriented": абстракции строят на протоколах, а не на
    // наследовании классов. Причины:
    //  - struct и enum тоже могут соответствовать (у них нет наследования)
    //  - тип может соответствовать МНОГИМ протоколам (множественное
    //    наследование поведения без проблемы ромба)
    //  - протокол + extension = поведение по умолчанию
    //  - "ретроактивное моделирование": добавить соответствие чужому типу
    //    (extension Int: MyProtocol)
    //
    // Динамика vs статика:
    //  - generic <T: P> и `some P`  -> СТАТИЧЕСКАЯ диспетчеризация
    //    (специализация, inlining, быстро)
    //  - `any P` (existential)      -> ДИНАМИЧЕСКАЯ (witness table + box),
    //    медленнее, но гибко: разные типы в одной коллекции.

    // ------------------------------------------------------------------------
    // 2. БАЗОВЫЙ СИНТАКСИС
    // ------------------------------------------------------------------------

    protocol Identifiable2 {
        // { get } — минимум читаемое. { get set } — читаемое и записываемое.
        var id: String { get }
    }

    protocol Describable {
        var title: String { get }
        func describe() -> String
    }

    // Default implementation через extension: тип МОЖЕТ не реализовывать describe.
    // (extension вынесен в конец файла: extension допустим только на уровне файла)

    struct Book: Describable, Identifiable2 {
        let id: String
        let title: String
        // describe() получаем бесплатно
    }

    // Нюанс диспетчеризации! Метод, объявленный В протоколе, диспетчеризуется
    // динамически (witness table) — переопределение в типе сработает даже через
    // `any Describable`. Метод, объявленный ТОЛЬКО в extension, диспетчеризуется
    // статически — по типу переменной. Частая причина "странных" багов.

    struct Magazine: Describable {
        let title: String
        func describe() -> String { "Журнал \(title)" }   // переопределяет default
    }

    // Композиция протоколов
    typealias Entity = Identifiable2 & Describable

    static func printAll(_ items: [any Entity]) {
        items.forEach { print($0.id, $0.describe()) }
    }

    // Constrained extension: поведение только для подходящих типов.
    // (extension вынесен в конец файла: extension допустим только на уровне файла)

    // Retroactive modeling: чужой тип + наш протокол.
    // (extension вынесен в конец файла: extension допустим только на уровне файла)

    // ========================================================================
    // 3. ПРАКТИЧЕСКИЕ СЦЕНАРИИ
    // ========================================================================

    // ------------------------------------------------------------------------
    // Сценарий A. DEPENDENCY INVERSION: сервис зависит от абстракции.
    // ------------------------------------------------------------------------
    // Без протокола тест AnalyticsTracker требовал бы реальную сеть.

    protocol HTTPClient: Sendable {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    }

    /// Боевая реализация поверх URLSession.
    struct URLSessionHTTPClient: HTTPClient {
        let session: URLSession
        init(session: URLSession = .shared) { self.session = session }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, http)
        }
    }

    /// Тестовый мок: возвращает заготовленный ответ, запоминает запросы.
    final class HTTPClientMock: HTTPClient, @unchecked Sendable {
        // @unchecked: защищаем состояние вручную (lock) — мы сами гарантируем
        // потокобезопасность, компилятор нам верит на слово.
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var stub: (Data, HTTPURLResponse)

        init(stub: (Data, HTTPURLResponse)) { self.stub = stub }

        var requests: [URLRequest] { lock.withLock { _requests } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            // withLock — scoped-блокировка, разрешена в async-контексте
            lock.withLock { _requests.append(request) }
            return stub
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий B. STRATEGY: подмена алгоритма (Open/Closed).
    // ------------------------------------------------------------------------

    protocol DiscountStrategy {
        func apply(to amount: Int) -> Int
    }
    struct NoDiscount: DiscountStrategy { func apply(to amount: Int) -> Int { amount } }
    struct PercentDiscount: DiscountStrategy {
        let percent: Int
        func apply(to amount: Int) -> Int { amount - amount * percent / 100 }
    }
    struct Checkout {
        let strategy: any DiscountStrategy       // existential: выбор в runtime
        func total(_ amount: Int) -> Int { strategy.apply(to: amount) }
    }
    // Добавить "BlackFriday" = новый тип. Checkout НЕ меняется (OCP).

    // ------------------------------------------------------------------------
    // Сценарий C. ASSOCIATED TYPE: протоколы с обобщениями (PAT).
    // ------------------------------------------------------------------------
    // Требование "тип, который хранит значения какого-то типа".

    protocol Store {
        associatedtype Key: Hashable
        associatedtype Value
        func value(for key: Key) -> Value?
        mutating func set(_ value: Value, for key: Key)
    }

    struct MemoryStore<K: Hashable, V>: Store {
        private var dict: [K: V] = [:]
        func value(for key: K) -> V? { dict[key] }
        mutating func set(_ value: V, for key: K) { dict[key] = value }
    }

    // Generic-функция над PAT: компилятор знает конкретные Key/Value.
    static func cached<S: Store>(_ store: inout S, key: S.Key, make: () -> S.Value) -> S.Value {
        if let hit = store.value(for: key) { return hit }
        let v = make()
        store.set(v, for: key)
        return v
    }

    // Primary associated types (Swift 5.7+): можно писать `any Sequence<Int>`.
    static func sum(of numbers: any Sequence<Int>) -> Int { numbers.reduce(0, +) }

    // Type erasure вручную (до Swift 5.7 было единственным путём):
    struct AnyStore<K: Hashable, V> {
        private let _get: (K) -> V?
        private let _set: (V, K) -> Void
        init<S: Store>(_ store: S) where S.Key == K, S.Value == V {
            var box = store
            _get = { box.value(for: $0) }
            _set = { box.set($0, for: $1) }
        }
        func value(for k: K) -> V? { _get(k) }
        func set(_ v: V, for k: K) { _set(v, k) }
    }
    // Сегодня чаще достаточно `any Store<...>`/`some Store`, если у протокола
    // объявлены primary associated types.

    // ------------------------------------------------------------------------
    // Сценарий D. some vs any.
    // ------------------------------------------------------------------------

    protocol Shape { func area() -> Double }
    struct Circle: Shape { let r: Double; func area() -> Double { .pi * r * r } }
    struct Square: Shape { let a: Double; func area() -> Double { a * a } }

    // some Shape — ОДИН конкретный тип, скрытый от вызывающего. Быстро.
    static func makeUnit() -> some Shape { Circle(r: 1) }

    // any Shape — любой тип в runtime. Нужна для гетерогенных коллекций.
    static func totalArea(_ shapes: [any Shape]) -> Double { shapes.reduce(0) { $0 + $1.area() } }

    // Правило: начинай с `some`/generic; `any` — когда реально нужна runtime-гибкость.

    // ------------------------------------------------------------------------
    // Сценарий E. Протокол + class-only + weak delegate.
    // ------------------------------------------------------------------------
    // AnyObject-ограничение позволяет `weak` -> нет retain cycle.

    protocol DownloaderDelegate: AnyObject {
        func downloader(_ d: Downloader, didProgress value: Double)
    }
    final class Downloader {
        weak var delegate: DownloaderDelegate?     // weak обязателен для делегатов
        func start() { delegate?.downloader(self, didProgress: 1.0) }
    }

    // ------------------------------------------------------------------------
    // Сценарий F. Optional-требования и ограничения init.
    // ------------------------------------------------------------------------
    // В чистом Swift optional-методов нет: используем default implementation
    // (пустая реализация в extension). @objc optional — только для ObjC-мира.

    protocol ScreenLifecycle {
        func screenWillAppear()
        func screenDidDisappear()
    }
    // (extension вынесен в конец файла: extension допустим только на уровне файла)

    // ========================================================================
    // 4. PRODUCTION-ПРИМЕР: Repository + UseCase + DI-контейнер
    // ========================================================================
    //
    // Domain объявляет протокол (что нужно), Data реализует (как получить).
    // Стрелка зависимости направлена К домену (Dependency Rule).

    struct Product: Equatable, Sendable { let id: Int; let name: String }

    // --- Domain ---
    protocol ProductRepository: Sendable {
        func products() async throws -> [Product]
    }

    // --- Data: две реализации + декоратор кэша (Decorator pattern) ---
    struct RemoteProductRepository: ProductRepository {
        let client: any HTTPClient
        func products() async throws -> [Product] {
            // Запрос + декодирование опущены ради краткости
            [Product(id: 1, name: "Remote")]
        }
    }

    /// Декоратор: оборачивает ЛЮБОЙ ProductRepository, добавляя кэш.
    /// Клиентский код об этом не знает — он видит тот же протокол (LSP).
    actor CachedProductRepository: ProductRepository {
        private let base: any ProductRepository
        private var cache: [Product]?

        init(base: any ProductRepository) { self.base = base }

        func products() async throws -> [Product] {
            if let cache { return cache }
            let fresh = try await base.products()
            cache = fresh
            return fresh
        }
    }

    // --- Domain: UseCase ---
    struct GetProductsUseCase: Sendable {
        let repository: any ProductRepository
        func execute() async throws -> [Product] {
            try await repository.products().sorted { $0.name < $1.name }
        }
    }

    // --- Composition Root: единственное место, где знают конкретные типы ---
    struct AppDependencies {
        let getProducts: GetProductsUseCase

        static func live() -> AppDependencies {
            let client = URLSessionHTTPClient()
            let remote = RemoteProductRepository(client: client)
            let cached = CachedProductRepository(base: remote)
            return AppDependencies(getProducts: GetProductsUseCase(repository: cached))
        }
        static func preview() -> AppDependencies {
            struct Fake: ProductRepository {
                func products() async throws -> [Product] { [Product(id: 0, name: "Preview")] }
            }
            return AppDependencies(getProducts: GetProductsUseCase(repository: Fake()))
        }
    }

    // ========================================================================
    // 5. АРХИТЕКТУРНЫЙ АНАЛИЗ
    // ========================================================================
    //
    // СОЗДАВАЙ протокол, когда:
    //  - есть граница слоёв (Domain <-> Data, Feature <-> Feature)
    //  - нужна подмена в тестах (сеть, БД, время, UUID, Keychain)
    //  - есть >1 реализация (или будет: A/B, платформы, SDK-обёртки)
    //  - нужно скрыть стороннюю зависимость (SDK) за своим интерфейсом
    //
    // НЕ создавай протокол, когда:
    //  - единственная реализация, и подмена не нужна ("протокол ради протокола",
    //    `FooServiceProtocol` на каждый класс) — это шум и стоимость навигации
    //  - тип — чистая модель данных (struct без поведения)
    //  - достаточно замыкания: `var fetch: () async throws -> [Product]`
    //    (см. Closures_Explanation — struct-of-closures вместо протокола)
    //
    // ПЛЮСЫ: тестируемость, слабая связность, параллельная разработка команд.
    // МИНУСЫ: косвенность, existential-накладные расходы (any),
    //         сложность PAT, раздувание числа файлов.

    // ========================================================================
    // 6. ОШИБКИ И BEST PRACTICES
    // ========================================================================
    //  - Широкие протоколы (10+ методов) нарушают ISP: дроби на роли
    //    (Readable/Writable) и собирай композицией `Reader & Writer`.
    //  - Не клади в протокол требований, которые реализуют "заглушкой".
    //  - Метод только в extension НЕ полиморфен (см. раздел 2).
    //  - `any` в горячих циклах — измеряй; предпочитай generics/some.
    //  - Делегаты: AnyObject + weak. Для async-мира замени делегат на
    //    AsyncStream (см. AsyncStream_Explanation).
    //  - Для DI в SwiftUI: Environment/EnvironmentValues или init-инъекция.
    //  - Помечай протоколы репозиториев `Sendable`, если реализации
    //    вызываются из разных изоляций (Swift 6).
    //  - Именование: capability — `Fetching`, `Describable`; роль —
    //    `UserRepository`. Суффикс "Protocol" не нужен.

    // ========================================================================
    // 7. ВЗАИМОДЕЙСТВИЕ С ДРУГИМИ МЕХАНИЗМАМИ
    // ========================================================================
    //  SOLID: протоколы — главный инструмент OCP, LSP, ISP, DIP.
    //  Concurrency: `protocol X: Sendable`, `@MainActor protocol X`,
    //   async-требования (`func f() async throws`). actor может соответствовать
    //   протоколу, если требования async (см. CachedProductRepository).
    //  SwiftUI: View, ViewModifier, Shape, Layout — всё протоколы.
    //  Combine: Publisher/Subscriber — протоколы с associated types;
    //   AnyPublisher — type erasure над ними (см. AnyPublisher_Explanation).
    //  Codable = Encodable & Decodable — композиция протоколов.

    static func run() async {
        printAll([Book(id: "1", title: "Swift") as any Entity])
        let checkout = Checkout(strategy: PercentDiscount(percent: 10))
        print(checkout.total(1000))                      // 900

        var store = MemoryStore<String, Int>()
        print(Self.cached(&store, key: "a") { 42 })           // 42

        let deps = AppDependencies.preview()
        print((try? await deps.getProducts.execute()) ?? [])
    }
}

// ============================================================================
// EXTENSIONS (должны быть на уровне файла, не внутри enum-неймспейса)
// ============================================================================

extension ProtocolsLesson.Describable {
    func describe() -> String { "«\(title)»" }
}

extension Collection where Element: ProtocolsLesson.Describable {
    func joinedTitles() -> String { map(\.title).joined(separator: ", ") }
}

extension Int: ProtocolsLesson.Describable {
    var title: String { "Число \(self)" }
}

extension ProtocolsLesson.ScreenLifecycle {
    func screenWillAppear() {}
    func screenDidDisappear() {}
}
