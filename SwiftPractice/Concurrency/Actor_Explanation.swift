// ============================================================================
// Actor_Explanation.swift
// actor: изоляция, reentrancy, isolated-параметры, Mutex, свой GlobalActor
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: что гарантирует actor, а что НЕТ
//  2. Базовый синтаксис и правила доступа
//  3. REENTRANCY — главная ловушка (4 сценария с исправлениями)
//  4. isolated-параметры, `#isolation`, assumeIsolated
//  5. Mutex (Synchronization): когда лучше actor, когда лучше Mutex
//  6. Свой GlobalActor
//  7. Production-пример: токен-менеджер с однократным refresh
//  8. Архитектурный анализ, ошибки, best practices
//
// Типы в неймспейсе `ActorLesson`.
// ============================================================================

import Foundation
import Synchronization

enum ActorLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // actor — ссылочный тип, который ПОСЛЕДОВАТЕЛЬНО (по одному) исполняет
    // доступ к своему изменяемому состоянию. Аналог serial-очереди, но
    // проверяемый компилятором и без блокировки потока.
    //
    // Гарантирует:  в любой момент внутри actor исполняется НЕ БОЛЕЕ ОДНОГО
    //               синхронного фрагмента кода -> нет data race на его свойствах.
    // НЕ гарантирует: атомарность между `await`. Пока actor ждёт await,
    //               он ОСВОБОЖДАЕТСЯ и может обработать другой вызов
    //               (REENTRANCY). Состояние после await может отличаться.
    // НЕ гарантирует: порядок FIFO вызовов (планировщик не обязан).
    // НЕ гарантирует: что код выполнится на конкретном потоке.
    //
    // Все члены actor изолированы. Снаружи доступ — через `await`.
    // `let`-свойства Sendable-типов читаются без await (неизменяемы).

    // ------------------------------------------------------------------------
    // 2. БАЗА
    // ------------------------------------------------------------------------

    actor BankAccount {
        let owner: String                  // let: читается снаружи без await
        private(set) var balance: Int      // читается снаружи через await

        init(owner: String, balance: Int) { self.owner = owner; self.balance = balance }

        func deposit(_ amount: Int) { balance += amount }       // внутри: синхронно

        func withdraw(_ amount: Int) throws {
            guard balance >= amount else { throw AccountError.insufficientFunds }
            balance -= amount                                    // проверка+запись атомарны:
        }                                                        // между ними нет await

        // Синхронная операция над ДВУМЯ акторами нельзя -> делаем через await
        func transfer(_ amount: Int, to other: BankAccount) async throws {
            try withdraw(amount)
            await other.deposit(amount)       // await: возможна приостановка (reentrancy!)
        }
    }
    enum AccountError: Error { case insufficientFunds }

    static func basicDemo() async throws {
        let a = BankAccount(owner: "A", balance: 100)
        let b = BankAccount(owner: "B", balance: 0)
        print(a.owner)                         // без await: let
        try await a.transfer(30, to: b)
        print(await a.balance, await b.balance)  // 70 30
    }

    // ========================================================================
    // 3. REENTRANCY
    // ========================================================================
    //
    // Правило: ВСЁ, что проверено ДО await, надо перепроверить ПОСЛЕ await.
    // Либо не иметь await между проверкой и действием.

    // --- Сценарий 3.1. Двойное списание (БАГ) ---
    actor BuggyWallet {
        private var balance = 100

        func spend(_ amount: Int) async -> Bool {
            guard balance >= amount else { return false }      // (1) проверили
            await auditLog(amount)                             // (2) ПРИОСТАНОВКА: actor свободен
            balance -= amount                                  // (3) состояние могло измениться!
            return true
        }
        private func auditLog(_ amount: Int) async { try? await Task.sleep(for: .milliseconds(10)) }
        var current: Int { balance }
    }
    // Два параллельных spend(80): оба проходят проверку (balance=100), потом
    // оба списывают -> баланс -60.

    // --- Исправление 3.1: действие ДО await, await — после (или перепроверка) ---
    actor FixedWallet {
        private var balance = 100

        func spend(_ amount: Int) async -> Bool {
            guard balance >= amount else { return false }
            balance -= amount                                  // резервируем сразу
            await auditLog(amount)                             // потом await
            return true
        }
        private func auditLog(_ amount: Int) async { try? await Task.sleep(for: .milliseconds(10)) }
        var current: Int { balance }
    }

    static func reentrancyDemo() async {
        let buggy = BuggyWallet()
        async let r1 = buggy.spend(80)
        async let r2 = buggy.spend(80)
        _ = await (r1, r2)
        print("buggy:", await buggy.current)       // -60  (!)

        let fixed = FixedWallet()
        async let f1 = fixed.spend(80)
        async let f2 = fixed.spend(80)
        _ = await (f1, f2)
        print("fixed:", await fixed.current)       // 20
    }

    // --- Сценарий 3.2. Дублирование дорогой работы -> дедупликация inFlight ---
    // Без неё 10 одновременных запросов одного URL = 10 загрузок.
    actor Downloader {
        private var cache: [URL: Data] = [:]
        private var inFlight: [URL: Task<Data, Error>] = [:]
        private(set) var networkCalls = 0

        func data(for url: URL) async throws -> Data {
            if let cached = cache[url] { return cached }
            if let task = inFlight[url] { return try await task.value }   // присоединяемся

            // Task внутри actor наследует изоляцию -> безопасно трогать состояние
            let task = Task { () throws -> Data in
                networkCalls += 1
                try await Task.sleep(for: .milliseconds(20))              // "сеть"
                return Data(url.absoluteString.utf8)
            }
            inFlight[url] = task
            defer { inFlight[url] = nil }
            let result = try await task.value
            cache[url] = result                                           // запись после await — ок
            return result
        }
    }

    // --- Сценарий 3.3. Инвариант между двумя await -> "ждать пока свободно" ---
    // Нужен эксклюзивный доступ ДАЖЕ через await? Actor этого НЕ даст. Решение:
    // очередь/семафор-на-continuation (ниже) либо перенос await за пределы actor.
    actor AsyncLock {
        private var isLocked = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !isLocked { isLocked = true; return }
            await withCheckedContinuation { waiters.append($0) }   // ждём очереди FIFO
        }
        func release() {
            if waiters.isEmpty { isLocked = false }
            else { waiters.removeFirst().resume() }                // передаём владение следующему
        }
        func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
            await acquire()
            defer { release() }
            return try await body()
        }
    }

    // --- Сценарий 3.4. Не держи actor занятым тяжёлой синхронной работой ---
    // Долгий синхронный код внутри actor блокирует ВСЕХ его клиентов.
    // Выноси CPU-работу в nonisolated async / отдельную задачу:
    actor ImageProcessor {
        private var processedCount = 0
        func process(_ input: [UInt8]) async -> [UInt8] {
            let output = await Task.detached { input.map { $0 &+ 1 } }.value   // вне actor
            processedCount += 1                                                 // назад в actor
            return output
        }
    }

    // ========================================================================
    // 4. ISOLATED-ПАРАМЕТРЫ, #isolation, assumeIsolated
    // ========================================================================

    // `isolated` параметр: функция исполняется В изоляции переданного actor'а.
    // Внутри — синхронный доступ к его состоянию, без await на каждый вызов.
    // Применение: пакетные операции над actor (один "заход" вместо N await).
    static func batchDeposit(_ amounts: [Int], into account: isolated BankAccount) {
        for a in amounts { account.deposit(a) }       // синхронно, без await
    }
    static func batchDemo() async {
        let acc = BankAccount(owner: "C", balance: 0)
        await batchDeposit([1, 2, 3], into: acc)       // ОДИН await на весь пакет
        print(await acc.balance)                       // 6
    }

    // Наследование изоляции вызывающего (Swift 6): generic-хелпер, работающий
    // в изоляции того, кто вызвал.
    static func logIsolation(_ isolation: isolated (any Actor)? = #isolation) {
        print("в изоляции:", isolation.map { "\(type(of: $0))" } ?? "нет (nonisolated)")
    }

    // assumeIsolated: "я уверен, что мы сейчас на этом actor" — проверка в
    // runtime (crash при ошибке). Нужен для старых синхронных callback'ов,
    // которые документированно приходят на нужной очереди/потоке.
    @MainActor
    final class LegacyBridge {
        var value = 0
        nonisolated func callbackFromMainQueue() {
            MainActor.assumeIsolated { self.value += 1 }
        }
    }

    // ========================================================================
    // 5. Mutex (Synchronization, iOS 18+/macOS 15+)
    // ========================================================================
    //
    // Mutex<State> — потокобезопасный контейнер: доступ только внутри
    // `withLock`. Компилятор считает Mutex Sendable -> класс со `let mutex`
    // может быть Sendable БЕЗ @unchecked.
    //
    // actor vs Mutex:
    //   actor: async-доступ, подходит для логики с await внутри,
    //          состояние сложное, нужна изоляция всего объекта.
    //   Mutex: СИНХРОННЫЙ доступ (нельзя `await` внутри withLock!), очень
    //          короткие критические секции, горячий путь (счётчики, кэш
    //          значений), интеграция с синхронным API (init, deinit,
    //          delegate-методы, свойства).

    final class MemoryCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
        private let storage = Mutex<[Key: Value]>([:])

        func value(for key: Key) -> Value? { storage.withLock { $0[key] } }
        func set(_ value: Value, for key: Key) { storage.withLock { $0[key] = value } }

        /// Атомарный "get or create": check-then-act внутри ОДНОЙ секции.
        func getOrCreate(_ key: Key, make: () -> Value) -> Value {
            storage.withLock { dict in
                if let v = dict[key] { return v }
                let v = make()
                dict[key] = v
                return v
            }
        }
    }

    final class Counter: Sendable {
        private let count = Mutex(0)
        func increment() -> Int { count.withLock { $0 += 1; return $0 } }
    }
    // ЗАПРЕЩЕНО: await внутри withLock (замок держится через приостановку ->
    // deadlock). Компилятор не даёт: замыкание синхронное.

    // ========================================================================
    // 6. СВОЙ GlobalActor
    // ========================================================================
    //
    // @MainActor — один из глобальных акторов. Можно объявить свой, чтобы
    // "привязать" набор типов/функций к ОДНОМУ последовательному контексту
    // (БД, аудио-движок, графический движок, Realm/CoreData-контекст).
    //
    // Плюс над обычным actor: изоляцию можно навесить на МНОГО разных типов и
    // свободных функций, и они все делят один последовательный контекст.

    @globalActor
    actor DatabaseActor {
        static let shared = DatabaseActor()
    }

    @DatabaseActor
    final class UserDatabase {
        private var rows: [Int: String] = [:]          // изолировано на DatabaseActor
        nonisolated init() {}                          // создавать можно из любой изоляции
        func insert(id: Int, name: String) { rows[id] = name }
        func name(id: Int) -> String? { rows[id] }
    }

    @DatabaseActor
    static func migrateDatabase() { print("миграция выполняется на DatabaseActor") }  // static-функция тоже может быть на глобальном акторе (так же и свободная вне enum)

    static func globalActorDemo() async {
        let db = UserDatabase()                        // создание из другой изоляции
        await db.insert(id: 1, name: "Элшод")
        print(await db.name(id: 1) ?? "—")
        await migrateDatabase()
    }

    // Кастомный executor (Swift 5.9+): actor может исполняться на заданной
    // очереди/потоке через `unownedExecutor` — для интеграции с C/ObjC API,
    // которые требуют конкретный поток. Редко; применять осознанно.

    // ========================================================================
    // 7. PRODUCTION-ПРИМЕР: TokenManager — единственный refresh
    // ========================================================================
    //
    // Проблема: 20 запросов получили 401 одновременно. Наивно — 20 refresh-
    // запросов, сервер инвалидирует токены, пользователь разлогинен.
    // Решение: actor + одна Task refresh; остальные ждут её результат.

    struct Token: Sendable, Equatable { let value: String; let expiresAt: Date
        var isExpired: Bool { expiresAt <= Date() } }

    actor TokenManager {
        private var token: Token
        private var refreshTask: Task<Token, Error>?
        private let refresh: @Sendable () async throws -> Token     // зависимость-замыкание

        init(initial: Token, refresh: @escaping @Sendable () async throws -> Token) {
            self.token = initial
            self.refresh = refresh
        }

        func validToken() async throws -> Token {
            if !token.isExpired { return token }
            if let task = refreshTask { return try await task.value }   // присоединяемся к идущему
            let task = Task { try await refresh() }
            refreshTask = task
            defer { refreshTask = nil }                                  // сброс при любом исходе
            let newToken = try await task.value
            token = newToken                                             // запись после await
            return newToken
        }
    }

    static func tokenDemo() async throws {
        let calls = Mutex(0)
        let manager = TokenManager(
            initial: Token(value: "old", expiresAt: .distantPast),
            refresh: {
                calls.withLock { $0 += 1 }
                try await Task.sleep(for: .milliseconds(30))
                return Token(value: "new", expiresAt: .distantFuture)
            }
        )
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await manager.validToken().value } }
            for try await _ in group {}
        }
        print("refresh вызван раз:", calls.withLock { $0 })        // 1
    }

    // ========================================================================
    // 8. АРХИТЕКТУРНЫЙ АНАЛИЗ, ОШИБКИ, BEST PRACTICES
    // ========================================================================
    //
    // ИСПОЛЬЗУЙ actor: общее изменяемое состояние с async-логикой (кэш с
    //   сетью, токены, очередь загрузок, координатор синхронизации).
    // ИСПОЛЬЗУЙ @MainActor: UI и всё, что должно быть на main.
    // ИСПОЛЬЗУЙ Mutex: короткие синхронные секции, горячий путь, нужен
    //   синхронный API (init/deinit/свойства).
    // ИСПОЛЬЗУЙ struct+Sendable: если состояние можно не разделять.
    // ИЗБЫТОЧНО: actor вокруг неизменяемых данных или одного флага;
    //   actor "на каждый сервис" без реального общего состояния.
    //
    // ПЛЮСЫ: проверка компилятором, нет блокировок потока, читаемость.
    // МИНУСЫ: reentrancy, async-вирусность, нет синхронного доступа,
    //   "actor hopping" стоит ресурсов, узкое место при тяжёлых вызовах.
    //
    // ОШИБКИ:
    //  1. Check-then-act через await (см. 3.1).
    //  2. Долгая синхронная работа в actor -> очередь клиентов стоит.
    //  3. Ожидание FIFO-порядка.
    //  4. await на каждый маленький вызов в цикле -> используй isolated-пакет.
    //  5. Возврат из actor ссылочного не-Sendable объекта (утечка изоляции).
    //  6. actor для UI-модели вместо @MainActor.
    //  7. `await` внутри Mutex.withLock — невозможно/deadlock.
    //  8. Забыли `defer` при сбросе inFlight -> навсегда зависший ключ.
    //
    // BEST PRACTICES:
    //  - Меняй состояние СИНХРОННО в одном блоке, await — до или после
    //  - После каждого await перепроверяй допущения
    //  - Дедупликация через словарь inFlight: [Key: Task]
    //  - Маленькие actor'ы с одной ответственностью
    //  - Наружу отдавай Sendable-значения (struct), а не внутренние объекты

    static func run() async throws {
        try await basicDemo()
        await reentrancyDemo()
        await batchDemo()
        await globalActorDemo()
        try await tokenDemo()

        let dl = Downloader()
        let url = URL(string: "https://example.com/a")!
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<10 { g.addTask { _ = try? await dl.data(for: url) } }
        }
        print("сетевых вызовов:", await dl.networkCalls)            // 1
    }
}
