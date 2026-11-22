// MiniProjectTests.swift — тесты мини-проекта FeedApp: кэш, оффлайн, поиск,
// пагинация. Все зависимости подменены: сеть — FakeFeedAPI, время — ManualClock.

import Testing
import Foundation
@testable import SwiftPractice

@Suite("FeedApp mini-project")
struct MiniProjectTests {
    typealias F = FeedApp

    /// Ждём, пока задача уснёт на ManualClock (событие, а не время).
    @MainActor
    func waitForSleeper(_ clock: TestingLesson.ManualClock) async {
        while clock.sleeperCount == 0 { await Task.yield() }
    }

    @Test("Репозиторий: первая загрузка идёт из сети и кладётся в кэш")
    func networkThenCache() async throws {
        let api = F.FakeFeedAPI()
        let repo = F.Dependencies.make(api: api).repository
        let first = try await repo.page(0)
        #expect(first.source == .network)
        #expect(first.articles.count == 10)

        let second = try await repo.page(0)                 // кэш свежий
        #expect(second.source == .cache)
        #expect(await api.requests == 1, "повторный запрос не должен идти в сеть")
    }

    @Test("Оффлайн: отдаётся устаревший кэш вместо ошибки")
    func offlineServesStaleCache() async throws {
        let api = F.FakeFeedAPI()
        // ttl = 0: кэш сразу "устарел" -> репозиторий идёт в сеть, а при сбое берёт stale
        let cache = F.ArticleCache(storage: F.InMemoryStorage(), ttl: 0)
        let repo = F.CachedFeedRepository(api: api, cache: cache, pageSize: 10)

        _ = try await repo.page(0)
        await api.setOnline(false)
        let page = try await repo.page(0)
        #expect(page.source == .cache)
        #expect(page.articles.count == 10)
    }

    @Test("Оффлайн без кэша: доменная ошибка .offline")
    func offlineWithoutCache() async {
        let api = F.FakeFeedAPI()
        await api.setOnline(false)
        let repo = F.Dependencies.make(api: api).repository
        await #expect(throws: F.FeedError.offline) { _ = try await repo.page(0) }
    }

    @Test("Кэш переживает «перезапуск» (читается из CacheStorage)")
    func cachePersistsAcrossInstances() async throws {
        let storage = F.InMemoryStorage()
        let api = F.FakeFeedAPI()
        let repo1 = F.CachedFeedRepository(api: api, cache: F.ArticleCache(storage: storage), pageSize: 10)
        _ = try await repo1.page(0)

        await api.setOnline(false)                           // новая «сессия» без сети
        let repo2 = F.CachedFeedRepository(api: api, cache: F.ArticleCache(storage: storage), pageSize: 10)
        let page = try await repo2.page(0)
        #expect(page.source == .cache)
    }

    @Test("Оффлайн-поиск идёт по кэшу")
    func offlineSearchUsesCache() async throws {
        let api = F.FakeFeedAPI()
        let repo = F.Dependencies.make(api: api).repository
        _ = try await repo.page(0)
        await api.setOnline(false)
        let found = try await repo.search("Статья 3")
        #expect(found.map(\.id) == [3])
    }

    @MainActor
    @Test("ViewModel: пагинация догружает страницы и не дублирует запросы")
    func pagination() async {
        let vm = F.makeViewModel(.make(api: F.FakeFeedAPI()))
        vm.refresh()
        await vm.loadTask?.value
        #expect(vm.articles.count == 10)

        let last = vm.articles.last!
        vm.loadMoreIfNeeded(current: last)
        vm.loadMoreIfNeeded(current: last)                  // дубль игнорируется
        await vm.loadTask?.value
        #expect(vm.articles.count == 20)
        #expect(Set(vm.articles.map(\.id)).count == 20, "дублей статей быть не должно")
    }

    @MainActor
    @Test("ViewModel: debounce поиска на ManualClock")
    func searchDebounce() async {
        let clock = TestingLesson.ManualClock()
        let deps = F.Dependencies.make(api: F.FakeFeedAPI())
        let vm = F.FeedViewModel(repository: deps.repository, connectivity: deps.connectivity, clock: clock)

        vm.query = "Ста"
        vm.query = "Статья 2"                               // отменяет предыдущий ввод
        await waitForSleeper(clock)
        await clock.advance(by: .milliseconds(299))
        #expect(vm.searchResults == nil, "пауза ещё не прошла")
        await clock.advance(by: .milliseconds(1))
        await vm.searchTask?.value
        #expect(vm.searchResults?.map(\.id).sorted() == [2, 20, 21, 22, 23, 24])
    }

    @MainActor
    @Test("ViewModel: баннер оффлайн и авто-обновление при возвращении сети")
    func connectivityRefresh() async {
        let api = F.FakeFeedAPI()
        let connectivity = F.ManualConnectivity()
        let cache = F.ArticleCache(storage: F.InMemoryStorage(), ttl: 0)
        let repo = F.CachedFeedRepository(api: api, cache: cache, pageSize: 10)
        let vm = F.FeedViewModel(repository: repo, connectivity: connectivity)

        vm.onAppear()
        await vm.loadTask?.value                            // загрузили из сети и закэшировали
        await api.setOnline(false)
        vm.refresh()
        await vm.loadTask?.value
        #expect(vm.isShowingCache)                          // сеть упала -> кэш

        connectivity.send.yield(false)
        while !vm.isOffline { await Task.yield() }
        let before = await api.requests

        await api.setOnline(true)
        connectivity.send.yield(true)                       // сеть вернулась
        while await api.requests == before { await Task.yield() }
        await vm.loadTask?.value
        #expect(!vm.isOffline)
        #expect(!vm.isShowingCache, "после возвращения сети данные обновились из сети")
        vm.onDisappear()
    }
}
