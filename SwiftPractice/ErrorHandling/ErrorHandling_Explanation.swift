// ============================================================================
// ErrorHandling_Explanation.swift
// MARK 11: Обработка ошибок (Error Handling)
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: Error, throw, throws, try, do/catch
//  2. Синтаксис: try / try? / try! / rethrows / defer / typed throws
//  3. Сценарии: валидация, Result, async throws, TaskGroup, отмена
//  4. Production: иерархия ошибок по слоям + маппинг + retry с backoff
//  5. Архитектурный анализ
//  6. Ошибки и best practices
//  7. Связь с SOLID, Clean Architecture, concurrency
//
// Типы в неймспейсе `ErrorHandlingLesson`.
// ============================================================================

import Foundation

enum ErrorHandlingLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // Error — пустой протокол-маркер. Любой тип (обычно enum) может быть
    // ошибкой. Ошибки в Swift — ОБЫЧНЫЙ поток управления, не исключения C++:
    // нет дорогой раскрутки стека; `throws` — второй "канал" возврата.
    // Поэтому бросать ошибки дёшево.
    //
    // Правила:
    //  - функция, которая может бросить, помечается `throws`
    //  - вызов — только с `try` (в коде видно, где возможен сбой)
    //  - обработка — `do { } catch { }` либо проброс вверх (`throws`)
    //
    // Что НЕ является Error:
    //  - ошибки программиста (индекс вне границ, force-unwrap nil, нарушение
    //    precondition) -> crash. Их нужно ИСПРАВИТЬ, не обработать.
    //  - "нормальное отсутствие значения" -> Optional, а не throws.

    // ------------------------------------------------------------------------
    // 2. БАЗОВЫЙ СИНТАКСИС
    // ------------------------------------------------------------------------

    enum ValidationError: Error, Equatable {
        case empty
        case tooShort(min: Int)              // associated value несёт контекст
        case forbiddenCharacter(Character)
    }

    // throws-функция
    static func validate(password: String) throws {
        guard !password.isEmpty else { throw ValidationError.empty }
        guard password.count >= 8 else { throw ValidationError.tooShort(min: 8) }
        if let bad = password.first(where: { $0 == " " }) {
            throw ValidationError.forbiddenCharacter(bad)
        }
    }

    static func syntaxDemo() {
        // 1) do/catch с паттернами: ловим конкретные кейсы, затем общий.
        do {
            try validate(password: "abc")
        } catch ValidationError.empty {
            print("пусто")
        } catch ValidationError.tooShort(let min) {
            print("минимум \(min) символов")
        } catch {
            // `error` — неявная константа в общем catch
            print("другая ошибка: \(error)")
        }

        // 2) try? — превращает ошибку в nil. Теряем причину! Только когда
        //    причина не важна (необязательный кэш, опциональная фича).
        let ok: Void? = try? validate(password: "12345678")
        print(ok != nil)

        // 3) try! — crash при ошибке. Допустимо ТОЛЬКО для заведомо
        //    корректных констант (например, статический regex в коде).
        // try! validate(password: "")   // упадёт

        // 4) defer — гарантированная очистка при любом выходе (return/throw).
        func readFile() throws {
            let handle = FileHandle.nullDevice
            defer { try? handle.close() }          // выполнится ВСЕГДА
            throw ValidationError.empty
        }
        try? readFile()
    }

    // LocalizedError: текст для пользователя, отдельно от технических деталей.
    enum LoginError: LocalizedError {
        case invalidCredentials
        case accountLocked(until: Date)
        case network(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .invalidCredentials: return "Неверный логин или пароль"
            case .accountLocked:      return "Аккаунт временно заблокирован"
            case .network:            return "Проблема с сетью. Попробуйте позже"
            }
        }
    }

    // rethrows: функция бросает ТОЛЬКО если бросает переданное замыкание.
    // Так устроены map/filter: map с не-бросающим замыканием не требует try.
    static func applyTwice<T>(_ value: T, _ f: (T) throws -> T) rethrows -> T {
        try f(try f(value))
    }

    // Typed throws (Swift 6.0+): указываем конкретный тип ошибки.
    // Плюс: exhaustive catch без `as?`; нет existential-бокса (быстрее,
    // важно для embedded). Минус: усложняет API-эволюцию — используй
    // внутри модуля, для публичного API осторожно.
    static func parseAge(_ s: String) throws(ParseError) -> Int {
        guard let n = Int(s) else { throw .notANumber }
        guard (0...150).contains(n) else { throw .outOfRange }
        return n
    }
    enum ParseError: Error { case notANumber, outOfRange }

    static func typedThrowsDemo() {
        do {
            _ = try parseAge("200")
        } catch {
            // error здесь имеет тип ParseError, не `any Error`
            switch error {
            case .notANumber: print("не число")
            case .outOfRange: print("вне диапазона")
            }
        }
    }

    // ========================================================================
    // 3. ПРАКТИЧЕСКИЕ СЦЕНАРИИ
    // ========================================================================

    // ------------------------------------------------------------------------
    // Сценарий A. Result<Success, Failure> — ошибка как ЗНАЧЕНИЕ.
    // ------------------------------------------------------------------------
    // Нужен, где throws недоступен: callback-API (старые SDK), хранение
    // результата (кэш последней попытки), Combine, передача между потоками.
    // В async-коде предпочитай async throws — он короче и безопаснее.

    static func legacyFetch(completion: @escaping (Result<Int, Error>) -> Void) {
        DispatchQueue.global().async { completion(.success(42)) }
    }

    /// Мост callback -> async/await. Ключевой приём миграции старого кода.
    static func fetchAsync() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            legacyFetch { result in
                // Result -> resume(with:) вызывается РОВНО ОДИН раз.
                continuation.resume(with: result)
            }
        }
    }

    // Result <-> throws
    static func resultDemo() {
        let r: Result<Int, ValidationError> = .failure(.empty)
        let value = try? r.get()                 // get() бросает failure
        let mapped = r.map { $0 * 2 }            // map только для success
        let recovered: Result<Int, ValidationError> = r.flatMapError { _ in .success(0) }
        print(value as Any, mapped, recovered)

        // Захват throwing-выражения в Result:
        let captured = Result { try validate(password: "short") }
        print(captured)
    }

    // ------------------------------------------------------------------------
    // Сценарий B. Ошибки в структурной конкурентности.
    // ------------------------------------------------------------------------

    /// withThrowingTaskGroup: первая брошенная ошибка ОТМЕНЯЕТ остальные задачи
    /// группы и пробрасывается наружу. Пример: загрузка набора ресурсов
    /// "всё или ничего".
    static func loadAll(ids: [Int]) async throws -> [Int] {
        try await withThrowingTaskGroup(of: Int.self) { group in
            for id in ids {
                group.addTask {
                    // Cooperative cancellation: проверяем отмену вручную.
                    try Task.checkCancellation()     // бросает CancellationError
                    if id < 0 { throw ValidationError.empty }
                    return id * 2
                }
            }
            var result: [Int] = []
            for try await value in group { result.append(value) }
            return result
        }
    }

    /// Частичный успех: не прерываем всё из-за одного сбоя. Каждый элемент —
    /// Result, агрегируем сами. Нужно для "загрузить что получится".
    static func loadBestEffort(ids: [Int]) async -> [Result<Int, Error>] {
        await withTaskGroup(of: Result<Int, Error>.self) { group in
            for id in ids {
                group.addTask { Result { if id < 0 { throw ValidationError.empty }; return id } }
            }
            var all: [Result<Int, Error>] = []
            for await r in group { all.append(r) }
            return all
        }
    }

    // CancellationError — НЕ сбой, а штатный сигнал. Не показывай алерт
    // пользователю и не отправляй в крэш-репортинг:
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // ========================================================================
    // 4. PRODUCTION-ПРИМЕР: ошибки по слоям + маппинг + retry
    // ========================================================================
    //
    // Принцип: каждый слой имеет СВОИ ошибки; на границе — маппинг.
    // Тогда UI не знает про URLError/SQLite/статус-коды, а Domain не
    // зависит от инфраструктуры.
    //
    //   Data:    HTTPError / DecodingError / URLError   (технические)
    //      │ map
    //   Domain:  UserError.notFound / .unauthorized ...  (бизнес-смысл)
    //      │ map
    //   UI:      ErrorViewModel(title, message, action)  (презентация)

    // --- Data ---
    enum HTTPError: Error {
        case status(Int, body: Data)
        case transport(URLError)
        case decoding(DecodingError)
    }

    // --- Domain ---
    enum UserError: Error, Equatable {
        case notFound
        case unauthorized
        case offline
        case server           // 5xx
        case unknown
    }

    /// Маппер — чистая функция: тривиально покрывается юнит-тестами.
    static func mapToDomain(_ error: Error) -> UserError {
        switch error {
        case let HTTPError.status(code, _):
            switch code {
            case 401, 403: return .unauthorized
            case 404:      return .notFound
            case 500...:   return .server
            default:       return .unknown
            }
        case let HTTPError.transport(urlError):
            return urlError.code == .notConnectedToInternet ? .offline : .unknown
        default:
            return .unknown
        }
    }

    // --- Presentation ---
    struct ErrorViewModel: Equatable {
        let title: String
        let message: String
        let canRetry: Bool

        init(_ error: UserError) {
            switch error {
            case .offline:
                title = "Нет сети"; message = "Проверьте подключение"; canRetry = true
            case .unauthorized:
                title = "Сессия истекла"; message = "Войдите снова"; canRetry = false
            case .notFound:
                title = "Не найдено"; message = "Объект удалён"; canRetry = false
            case .server, .unknown:
                title = "Ошибка"; message = "Попробуйте позже"; canRetry = true
            }
        }
    }

    // --- Retry с экспоненциальным backoff (устойчивость к сбоям) ---
    //
    // Повторяем ТОЛЬКО транзитные ошибки (сеть, 5xx). Ошибки клиента
    // (401/404/валидация) повторять бессмысленно.
    // `operation` — async-замыкание: функция универсальна и тестируется
    // подстановкой замыкания (см. Closures_Explanation).
    static func retrying<T>(
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(200),
        shouldRetry: (Error) -> Bool = { mapToDomain($0) == .offline || mapToDomain($0) == .server },
        operation: () async throws -> T
    ) async throws -> T {
        var delay = initialDelay
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                // Отмену не повторяем и не глотаем — пробрасываем немедленно.
                if isCancellation(error) { throw error }
                guard attempt < maxAttempts, shouldRetry(error) else { throw error }
                try await Task.sleep(for: delay)     // бросает при отмене
                delay *= 2                           // 200ms, 400ms, 800ms ...
                attempt += 1
            }
        }
    }

    /// Репозиторий: ловит технические ошибки, отдаёт доменные.
    struct UserRepository {
        let fetch: () async throws -> String        // зависимость как замыкание

        func user() async throws -> String {
            do {
                return try await Self.retryingFetch(fetch)
            } catch {
                if isCancellation(error) { throw error }
                throw mapToDomain(error)             // граница слоя
            }
        }
        private static func retryingFetch(_ f: () async throws -> String) async throws -> String {
            try await ErrorHandlingLesson.retrying(operation: f)
        }
    }

    // ViewModel: превращает ошибку в состояние экрана.
    @MainActor
    final class UserScreenModel {
        enum State: Equatable { case loading, content(String), failure(ErrorViewModel) }
        private(set) var state: State = .loading
        private let repo: UserRepository
        init(repo: UserRepository) { self.repo = repo }

        func load() async {
            state = .loading
            do {
                state = .content(try await repo.user())
            } catch is CancellationError {
                // тихо выходим: пользователь ушёл с экрана
            } catch let e as UserError {
                state = .failure(ErrorViewModel(e))
            } catch {
                state = .failure(ErrorViewModel(.unknown))
            }
        }
    }

    // ========================================================================
    // 5. АРХИТЕКТУРНЫЙ АНАЛИЗ: что выбрать?
    // ========================================================================
    //
    //  throws / async throws  — по умолчанию. Ошибка = исключительный путь.
    //  Optional               — отсутствие значения без причины (поиск в словаре).
    //  Result                 — хранение/передача исхода как значения,
    //                           callback-API, агрегация (best effort).
    //  Typed throws           — внутренние модули, где набор ошибок замкнут.
    //  fatalError/precondition— нарушены инварианты программы (баг).
    //
    // ПЛЮСЫ: компилятор заставляет обработать (try), ошибки дёшевы, enum с
    //        associated values выразителен, хорошо тестируется.
    // МИНУСЫ: `any Error` стирает тип (нужен каст); легко "проглотить" через
    //         try?; нет проверки, какие именно ошибки бросает функция
    //         (до typed throws); много маппинга между слоями.
    //
    // ИЗБЫТОЧНО: отдельный enum ошибок на каждую мелкую функцию; оборачивать
    // каждую ошибку в три слоя в маленьком приложении.

    // ========================================================================
    // 6. ТИПИЧНЫЕ ОШИБКИ И BEST PRACTICES
    // ========================================================================
    //  1. `catch { }` пустой — молчаливая потеря ошибки. Минимум логируй.
    //  2. try? там, где нужна причина (логин, платёж).
    //  3. Протекание деталей инфраструктуры в UI (показ "URLError -1009").
    //  4. Повтор НЕидемпотентных операций (POST оплаты) без idempotency-key.
    //  5. Показ алерта на CancellationError.
    //  6. Двойной resume у continuation -> crash/UB. Ровно один раз!
    //  7. Бросать строки: `throw "oops"` невозможно, и правильно — заводи тип.
    //  8. Один гигантский enum `AppError` на всё приложение -> связность.
    //     Лучше ошибки на фичу/модуль.
    //  9. Не делай ошибки class: enum/struct + Sendable (Error уже Sendable
    //     с Swift 5.5+).
    //
    // Best practices:
    //  - Error-типы: enum + associated values + Equatable (для тестов)
    //  - LocalizedError только на границе UI
    //  - Логируй технические детали, показывай пользователю человеческие
    //  - Для критических потоков — retry только для транзитных ошибок
    //  - Тесты: проверяй и успешный, и каждый путь ошибки

    // ========================================================================
    // 7. ВЗАИМОДЕЙСТВИЕ С ДРУГИМИ МЕХАНИЗМАМИ
    // ========================================================================
    //  Clean Architecture: ошибки пересекают границы слоёв только через маппинг.
    //  SOLID: SRP — маппер/ретрай отдельно от репозитория; DIP — репозиторий
    //         получает `fetch` извне (замыкание/протокол).
    //  Concurrency: async throws; TaskGroup отменяет siblings при ошибке;
    //         Error: Sendable — безопасно пересекать изоляции; CancellationError
    //         — штатный сигнал.
    //  Combine: Publisher<Output, Failure>; `.tryMap`, `.mapError`, `.catch`,
    //         `.retry(n)`; Never = публикатор без ошибок (см. AnyPublisher_...).
    //  AsyncStream: бросающий вариант — AsyncThrowingStream.
    //  SwiftUI: ошибки -> состояние (enum State), не алерты из глубины сервисов.

    static func run() async {
        syntaxDemo()
        typedThrowsDemo()
        resultDemo()
        print((try? await loadAll(ids: [1, 2, 3])) ?? [])

        var attempts = 0
        let repo = UserRepository(fetch: {
            attempts += 1
            if attempts < 3 { throw HTTPError.status(503, body: Data()) }
            return "Элшод"
        })
        let vm = await UserScreenModel(repo: repo)
        await vm.load()
        print(await vm.state, "попыток:", attempts)
    }
}
