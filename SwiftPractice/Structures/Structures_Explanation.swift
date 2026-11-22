// ============================================================================
// Structures_Explanation.swift
// MARK 9: Структуры (Structures)
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: что такое struct и value semantics
//  2. Базовый синтаксис: свойства, init, mutating, computed, static
//  3. Практические сценарии (Value Object, DTO, Domain, ViewState, Reducer)
//  4. Production-пример: слой данных и домена в Clean Architecture
//  5. Архитектурный анализ: когда struct, когда class
//  6. Типичные ошибки, ограничения, best practices
//  7. Связь с SOLID, Sendable, многопоточностью, SwiftUI
//
// Все типы вложены в enum-неймспейс `StructuresLesson`, чтобы не конфликтовать
// с типами в main.swift и других учебных файлах (один модуль = одно
// пространство имён). `enum` без case нельзя инстанцировать — это
// идиоматичный "namespace" в Swift.
// ============================================================================

import Foundation

enum StructuresLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // struct — ЗНАЧИМЫЙ тип (value type). При присваивании, передаче в функцию
    // или захвате в замыкание создаётся НЕЗАВИСИМАЯ КОПИЯ.
    // class — ссылочный тип (reference type): копируется только ссылка,
    // объект один.
    //
    // Что умеет struct:
    //  - хранимые и вычисляемые свойства, observers (willSet/didSet)
    //  - методы, static-члены, subscript, extension
    //  - init'ы (memberwise генерируется автоматически)
    //  - соответствие протоколам
    // Чего НЕ умеет:
    //  - наследования (но есть протоколы + композиция)
    //  - deinit (нет identity, нет "времени жизни объекта")
    //  - ссылочной идентичности (===)
    //
    // Почему Apple рекомендует struct по умолчанию:
    //  - предсказуемость: изменение копии не влияет на оригинал
    //  - нет разделяемого изменяемого состояния -> нет data race
    //  - обычно размещается на стеке / inline -> дёшево, без ARC
    //  - автоматический Sendable, Equatable, Hashable, Codable

    // ------------------------------------------------------------------------
    // 2. БАЗОВЫЙ СИНТАКСИС
    // ------------------------------------------------------------------------

    /// Точка на карте. Демонстрирует все основные возможности struct.
    struct Coordinate: Equatable, Hashable, Codable {
        // Хранимые свойства. `let` — неизменяемы после init, `var` — изменяемы
        // (но только если сам экземпляр объявлен через `var`).
        let latitude: Double
        var longitude: Double

        // Memberwise init генерируется АВТОМАТИЧЕСКИ: Coordinate(latitude:longitude:)
        // Но если написать свой init ВНУТРИ тела struct — автогенерация пропадает.
        // Трюк: свой init кладут в extension, тогда memberwise остаётся.

        // Вычисляемое свойство: не хранит значение, считает его при обращении.
        var isValid: Bool {
            (-90...90).contains(latitude) && (-180...180).contains(longitude)
        }

        // static — принадлежит типу, а не экземпляру. Удобно для констант/фабрик.
        static let zero = Coordinate(latitude: 0, longitude: 0)

        // mutating — метод ИЗМЕНЯЕТ self. Для struct это обязательно: иначе
        // компилятор считает self константой внутри метода.
        // Под капотом self передаётся как inout.
        mutating func shiftEast(by degrees: Double) {
            longitude += degrees
        }

        // Неизменяющий метод — возвращает НОВОЕ значение (функциональный стиль).
        func shiftedEast(by degrees: Double) -> Coordinate {
            var copy = self          // копия, а не ссылка
            copy.shiftEast(by: degrees)
            return copy
        }
    }

    // Демонстрация value semantics
    static func valueSemanticsDemo() {
        var a = Coordinate(latitude: 41.31, longitude: 69.24) // Ташкент
        var b = a                 // b — НЕЗАВИСИМАЯ копия
        b.longitude = 0
        print(a.longitude)        // 69.24 — a не изменился
        print(b.longitude)        // 0.0
        a.shiftEast(by: 1)
        print(a == b)             // false — Equatable синтезирован компилятором
    }

    // Observers и lazy: часто встречаются в ViewModel-ах на struct.
    struct Counter {
        var value: Int = 0 {
            willSet { print("перед: \(value) -> \(newValue)") }
            didSet  { print("после: \(oldValue) -> \(value)") }
        }
        // lazy допустим в struct, но делает доступ `mutating`.
        lazy var expensive: [Int] = (0..<1_000).map { $0 * $0 }
    }

    // ========================================================================
    // 3. ПРАКТИЧЕСКИЕ СЦЕНАРИИ
    // ========================================================================

    // ------------------------------------------------------------------------
    // Сценарий A. VALUE OBJECT (DDD): валидация в init, инвариант навсегда.
    // ------------------------------------------------------------------------
    // Идея: невалидное значение НЕВОЗМОЖНО создать -> нет проверок по всему
    // коду. "Make illegal states unrepresentable".

    struct Email: Hashable, Codable {
        let rawValue: String

        enum ValidationError: Error { case invalidFormat }

        // failable/throwing init — единственная точка входа.
        init(_ raw: String) throws {
            let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
            // Упрощённая проверка. В production — NSDataDetector/regex/сервер.
            guard trimmed.contains("@"), trimmed.split(separator: "@").count == 2 else {
                throw ValidationError.invalidFormat
            }
            self.rawValue = trimmed
        }
    }

    /// Деньги: никогда не храните сумму в Double! 0.1 + 0.2 != 0.3.
    /// Храним минимальные единицы (копейки/тийины) в Int.
    struct Money: Hashable, Codable, Comparable {
        let minorUnits: Int      // 1250 = 12.50
        let currency: String     // "UZS", "USD"

        static func < (l: Money, r: Money) -> Bool {
            precondition(l.currency == r.currency, "Разные валюты")
            return l.minorUnits < r.minorUnits
        }
        // Перегрузка оператора: суммирование с защитой от смешивания валют.
        static func + (l: Money, r: Money) -> Money {
            precondition(l.currency == r.currency, "Разные валюты")
            return Money(minorUnits: l.minorUnits + r.minorUnits, currency: l.currency)
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий B. DTO <-> Domain: разделение слоёв (Clean Architecture).
    // ------------------------------------------------------------------------
    // DTO повторяет формат сервера (snake_case, опциональные поля, строки
    // вместо дат). Domain — чистая модель приложения. Mapper между ними.
    // Изменился бэкенд -> правим только DTO и mapper, UI/UseCase не трогаем.

    /// Data layer: ровно то, что приходит с сервера.
    struct UserDTO: Decodable {
        let id: Int
        let full_name: String?
        let email: String?
        let balance_minor: Int?
    }

    /// Domain layer: строгая, без опционалов там, где они не нужны.
    struct User: Identifiable, Equatable, Sendable {
        let id: Int
        let name: String
        let email: Email?
        let balance: Money
    }
    // Email не объявлен Sendable явно — но struct с Sendable-полями (String)
    // получает Sendable неявно, если он не public. См. раздел 7.

    /// Mapper — отдельная struct без состояния: легко тестировать (SRP).
    struct UserMapper {
        func map(_ dto: UserDTO) -> User {
            User(
                id: dto.id,
                name: dto.full_name ?? "Без имени",     // дефолт на границе слоёв
                email: dto.email.flatMap { try? Email($0) },
                balance: Money(minorUnits: dto.balance_minor ?? 0, currency: "UZS")
            )
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий C. VIEW STATE: единственный источник правды для экрана.
    // ------------------------------------------------------------------------
    // Вместо россыпи isLoading/error/items (возможны невозможные комбинации,
    // например isLoading && error != nil) — одно состояние.

    struct ProfileViewState: Equatable {
        enum Phase: Equatable {
            case idle
            case loading
            case loaded(User)
            case failed(message: String)
        }
        var phase: Phase = .idle
        var isRefreshing = false
    }

    // ------------------------------------------------------------------------
    // Сценарий D. REDUCER (стиль Redux / TCA): (State, Action) -> State.
    // ------------------------------------------------------------------------
    // Чистая функция над value type: тривиально тестируется, нет скрытых
    // побочных эффектов, state можно логировать/воспроизводить (time travel).

    struct CartState: Equatable {
        struct Line: Equatable, Identifiable {
            let id: Int
            var title: String
            var price: Money
            var quantity: Int
        }
        var lines: [Line] = []

        var total: Money {
            lines.reduce(Money(minorUnits: 0, currency: "UZS")) {
                $0 + Money(minorUnits: $1.price.minorUnits * $1.quantity,
                           currency: $1.price.currency)
            }
        }
    }

    enum CartAction {
        case add(CartState.Line)
        case remove(id: Int)
        case setQuantity(id: Int, Int)
    }

    enum CartReducer {
        // Принимаем state как inout: мутируем на месте, без лишних копий.
        static func reduce(_ state: inout CartState, _ action: CartAction) {
            switch action {
            case .add(let line):
                if let i = state.lines.firstIndex(where: { $0.id == line.id }) {
                    state.lines[i].quantity += line.quantity
                } else {
                    state.lines.append(line)
                }
            case .remove(let id):
                state.lines.removeAll { $0.id == id }
            case .setQuantity(let id, let q):
                guard let i = state.lines.firstIndex(where: { $0.id == id }) else { return }
                if q <= 0 { state.lines.remove(at: i) } else { state.lines[i].quantity = q }
            }
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий E. КОНФИГУРАЦИЯ + "with"-копирование (иммутабельный builder).
    // ------------------------------------------------------------------------

    struct NetworkConfig {
        var baseURL: URL
        var timeout: TimeInterval = 30
        var retries: Int = 2
        var headers: [String: String] = [:]

        // Паттерн: вернуть изменённую копию — безопасно для разделяемых конфигов.
        func with(_ change: (inout NetworkConfig) -> Void) -> NetworkConfig {
            var copy = self
            change(&copy)
            return copy
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий F. COPY-ON-WRITE для собственной "тяжёлой" struct.
    // ------------------------------------------------------------------------
    // Array/String/Dictionary — struct, но данные в куче с CoW: копия дешёвая
    // (копируется только указатель), реальное копирование — при первой записи.
    // Если у вас struct с большим буфером — повторите приём вручную.

    struct BigBuffer {
        // Внутренний класс — хранилище (reference semantics спрятана внутри).
        private final class Storage {
            var bytes: [UInt8]
            init(_ bytes: [UInt8]) { self.bytes = bytes }
        }
        private var storage: Storage

        init(count: Int) { storage = Storage(Array(repeating: 0, count: count)) }

        var count: Int { storage.bytes.count }
        subscript(i: Int) -> UInt8 {
            get { storage.bytes[i] }
            set {
                // isKnownUniquelyReferenced: true, если на Storage ссылается
                // только эта копия. Иначе клонируем перед записью.
                if !isKnownUniquelyReferenced(&storage) {
                    storage = Storage(storage.bytes)
                }
                storage.bytes[i] = newValue
            }
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий G. Property wrapper — тоже struct (основа @State, @Published).
    // ------------------------------------------------------------------------

    @propertyWrapper
    struct Clamped<Value: Comparable> {
        private var value: Value
        private let range: ClosedRange<Value>

        init(wrappedValue: Value, _ range: ClosedRange<Value>) {
            self.range = range
            self.value = min(max(wrappedValue, range.lowerBound), range.upperBound)
        }
        var wrappedValue: Value {
            get { value }
            set { value = min(max(newValue, range.lowerBound), range.upperBound) }
        }
    }

    struct VolumeSettings {
        @Clamped(0...100) var volume: Int = 50
    }

    // ========================================================================
    // 4. PRODUCTION-ПРИМЕР: фича "Профиль" в Clean Architecture
    // ========================================================================
    //
    //  Presentation (ViewState, ViewModel)
    //        │ зависит от
    //        ▼
    //  Domain (User, Money, UseCase, protocol UserRepository)   <- чистый слой
    //        ▲ реализует
    //        │
    //  Data (UserDTO, UserMapper, RemoteUserRepository)
    //
    // Модели — struct: передаются между слоями и потоками без блокировок.

    protocol UserRepository: Sendable {
        func fetchUser(id: Int) async throws -> User
    }

    /// Use case — одна бизнес-операция (SRP). Сам struct без изменяемого
    /// состояния, поэтому автоматически потокобезопасен.
    struct LoadUserUseCase: Sendable {
        let repository: UserRepository
        func callAsFunction(id: Int) async throws -> User {
            try await repository.fetchUser(id: id)
        }
    }

    /// Фейк для демонстрации/тестов: внедряется через протокол (DIP).
    struct StubUserRepository: UserRepository {
        func fetchUser(id: Int) async throws -> User {
            let dto = UserDTO(id: id, full_name: "Элшод", email: "a@b.uz", balance_minor: 150_000)
            return UserMapper().map(dto)
        }
    }

    @MainActor
    final class ProfileViewModel {
        // ViewState — struct: каждое присваивание = новое консистентное значение.
        private(set) var state = ProfileViewState()
        private let loadUser: LoadUserUseCase

        init(loadUser: LoadUserUseCase) { self.loadUser = loadUser }

        func load(id: Int) async {
            state.phase = .loading
            do {
                state.phase = .loaded(try await loadUser(id: id))
            } catch {
                state.phase = .failed(message: error.localizedDescription)
            }
        }
    }

    // ========================================================================
    // 5. АРХИТЕКТУРНЫЙ АНАЛИЗ: struct или class?
    // ========================================================================
    //
    // ИСПОЛЬЗУЙ struct, когда:
    //  - тип — данные/значение: модель, DTO, конфиг, ViewState, событие
    //  - равенство определяется содержимым, а не идентичностью
    //  - хочешь потокобезопасность "бесплатно" (Sendable)
    //  - нужно безопасно хранить в @State / передавать через Binding
    //
    // ИСПОЛЬЗУЙ class (или actor), когда:
    //  - есть идентичность и жизненный цикл (сессия, сокет, БД-подключение)
    //  - нужно разделяемое изменяемое состояние (кэш — лучше actor)
    //  - нужен deinit (освобождение ресурса), наследование от ObjC-класса
    //  - ViewModel с @Observable (требует class)
    //
    // ИЗБЫТОЧНО:
    //  - struct на 30+ полей, копируемый в горячем цикле -> профилируй,
    //    возможно, нужен CoW-контейнер
    //  - оборачивать каждый String в Value Object: если у типа нет
    //    инварианта/поведения, это церемония без пользы
    //
    // ПЛЮСЫ: предсказуемость, тестируемость, thread-safety, производительность.
    // МИНУСЫ: копии при мутации больших данных; нет наследования; закрытые
    //         циклы ссылок невозможны (граф объектов не выразить без class).

    // ========================================================================
    // 6. ТИПИЧНЫЕ ОШИБКИ И BEST PRACTICES
    // ========================================================================
    //
    //  ОШИБКА 1: struct, хранящий class -> value semantics "дырявая".
    final class Box { var n = 0 }
    struct Leaky { let box = Box() }   // копия Leaky делит ОДИН Box!
    static func leakyDemo() {
        let a = Leaky(); let b = a
        b.box.n = 42
        print(a.box.n) // 42 — сюрприз. Решение: хранить только значимые типы
                       // либо делать CoW как в BigBuffer.
    }
    //
    //  ОШИБКА 2: забыли mutating / пытаются менять `let`-экземпляр.
    //  ОШИБКА 3: Double для денег. Используй Int minor units или Decimal.
    //  ОШИБКА 4: огромный memberwise init с 15 параметрами -> группируй в
    //            вложенные struct (Address, Pricing...).
    //  ОШИБКА 5: Equatable по всем полям там, где нужно по id (кэш/diff).
    //            Для списков используй Identifiable + отдельный Hashable по id.
    //
    // BEST PRACTICES:
    //  - `let` по умолчанию, `var` только если действительно нужно менять
    //  - инварианты — в init (Value Object), не в десяти местах кода
    //  - явный CodingKeys вместо snake_case в Domain-моделях
    //  - модели для API — отдельно от моделей для UI (DTO != Domain != ViewState)
    //  - в Swift 6 / strict concurrency помечай публичные struct `Sendable`
    //    явно: для public типов автоматический вывод НЕ работает.

    // ========================================================================
    // 7. ВЗАИМОДЕЙСТВИЕ С ДРУГИМИ МЕХАНИЗМАМИ
    // ========================================================================
    //
    //  SOLID:
    //   S — каждая struct (Mapper, UseCase, Money) делает одно дело
    //   O — расширяем поведение через extension/протоколы без правки типа
    //   L — struct-реализации протоколов взаимозаменяемы (Stub vs Remote)
    //   I — маленькие протоколы (UserRepository), а не "God interface"
    //   D — UseCase зависит от протокола, а не от конкретного класса
    //
    //  Concurrency: struct из Sendable-полей автоматически Sendable -> можно
    //   свободно передавать между actor'ами и Task'ами (см. Sendable_Explanation).
    //
    //  SwiftUI: View — struct, состояние @State хранит struct-значения;
    //   изменение значения -> новая "версия" -> перерисовка (см. State_Explanation).
    //
    //  Combine/AsyncStream: события — struct/enum-значения, поэтому подписчик
    //   получает снимок и не может случайно изменить состояние издателя.

    /// Запуск всех демо. Вызывается вручную из main.swift при желании.
    static func run() async {
        valueSemanticsDemo()
        leakyDemo()

        var cart = CartState()
        CartReducer.reduce(&cart, .add(.init(id: 1, title: "Чай", price: Money(minorUnits: 12_000, currency: "UZS"), quantity: 2)))
        print("Итого:", cart.total)

        let vm = await ProfileViewModel(loadUser: LoadUserUseCase(repository: StubUserRepository()))
        await vm.load(id: 1)
        print(await vm.state)
    }
}
