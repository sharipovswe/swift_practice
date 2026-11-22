// ============================================================================
// FeedApp_MiniProject.swift
// МИНИ-ПРОЕКТ: лента новостей + поиск + кэш + оффлайн
// Собирает в одном месте всё, что разобрано в уроках.
// ============================================================================
//
// ЧТО ДЕЛАЕТ ПРИЛОЖЕНИЕ
//  - Лента с постраничной подгрузкой (pagination)
//  - Поиск по мере ввода (debounce, отмена устаревших запросов)
//  - Кэш: после успешной загрузки данные сохраняются (TTL)
//  - Оффлайн: при отсутствии сети показываем кэш + баннер; поиск — по кэшу
//  - Мониторинг сети: AsyncStream<Bool> -> баннер и авто-обновление при
//    возвращении сети
//
// КАКИЕ УРОКИ ЗДЕСЬ ПРИМЕНЕНЫ (читай соответствующий файл для деталей)
//  Structures      — Article, FeedPage, Phase: иммутабельные значения
//  Protocols       — FeedAPI, CacheStorage, ConnectivityMonitor: границы слоёв, DI
//  ErrorHandling   — FeedError, маппинг URLError -> доменная ошибка, fallback
//  Closures        — Clock/Date как внедряемые зависимости, [weak self]
//  Actor           — ArticleCache: общее изменяемое состояние
//  Sendable        — все модели пересекают границы изоляции
//  Cancellation    — отмена поиска и подгрузки при новом вводе/уходе с экрана
//  AsyncStream     — поток состояния сети
//  Testing         — ManualClock, фейки (см. Tests/MiniProjectTests.swift)
//  @Observable / @State / @Bindable — слой Presentation
//
// АРХИТЕКТУРА (Clean Architecture)
//
//   Presentation     FeedView ──▶ FeedViewModel (@MainActor @Observable)
//                                        │ зависит от протокола
//   Domain                         FeedRepository (protocol), Article, FeedPage
//                                        ▲ реализует
//   Data             CachedFeedRepository ─▶ FeedAPI (сеть)
//                                         └▶ ArticleCache (actor) ─▶ CacheStorage
//
//   Composition Root: FeedApp.Dependencies — единственное место, где
//   известны конкретные типы.
// ============================================================================

import Foundation
import SwiftUI
import Observation

enum FeedApp {

    // ========================================================================
    // DOMAIN
    // ========================================================================

    struct Article: Identifiable, Hashable, Codable, Sendable {
        let id: Int
        let title: String
        let body: String
    }

    struct FeedPage: Equatable, Sendable {
        enum Source: Equatable, Sendable { case network, cache }
        let articles: [Article]
        let page: Int
        let hasMore: Bool
        let source: Source
    }

    /// Доменные ошибки: UI ничего не знает про URLError и статус-коды.
    enum FeedError: Error, Equatable, Sendable {
        case offline          // нет сети и нет кэша
        case server           // сервер ответил ошибкой
        case unavailable      // пусто в кэше и нет данных
    }

    /// Контракт для Presentation. Реализация (сеть/кэш/мок) скрыта.
    protocol FeedRepository: Sendable {
        func page(_ number: Int) async throws -> FeedPage
        func search(_ query: String) async throws -> [Article]
    }

    // ========================================================================
    // DATA: источники
    // ========================================================================

    /// Сетевой слой (в реальности — URLSession + JSONDecoder).
    protocol FeedAPI: Sendable {
        func page(_ number: Int) async throws -> [Article]
        func search(_ query: String) async throws -> [Article]
    }

    /// Хранилище кэша: файл / SQLite / CoreData / SwiftData. Здесь — абстракция.
    protocol CacheStorage: Sendable {
        func read() async throws -> Data?
        func write(_ data: Data) async throws
    }

    /// Простейшая in-memory реализация (для тестов и превью).
    actor InMemoryStorage: CacheStorage {
        private var data: Data?
        func read() async throws -> Data? { data }
        func write(_ data: Data) async throws { self.data = data }
    }

    // ------------------------------------------------------------------------
    // Кэш: actor — единственный владелец изменяемого состояния.
    // ------------------------------------------------------------------------
    // Хранит страницы по номеру + время обновления. Сериализует чтение/запись
    // (нет гонок), сохраняет на "диск" через CacheStorage.

    actor ArticleCache {
        private struct Snapshot: Codable { var pages: [Int: [Article]]; var updatedAt: Date }

        private var snapshot: Snapshot?
        private var loadedFromStorage = false
        private let storage: any CacheStorage
        private let now: @Sendable () -> Date            // время — зависимость (тестируемость)
        private let ttl: TimeInterval

        init(storage: any CacheStorage, ttl: TimeInterval = 300, now: @escaping @Sendable () -> Date = { Date() }) {
            self.storage = storage; self.ttl = ttl; self.now = now
        }

        /// Страница из кэша; `allowStale` — отдавать ли устаревшее (оффлайн).
        func page(_ number: Int, allowStale: Bool) async -> [Article]? {
            await loadIfNeeded()
            guard let snapshot, let items = snapshot.pages[number] else { return nil }
            let fresh = now().timeIntervalSince(snapshot.updatedAt) < ttl
            return (fresh || allowStale) ? items : nil
        }

        func store(_ articles: [Article], page number: Int) async {
            await loadIfNeeded()
            var current = snapshot ?? Snapshot(pages: [:], updatedAt: now())
            if number == 0 { current.pages = [:] }       // обновили первую страницу -> сброс остальных
            current.pages[number] = articles
            current.updatedAt = now()
            snapshot = current
            // Сохраняем на диск; ошибка записи кэша НЕ должна ломать пользователя.
            if let data = try? JSONEncoder().encode(current) { try? await storage.write(data) }
        }

        /// Все закэшированные статьи — для оффлайн-поиска.
        func allArticles() async -> [Article] {
            await loadIfNeeded()
            return snapshot?.pages.sorted { $0.key < $1.key }.flatMap(\.value) ?? []
        }

        private func loadIfNeeded() async {
            guard !loadedFromStorage else { return }
            loadedFromStorage = true                      // ставим ДО await: защита от reentrancy
            if let data = try? await storage.read(), let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
                snapshot = decoded
            }
        }
    }

    // ------------------------------------------------------------------------
    // Репозиторий: стратегия "network-first, cache-fallback".
    // ------------------------------------------------------------------------
    //   1. кэш свежий -> отдаём сразу (экономия сети)
    //   2. иначе сеть -> успех: пишем кэш, отдаём (source = .network)
    //   3. сеть упала -> отдаём устаревший кэш (source = .cache)
    //   4. кэша нет -> доменная ошибка

    struct CachedFeedRepository: FeedRepository {
        let api: any FeedAPI
        let cache: ArticleCache
        let pageSize: Int

        func page(_ number: Int) async throws -> FeedPage {
            if let fresh = await cache.page(number, allowStale: false) {
                return FeedPage(articles: fresh, page: number, hasMore: fresh.count == pageSize, source: .cache)
            }
            do {
                let articles = try await api.page(number)
                await cache.store(articles, page: number)
                return FeedPage(articles: articles, page: number, hasMore: articles.count == pageSize, source: .network)
            } catch is CancellationError {
                throw CancellationError()                 // отмену не маскируем fallback'ом
            } catch {
                if let stale = await cache.page(number, allowStale: true) {
                    return FeedPage(articles: stale, page: number, hasMore: false, source: .cache)
                }
                throw Self.map(error)
            }
        }

        func search(_ query: String) async throws -> [Article] {
            do {
                return try await api.search(query)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Оффлайн-поиск по тому, что уже есть в кэше
                let local = await cache.allArticles().filter {
                    $0.title.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query)
                }
                if local.isEmpty { throw Self.map(error) }
                return local
            }
        }

        /// Граница слоя: технические ошибки -> доменные.
        static func map(_ error: Error) -> FeedError {
            guard let url = error as? URLError else { return .server }
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut: return .offline
            default: return .server
            }
        }
    }

    // ------------------------------------------------------------------------
    // Мониторинг сети: поток Bool (true = онлайн).
    // ------------------------------------------------------------------------
    // В production — обёртка над NWPathMonitor (см. AsyncStream_Explanation:
    // pathUpdateHandler -> continuation.yield, onTermination -> monitor.cancel()).

    protocol ConnectivityMonitor: Sendable {
        var updates: AsyncStream<Bool> { get }
    }

    struct ManualConnectivity: ConnectivityMonitor {      // для тестов/превью
        let updates: AsyncStream<Bool>
        let send: AsyncStream<Bool>.Continuation
        init() { (updates, send) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    }

    // ========================================================================
    // PRESENTATION: ViewModel
    // ========================================================================

    @MainActor
    @Observable
    final class FeedViewModel {

        enum Phase: Equatable { case idle, loading, content, empty, failed(FeedError) }

        // --- состояние экрана (читает View) ---
        private(set) var phase: Phase = .idle
        private(set) var articles: [Article] = []
        private(set) var isLoadingMore = false
        private(set) var isOffline = false
        private(set) var isShowingCache = false
        private(set) var searchResults: [Article]?          // nil = поиск не активен
        var query = "" { didSet { queryDidChange() } }       // меняется из UI (@Bindable)

        // --- зависимости и внутренняя кухня (не наблюдаем) ---
        @ObservationIgnored private let repository: any FeedRepository
        @ObservationIgnored private let connectivity: any ConnectivityMonitor
        @ObservationIgnored private let clock: any Clock<Duration>
        @ObservationIgnored private let debounce: Duration
        @ObservationIgnored private var nextPage = 0
        @ObservationIgnored private var hasMore = true
        @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
        @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
        @ObservationIgnored private var monitorTask: Task<Void, Never>?

        init(repository: any FeedRepository,
             connectivity: any ConnectivityMonitor,
             clock: any Clock<Duration> = ContinuousClock(),
             debounce: Duration = .milliseconds(300)) {
            self.repository = repository
            self.connectivity = connectivity
            self.clock = clock
            self.debounce = debounce
        }

        // MARK: Жизненный цикл

        func onAppear() {
            startMonitoring()
            if articles.isEmpty { refresh() }
        }

        func onDisappear() {
            loadTask?.cancel(); searchTask?.cancel(); monitorTask?.cancel()
            monitorTask = nil
        }

        // MARK: Лента

        func refresh() {
            loadTask?.cancel()                              // новая загрузка заменяет старую
            nextPage = 0; hasMore = true
            phase = articles.isEmpty ? .loading : phase     // при pull-to-refresh не мигаем спиннером
            loadTask = Task {
                do {
                    let page = try await repository.page(0)
                    articles = page.articles
                    apply(page)
                    phase = articles.isEmpty ? .empty : .content
                } catch is CancellationError {
                    // устарело — тихо
                } catch let error as FeedError {
                    if articles.isEmpty { phase = .failed(error) }   // есть что показать — не ломаем экран
                } catch {
                    if articles.isEmpty { phase = .failed(.server) }
                }
            }
        }

        /// Вызывается, когда последняя ячейка появилась на экране.
        func loadMoreIfNeeded(current article: Article) {
            guard article == articles.last, hasMore, !isLoadingMore, searchResults == nil else { return }
            isLoadingMore = true                            // защита от дублей (дедупликация)
            loadTask = Task {
                defer { isLoadingMore = false }
                do {
                    let page = try await repository.page(nextPage)
                    articles += page.articles
                    apply(page)
                } catch { /* пагинация: молча остановимся; кнопка "ещё раз" в UI */ }
            }
        }

        private func apply(_ page: FeedPage) {
            nextPage = page.page + 1
            hasMore = page.hasMore
            isShowingCache = page.source == .cache
        }

        // MARK: Поиск (debounce + отмена устаревших)

        private func queryDidChange() {
            searchTask?.cancel()
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { searchResults = nil; return }
            searchTask = Task { [weak self, clock, debounce] in
                do {
                    try await clock.sleep(for: debounce)            // ждём паузу в наборе
                    guard let self else { return }
                    searchResults = try await repository.search(text)
                } catch is CancellationError {
                    // пользователь продолжил печатать
                } catch {
                    self?.searchResults = []
                }
            }
        }

        // MARK: Сеть

        private func startMonitoring() {
            guard monitorTask == nil else { return }
            monitorTask = Task { [weak self, connectivity] in
                var wasOffline = false
                for await online in connectivity.updates {
                    guard let self else { return }           // guard ВНУТРИ цикла
                    isOffline = !online
                    // Сеть вернулась, а мы показывали кэш -> обновляем автоматически
                    if online, wasOffline, isShowingCache { refresh() }
                    wasOffline = !online
                }
            }
        }

        deinit { loadTask?.cancel(); searchTask?.cancel(); monitorTask?.cancel() }
    }

    // ========================================================================
    // PRESENTATION: View
    // ========================================================================
    // `SwiftUI.View` — в main.swift есть учебный класс View.

    struct FeedView: SwiftUI.View {
        @State private var viewModel: FeedViewModel         // @State ВЛАДЕЕТ моделью

        init(viewModel: FeedViewModel) { _viewModel = State(initialValue: viewModel) }

        var body: some SwiftUI.View {
            @Bindable var vm = viewModel                      // локальный Bindable для $vm.query
            NavigationStack {
                VStack(spacing: 0) {
                    if vm.isOffline { Text("Нет сети — показан сохранённый контент").font(.footnote).padding(6) }
                    content(vm)
                }
                .navigationTitle("Лента")
                .searchable(text: $vm.query)                   // биндинг через @Bindable
            }
            .task { vm.onAppear() }                            // старт при появлении
            .onDisappear { vm.onDisappear() }                  // отмена всех задач
        }

        @ViewBuilder
        private func content(_ vm: FeedViewModel) -> some SwiftUI.View {
            if let results = vm.searchResults {
                List(results) { ArticleRow(article: $0) }
            } else {
                switch vm.phase {
                case .idle, .loading: ProgressView().frame(maxHeight: .infinity)
                case .empty:          Text("Пока пусто").frame(maxHeight: .infinity)
                case .failed(let e):  errorView(e, vm)
                case .content:
                    List {
                        ForEach(vm.articles) { article in
                            ArticleRow(article: article).onAppear { vm.loadMoreIfNeeded(current: article) }
                        }
                        if vm.isLoadingMore { ProgressView() }
                    }
                    .refreshable { vm.refresh() }
                }
            }
        }

        private func errorView(_ error: FeedError, _ vm: FeedViewModel) -> some SwiftUI.View {
            VStack(spacing: 12) {
                Text(error == .offline ? "Нет подключения" : "Ошибка сервера")
                Button("Повторить") { vm.refresh() }
            }.frame(maxHeight: .infinity)
        }
    }

    struct ArticleRow: SwiftUI.View {
        let article: Article                                   // только чтение: let
        var body: some SwiftUI.View {
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title).font(.headline)
                Text(article.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    // ========================================================================
    // COMPOSITION ROOT
    // ========================================================================

    /// Фейковый API: 25 статей, 10 на страницу; можно "выключить сеть".
    actor FakeFeedAPI: FeedAPI {
        private(set) var isOnline = true
        private(set) var requests = 0
        private let all = (0..<25).map { Article(id: $0, title: "Статья \($0)", body: "Текст статьи номер \($0)") }
        let pageSize = 10

        func setOnline(_ value: Bool) { isOnline = value }

        func page(_ number: Int) async throws -> [Article] {
            requests += 1
            guard isOnline else { throw URLError(.notConnectedToInternet) }
            try await Task.sleep(for: .milliseconds(5))
            let start = number * pageSize
            guard start < all.count else { return [] }
            return Array(all[start..<min(start + pageSize, all.count)])
        }
        func search(_ query: String) async throws -> [Article] {
            requests += 1
            guard isOnline else { throw URLError(.notConnectedToInternet) }
            return all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }

    struct Dependencies {
        let repository: any FeedRepository
        let connectivity: any ConnectivityMonitor

        /// Боевая сборка: тут заменить FakeFeedAPI на URLSession-клиент,
        /// InMemoryStorage на файловое хранилище, ManualConnectivity на NWPathMonitor.
        static func make(api: any FeedAPI = FakeFeedAPI(),
                         storage: any CacheStorage = InMemoryStorage(),
                         connectivity: any ConnectivityMonitor = ManualConnectivity()) -> Dependencies {
            let cache = ArticleCache(storage: storage)
            return Dependencies(
                repository: CachedFeedRepository(api: api, cache: cache, pageSize: 10),
                connectivity: connectivity
            )
        }
    }

    @MainActor
    static func makeViewModel(_ deps: Dependencies = .make()) -> FeedViewModel {
        FeedViewModel(repository: deps.repository, connectivity: deps.connectivity)
    }

    // ========================================================================
    // КУДА РАСТИ ДАЛЬШЕ (идеи для практики)
    // ========================================================================
    //  1. Заменить InMemoryStorage на файловое хранилище или SwiftData.
    //  2. NWPathMonitor -> AsyncStream<Bool> (по шаблону из AsyncStream_Explanation).
    //  3. Детальный экран + навигация через Coordinator / NavigationPath.
    //  4. Избранное: оптимистичное обновление + откат при ошибке.
    //  5. Ограничение параллельной загрузки картинок (TaskGroup_Explanation).
    //  6. Токен-менеджер с однократным refresh (Actor_Explanation).
    //  7. Трассировка запросов через @TaskLocal (TaskLocal_Explanation).
    //  8. Включить Swift 6 mode для модуля (Swift6Migration_Explanation).

    static func run() async {
        let api = FakeFeedAPI()
        let repository = Dependencies.make(api: api).repository
        let first = try? await repository.page(0)
        print("страница 0:", first?.articles.count ?? 0, first?.source as Any)
        await api.setOnline(false)
        let cached = try? await repository.page(0)
        print("оффлайн:", cached?.source as Any)
    }
}
