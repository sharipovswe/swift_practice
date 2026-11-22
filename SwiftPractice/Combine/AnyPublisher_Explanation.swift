// ============================================================================
// AnyPublisher_Explanation.swift
// Combine: Publisher, AnyPublisher, type erasure, eraseToAnyPublisher()
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: Publisher/Subscriber/Subscription, Output и Failure
//  2. Проблема вложенных типов и зачем нужна type erasure
//  3. Как устроен AnyPublisher (и как написать свой)
//  4. Сценарии: Repository, Subject, CurrentValueSubject, @Published,
//     поиск с debounce, combineLatest, retry/catch, Future, мост в async
//  5. Production-пример: слой данных на Combine + ViewModel
//  6. Архитектурный анализ: когда AnyPublisher, когда some/async/AsyncStream
//  7. Ошибки и best practices, связь с concurrency/SOLID/Clean Architecture
//
// Типы лежат в неймспейсе `AnyPublisherLesson`.
// ============================================================================

import Combine
import Foundation

enum AnyPublisherLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // Combine — реактивный фреймворк Apple: поток значений во времени.
    //
    //  Publisher  — источник. Два ассоциированных типа:
    //                 Output  — что публикует
    //                 Failure — какой ошибкой может закончиться (Never = не может)
    //  Subscriber — потребитель (sink, assign). Запрашивает demand (сколько
    //               элементов готов принять) -> backpressure.
    //  Subscription — связь; `AnyCancellable` удерживает её. Освободили
    //               AnyCancellable -> подписка отменена.
    //  Operator   — map, filter, flatMap, debounce, ... Каждый оператор
    //               возвращает НОВЫЙ тип Publisher'а.
    //
    // Жизненный цикл: values* затем .finished ИЛИ .failure (терминально).
    // После failure поток мёртв — ошибку нужно обрабатывать ВНУТРИ цепочки
    // (catch/replaceError) там, где поток должен жить дальше.
    //
    // Выполнение: Combine синхронен по умолчанию; поток исполнения
    // определяют источник и `receive(on:)` / `subscribe(on:)`.

    // ========================================================================
    // 2. ПРОБЛЕМА, КОТОРУЮ РЕШАЕТ type erasure
    // ========================================================================
    //
    // Каждый оператор меняет тип. Пример цепочки:
    //
    //   let p = [1, 2, 3].publisher
    //       .map { $0 * 2 }
    //       .filter { $0 > 2 }
    //
    // Тип p:  Publishers.Filter<Publishers.Map<Publishers.Sequence<[Int], Never>, Int>>
    //
    // Если вернуть это из функции, КОНКРЕТНЫЙ тип станет частью публичного API:
    //   func numbers() -> Publishers.Filter<Publishers.Map<...>>  // ужас
    // Последствия:
    //  - нечитаемая сигнатура
    //  - утечка деталей реализации (изменили цепочку -> сломали всех
    //    клиентов, т.к. тип другой)
    //  - нельзя вернуть разные цепочки из разных веток (if/else) —
    //    тип у каждой свой
    //  - нельзя хранить в свойстве/массиве без указания точного типа
    //  - нельзя написать протокол с таким возвратом, не имея generic-а
    //
    // Решение — TYPE ERASURE: спрятать конкретный тип за обёрткой,
    // которая выставляет только Output и Failure.
    //
    //   AnyPublisher<Int, Never>
    //
    // Это "контракт": "из меня приходят Int, я не падаю" — и ничего больше.

    // Было бы так (не делайте):
    static func numbersExposed() -> Publishers.Filter<Publishers.Map<Publishers.Sequence<[Int], Never>, Int>> {
        [1, 2, 3].publisher.map { $0 * 2 }.filter { $0 > 2 }
    }

    // Стало: eraseToAnyPublisher() превращает любой Publisher в AnyPublisher.
    static func numbers() -> AnyPublisher<Int, Never> {
        [1, 2, 3].publisher
            .map { $0 * 2 }
            .filter { $0 > 2 }
            .eraseToAnyPublisher()
    }

    // Разные ветки с разными типами -> единый тип
    static func source(cached: Bool) -> AnyPublisher<String, Never> {
        if cached {
            return Just("из кэша").eraseToAnyPublisher()                       // Just<String>
        } else {
            return Just("из сети").delay(for: .milliseconds(10), scheduler: DispatchQueue.main)
                .eraseToAnyPublisher()                                          // другой тип
        }
    }

    // ========================================================================
    // 3. КАК УСТРОЕН AnyPublisher
    // ========================================================================
    //
    // Упрощённая модель (суть, не точный код Apple):
    //
    //   struct MyAnyPublisher<Output, Failure: Error>: Publisher {
    //       private let box: ... // хранит исходный publisher и пробрасывает
    //                            // receive(subscriber:) в него
    //       init<P: Publisher>(_ p: P) where P.Output == Output, P.Failure == Failure
    //       func receive<S: Subscriber>(subscriber: S) { box.receive(subscriber: subscriber) }
    //   }
    //
    // Что важно:
    //  - это ОБЁРТКА: поведение (холодный/горячий, потоки) сохраняется
    //  - цена: косвенный вызов (dynamic dispatch) + возможная аллокация
    //    бокса -> дороже "голой" цепочки, но на практике пренебрежимо
    //    по сравнению с сетью/UI
    //  - AnyPublisher НЕ даёт `send` — отправлять значения нельзя; это
    //    ТОЛЬКО-ЧТЕНИЕ. На этом строится инкапсуляция (раздел 4B)
    //  - тип Failure тоже стёрт до конкретного (не до `any Error`), поэтому
    //    его нужно преобразовывать через mapError

    /// Минимальная самописная type erasure — чтобы понять механику.
    struct SimpleAnyPublisher<Output, Failure: Error>: Publisher {
        // Храним замыкание, которое умеет подписать любого Subscriber.
        private let subscribeClosure: (AnySubscriber<Output, Failure>) -> Void

        init<P: Publisher>(_ publisher: P) where P.Output == Output, P.Failure == Failure {
            // Закрываем (захватываем) конкретный publisher внутри замыкания —
            // снаружи его тип уже не виден. Это и есть "стирание".
            subscribeClosure = { subscriber in publisher.subscribe(subscriber) }
        }

        func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            subscribeClosure(AnySubscriber(subscriber))
        }
    }

    // ========================================================================
    // 4. СЦЕНАРИИ
    // ========================================================================

    // ------------------------------------------------------------------------
    // A. Repository: возвращаем AnyPublisher, скрывая URLSession-цепочку.
    // ------------------------------------------------------------------------

    struct Post: Decodable, Equatable, Sendable { let id: Int; let title: String }

    enum APIError: Error, Equatable {
        case transport(String)
        case decoding(String)
        case status(Int)
    }

    protocol PostRepository {
        // Протокол оперирует AnyPublisher: реализация (сеть/кэш/мок) скрыта.
        func posts() -> AnyPublisher<[Post], APIError>
    }

    struct RemotePostRepository: PostRepository {
        let session: URLSession
        let url: URL

        func posts() -> AnyPublisher<[Post], APIError> {
            session.dataTaskPublisher(for: url)
                // tryMap: проверяем статус; бросает -> ошибка поднимается в Failure=Error
                .tryMap { output -> Data in
                    if let http = output.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw APIError.status(http.statusCode)
                    }
                    return output.data
                }
                .decode(type: [Post].self, decoder: JSONDecoder())
                // Нормализуем разнотипные ошибки к ОДНОМУ доменному типу.
                // Без этого Failure был бы `any Error` и протёк бы в домен.
                .mapError { error -> APIError in
                    switch error {
                    case let e as APIError:    return e
                    case let e as DecodingError: return .decoding(String(describing: e))
                    default:                   return .transport(error.localizedDescription)
                    }
                }
                .eraseToAnyPublisher()                       // скрыли всю цепочку
        }
    }

    /// Мок для тестов/превью — тот же контракт, никакой сети.
    struct StubPostRepository: PostRepository {
        var result: Result<[Post], APIError>
        func posts() -> AnyPublisher<[Post], APIError> {
            result.publisher.eraseToAnyPublisher()           // Result имеет .publisher
        }
    }

    // ------------------------------------------------------------------------
    // B. Инкапсуляция Subject: внутри можно писать, снаружи только читать.
    // ------------------------------------------------------------------------
    // PassthroughSubject/CurrentValueSubject — мутабельные (send). Нельзя
    // отдавать их наружу: любой сможет отправить событие. Паттерн:
    //   private let subject = CurrentValueSubject<...>(...)
    //   var publisher: AnyPublisher<...> { subject.eraseToAnyPublisher() }

    final class AuthService {
        enum State: Equatable { case loggedOut, loggedIn(userID: Int) }

        // Приватный источник — единственное место, где можно send.
        private let stateSubject = CurrentValueSubject<State, Never>(.loggedOut)

        /// Публичный read-only поток. Новый подписчик СРАЗУ получает текущее
        /// значение (CurrentValueSubject), затем изменения.
        var statePublisher: AnyPublisher<State, Never> {
            stateSubject.eraseToAnyPublisher()
        }
        /// Синхронный снимок текущего значения.
        var currentState: State { stateSubject.value }

        func login(userID: Int) { stateSubject.send(.loggedIn(userID: userID)) }
        func logout() { stateSubject.send(.loggedOut) }
    }

    /// Событийный канал (без текущего значения): PassthroughSubject.
    final class AnalyticsBus {
        private let subject = PassthroughSubject<String, Never>()
        var events: AnyPublisher<String, Never> { subject.eraseToAnyPublisher() }
        func track(_ name: String) { subject.send(name) }
    }

    // ------------------------------------------------------------------------
    // C. Поиск с debounce: классика Combine в ViewModel.
    // ------------------------------------------------------------------------

    final class SearchViewModel: ObservableObject {
        @Published var query = ""                            // @Published = источник-Subject
        @Published private(set) var results: [String] = []
        @Published private(set) var isLoading = false

        private var cancellables = Set<AnyCancellable>()     // хранилище подписок
        private let search: (String) -> AnyPublisher<[String], Never>

        init(search: @escaping (String) -> AnyPublisher<[String], Never>) {
            self.search = search

            $query                                           // Published<String>.Publisher
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main) // ждём паузу в наборе
                .removeDuplicates()                          // не повторяем тот же запрос
                .handleEvents(receiveOutput: { [weak self] _ in self?.isLoading = true })
                // switchToLatest: отменяет предыдущий внутренний запрос при новом
                // значении — защита от гонки "старый ответ пришёл позже нового".
                .map { query -> AnyPublisher<[String], Never> in
                    query.isEmpty ? Just([]).eraseToAnyPublisher() : search(query)
                }
                .switchToLatest()
                .receive(on: DispatchQueue.main)             // UI — только main
                .sink { [weak self] items in                 // [weak self]: цикл self->cancellables->sink->self
                    self?.results = items
                    self?.isLoading = false
                }
                .store(in: &cancellables)
        }
    }

    // ------------------------------------------------------------------------
    // D. Комбинирование источников.
    // ------------------------------------------------------------------------
    // combineLatest: эмитит при изменении ЛЮБОГО из входов, когда у всех
    // уже есть значение. Типичный пример — валидация формы / доступность кнопки.

    final class LoginFormModel: ObservableObject {
        @Published var email = ""
        @Published var password = ""
        @Published private(set) var canSubmit = false
        private var bag = Set<AnyCancellable>()

        init() {
            Publishers.CombineLatest($email, $password)
                .map { email, password in email.contains("@") && password.count >= 8 }
                .removeDuplicates()
                .assign(to: &$canSubmit)                    // assign(to:&$) — без cancellable и без retain cycle
        }
    }

    /// zip — ждёт пару значений (1-к-1); merge — объединяет однотипные потоки;
    /// flatMap — запускает вложенный Publisher на каждое значение
    /// (maxPublishers ограничивает параллелизм).
    static func mergeDemo() -> AnyPublisher<Int, Never> {
        Publishers.Merge(Just(1), Just(2)).eraseToAnyPublisher()
    }

    // ------------------------------------------------------------------------
    // E. Ошибки: catch / replaceError / retry (и как поток остаётся живым).
    // ------------------------------------------------------------------------

    static func resilient(_ repo: PostRepository) -> AnyPublisher<[Post], Never> {
        repo.posts()
            .retry(2)                                        // повторить ПОДПИСКУ на источник при ошибке
            .catch { _ in Just([]) }                         // ошибка -> значение по умолчанию; Failure -> Never
            .eraseToAnyPublisher()
    }
    // Поток внутри flatMap: ловим ошибку ВНУТРИ, чтобы внешний поток не умер:
    //   queryPublisher.flatMap { q in api(q).replaceError(with: []) }

    // ------------------------------------------------------------------------
    // F. Future — "один результат" (мост из callback) + мост в async/await.
    // ------------------------------------------------------------------------
    // ВАЖНО: Future ВЫПОЛНЯЕТСЯ СРАЗУ при создании (eager) и кэширует
    // результат. Чтобы сделать ленивым — оберни в Deferred { Future { ... } }.

    static func legacyCallback(_ done: @escaping (Result<Int, Error>) -> Void) { done(.success(7)) }

    static func lazyFuture() -> AnyPublisher<Int, Error> {
        Deferred {
            Future<Int, Error> { promise in legacyCallback { promise($0) } }
        }
        .eraseToAnyPublisher()
    }

    /// Combine -> async/await: `.values` даёт AsyncSequence; для одного
    /// значения — withCheckedThrowingContinuation либо `.values.first`.
    static func firstPosts(_ repo: PostRepository) async throws -> [Post] {
        for try await value in repo.posts().values { return value }
        return []
    }

    /// async/await -> Combine: Future + Task (не забывайте про отмену).
    static func publisher<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) -> AnyPublisher<T, Error> {
        Deferred {
            Future<T, Error> { promise in
                Task {
                    do { promise(.success(try await op())) }
                    catch { promise(.failure(error)) }
                }
            }
        }
        .eraseToAnyPublisher()
    }

    // ========================================================================
    // 5. PRODUCTION-ПРИМЕР: слой данных на Combine
    // ========================================================================
    //
    //   View ── @ObservedObject/@StateObject ──▶ PostsViewModel
    //                                                │ (подписка на AnyPublisher)
    //                                                ▼
    //                                  GetPostsUseCase (Domain)
    //                                                │ protocol PostRepository
    //                                                ▼
    //                      CachedPostRepository ──▶ RemotePostRepository (URLSession)
    //                              └─ fallback: кэш при ошибке сети
    //
    // Как выглядит "кэш с фолбэком" как декоратор поверх PostRepository:

    final class CachedPostRepository: PostRepository {
        private let remote: PostRepository
        private var cache: [Post] = []

        init(remote: PostRepository) { self.remote = remote }

        func posts() -> AnyPublisher<[Post], APIError> {
            remote.posts()
                .handleEvents(receiveOutput: { [weak self] in self?.cache = $0 })   // побочный эффект: запомнить
                .catch { [weak self] error -> AnyPublisher<[Post], APIError> in
                    guard let self, !self.cache.isEmpty else {
                        return Fail(error: error).eraseToAnyPublisher()             // кэша нет -> ошибка вверх
                    }
                    return Just(self.cache).setFailureType(to: APIError.self)       // кэш есть -> отдаём его
                        .eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
        }
    }

    struct GetPostsUseCase {
        let repository: PostRepository
        func callAsFunction() -> AnyPublisher<[Post], APIError> {
            repository.posts()
                .map { $0.sorted { $0.id < $1.id } }          // бизнес-правило
                .eraseToAnyPublisher()
        }
    }

    final class PostsViewModel: ObservableObject {
        enum State: Equatable { case idle, loading, loaded([Post]), failed(APIError) }
        @Published private(set) var state: State = .idle

        private let getPosts: GetPostsUseCase
        private var cancellables = Set<AnyCancellable>()

        init(getPosts: GetPostsUseCase) { self.getPosts = getPosts }

        func load() {
            state = .loading
            getPosts()
                .map(State.loaded)                             // успех -> State
                .catch { Just(State.failed($0)) }              // ошибка -> State (поток не рвётся)
                .receive(on: DispatchQueue.main)
                .assign(to: &$state)                           // привязка без ручного хранения
        }
    }

    // Тест ViewModel без сети: StubPostRepository(result: .success([...])).
    // Для синхронных тестов Combine можно использовать .sink и XCTestExpectation
    // либо `.values` + async-тест.

    // ========================================================================
    // 6. АРХИТЕКТУРНЫЙ АНАЛИЗ
    // ========================================================================
    //
    // КОГДА AnyPublisher:
    //  - ГРАНИЦА модуля/слоя: репозиторий, сервис, UseCase возвращают
    //    AnyPublisher<Output, Failure> -> детали цепочки скрыты (DIP, ISP)
    //  - нужно вернуть разные цепочки из разных веток
    //  - хранение publisher'а в свойстве/коллекции/протоколе
    //  - инкапсуляция Subject (отдать только чтение)
    //
    // КОГДА НЕ НУЖЕН (избыточен):
    //  - ВНУТРИ одной функции/типа: цепочку сразу подписывают sink/assign —
    //    стирание типа не нужно
    //  - публичный API нового кода с одним значением -> `async throws`
    //  - поток событий в новом коде -> AsyncStream
    //  - Swift 5.7+: `some Publisher<Output, Failure>` (opaque, без бокса,
    //    без накладных расходов) подходит, когда ветка ОДНА и протокол не
    //    требует конкретики. `any Publisher<Output, Failure>` — аналог
    //    AnyPublisher, но AnyPublisher остаётся стандартом и умеет
    //    собственные операторы-расширения.
    //
    // Combine vs Swift Concurrency:
    //   Combine: операторы времени (debounce, throttle, combineLatest),
    //            много подписчиков, ObservableObject/@Published (iOS 13+),
    //            интеграция с KVO/NotificationCenter/URLSession, UIKit-формы.
    //   async/await + AsyncStream: новый код, линейная логика, структурная
    //            отмена, строгая проверка изоляции. Combine НЕ Sendable-
    //            чистый: в Swift 6 передача Publisher/AnyCancellable между
    //            изоляциями вызывает предупреждения -> держи Combine
    //            внутри @MainActor-границ или оборачивай в `.values`.
    //   Новые проекты (iOS 17+): @Observable + async/await; Combine —
    //            для задач, где операторы действительно выигрывают.
    //
    // ПЛЮСЫ AnyPublisher: чистые сигнатуры, свободная смена реализации,
    //   тестируемость (подмена), инкапсуляция.
    // МИНУСЫ: теряется конкретика (нельзя вызвать специфичные методы
    //   исходного типа); небольшой оверхед; Failure остаётся в типе (нужен
    //   mapError); сложнее читать стеки вызовов; Combine в поддержке, но не
    //   развивается активно.

    // ========================================================================
    // 7. ОШИБКИ И BEST PRACTICES
    // ========================================================================
    //  1. Забыли сохранить AnyCancellable (`store(in:)`) -> подписка тут же
    //     отменяется, ничего не приходит.
    //  2. `sink { self.x = $0 }` в долгоживущем объекте без [weak self] ->
    //     retain cycle (self -> cancellables -> sink -> self).
    //  3. Обновление UI не на main: нужен `.receive(on: DispatchQueue.main)`
    //     (или RunLoop.main) ПЕРЕД sink/assign.
    //  4. Ошибка внутри flatMap без catch завершает ВНЕШНИЙ поток.
    //  5. Отдали наружу Subject вместо AnyPublisher -> кто угодно шлёт send.
    //  6. Future ленив? Нет! Выполняется сразу. Оберни в Deferred.
    //  7. `eraseToAnyPublisher()` ВНУТРИ длинной цепочки ради "красоты" —
    //     лишние боксы; стирай на границе.
    //  8. Failure == Error повсюду -> теряется типизация. Нормализуй
    //     через mapError к доменному enum.
    //  9. Не учтён backpressure: sink запрашивает .unlimited; для
    //     тяжёлых потребителей — собственный Subscriber с demand.
    //  10. Утечки в `Timer.publish` без отмены `connect`/cancel.
    //
    // BEST PRACTICES:
    //  - AnyPublisher на границах слоёв; внутри — конкретные типы
    //  - одна ошибка домена на границу; mapError рядом с источником
    //  - Subject приватный; наружу `eraseToAnyPublisher()`
    //  - `assign(to: &$property)` вместо sink + assign, где возможно
    //  - receive(on: main) как можно позже (перед UI), а не в начале
    //  - тесты: подмена Repository на Stub с Just/Fail/Empty/Result.publisher
    //  - в Swift 6: изолируй Combine на @MainActor, мост в async через `.values`
    //
    // СВЯЗЬ:
    //  Clean Architecture: Domain-протоколы возвращают AnyPublisher, Data
    //   реализует; Presentation подписывается.
    //  SOLID: DIP (зависимость от абстракции потока), ISP (read-only
    //   публичный интерфейс), OCP (новые источники — новые реализации).
    //  Closures: sink/map/tryMap — замыкания: [weak self], @escaping.
    //  Concurrency: `.values`, receive(on:), Sendable-ограничения.
    //  SwiftUI: @Published + ObservableObject (до iOS 17) -> @Observable.
    //  AsyncStream: альтернатива для событий от SDK (AsyncStream_Explanation).

    static func run() async {
        var bag = Set<AnyCancellable>()
        numbers().sink { print("число", $0) }.store(in: &bag)

        let auth = AuthService()
        auth.statePublisher.sink { print("auth:", $0) }.store(in: &bag)
        auth.login(userID: 1)

        let repo = StubPostRepository(result: .success([Post(id: 2, title: "B"), Post(id: 1, title: "A")]))
        let vm = PostsViewModel(getPosts: GetPostsUseCase(repository: repo))
        vm.load()
        print((try? await firstPosts(repo)) ?? [])
    }
}
