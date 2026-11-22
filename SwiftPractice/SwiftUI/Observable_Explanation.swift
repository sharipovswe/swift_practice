// ============================================================================
// Observable_Explanation.swift
// @Observable (Observation framework, iOS 17+ / macOS 14+)
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: наблюдаемость, ObservableObject vs @Observable
//  2. Как работает макрос @Observable и отслеживание доступа
//  3. Сценарии: модель, вложенность, @ObservationIgnored, вычисляемые, коллекции
//  4. Модели данных: struct Data, ViewState, связь с @State/@Bindable
//  5. Production-пример: масштабируемая ViewModel + DI + async
//  6. Архитектурный анализ, ошибки, best practices
//  7. Связь с @State, @Bindable, Concurrency, Combine, Clean Architecture
//
// Типы лежат в неймспейсе `ObservableLesson`; `View` -> `SwiftUI.View`
// (в main.swift есть класс `View`, который затеняет SwiftUI.View).
// ============================================================================

import SwiftUI
import Observation

enum ObservableLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // ДО iOS 17: ObservableObject + @Published + @StateObject/@ObservedObject/
    // @EnvironmentObject. Проблемы:
    //   - objectWillChange срабатывает при ЛЮБОМ @Published-изменении ->
    //     перерисовываются ВСЕ View, подписанные на объект, даже если они
    //     читают другое свойство
    //   - много property wrapper'ов, легко выбрать неправильный
    //   - Combine-зависимость
    //   - не работает с Optional/вложенными объектами интуитивно
    //
    // iOS 17+: макрос @Observable (модуль Observation).
    //   - гранулярное отслеживание: View перерисовывается ТОЛЬКО если
    //     изменилось свойство, которое она РЕАЛЬНО ЧИТАЛА в body
    //   - не нужны @Published; обычные `var` становятся наблюдаемыми
    //   - в View: @State (владеть), @Bindable (биндинги), обычный `let/var`
    //     (только читать), @Environment (из окружения)
    //   - без Combine, работает и вне SwiftUI (withObservationTracking)

    // ========================================================================
    // 2. КАК ЭТО РАБОТАЕТ
    // ========================================================================
    //
    // @Observable — макрос. Для класса он генерирует:
    //   1) conformance к протоколу Observable
    //   2) для каждого хранимого `var` — приватное хранилище `_name` и
    //      computed-свойство `name` с get/set, которые вызывают
    //      `access(keyPath:)` (при чтении) и `withMutation(keyPath:)` (при записи)
    //   3) ObservationRegistrar — регистр наблюдателей
    //
    // Во время вычисления `body` SwiftUI включает "tracking": каждое
    // чтение наблюдаемого свойства запоминается. Когда свойство меняется,
    // уведомляется только View, прочитавшая именно его. Это даёт
    // точечные обновления без ручной оптимизации.
    //
    // Требования/ограничения:
    //   - только class (не struct, не enum, не actor)
    //   - хранимые свойства отслеживаются; `let` — нет (не меняются)
    //   - @ObservationIgnored исключает свойство из отслеживания
    //   - property wrapper'ы на свойствах внутри @Observable не работают
    //     (кроме @ObservationIgnored-обёрнутых)

    // ------------------------------------------------------------------------
    // 3. БАЗОВЫЙ ПРИМЕР
    // ------------------------------------------------------------------------

    @Observable
    final class UserProfile {
        var name = "Элшод"                 // наблюдаемое
        var age = 25                       // наблюдаемое
        let id = UUID()                    // let: не меняется, не отслеживается

        // @ObservationIgnored: свойство НЕ вызывает обновлений. Применяй для
        // зависимостей, кэшей, служебных данных.
        @ObservationIgnored private var cache: [String: String] = [:]

        // Вычисляемые свойства: отслеживание "транзитивное" — если computed
        // читает наблюдаемое поле, View подпишется на это поле.
        var displayName: String { "\(name), \(age)" }

        func birthday() { age += 1 }
    }

    // Гранулярность: эта View читает ТОЛЬКО name.
    // Изменение age её НЕ перерисует (в ObservableObject — перерисовало бы).
    struct NameLabel: SwiftUI.View {
        let profile: UserProfile                         // без @ObservedObject!
        var body: some SwiftUI.View { Text(profile.name) }
    }

    // ------------------------------------------------------------------------
    // Модель данных (как в задании): простая struct.
    // ------------------------------------------------------------------------
    // ВНИМАНИЕ: имя `Data` затеняет Foundation.Data внутри этого неймспейса.
    // В реальном коде называй точнее (UserData, Item). Здесь — для наглядности.

    struct Data: Equatable, Identifiable {
        let id = UUID()
        let name: String
    }

    // Правило "кто что": struct Data — ЗНАЧЕНИЕ (иммутабельная модель);
    // @Observable class — ПОВЕДЕНИЕ и ИЗМЕНЯЕМОЕ СОСТОЯНИЕ экрана, держащее
    // значения. Данные вашего домена — struct; ViewModel — @Observable class.

    @Observable
    final class DataStore {
        var items: [Data] = [Data(name: "Первый")]
        var selected: Data?
        var searchText = ""

        // Производное состояние не храним — считаем (нет рассинхрона)
        var filtered: [Data] {
            searchText.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        func add(name: String) { items.append(Data(name: name)) }
        func remove(_ item: Data) { items.removeAll { $0 == item } }
    }

    // Коллекции: мутация массива (append/remove) = запись в свойство `items`
    // -> View, читавшие items/filtered, обновятся. Элементы-struct меняются
    // через присваивание целого значения.

    // ------------------------------------------------------------------------
    // Вложенные @Observable-объекты
    // ------------------------------------------------------------------------
    // Если свойство — другой @Observable, отслеживание работает рекурсивно:
    // View, читающая `settings.theme`, подпишется на theme внутри settings.

    @Observable
    final class Settings { var theme = "light"; var fontSize = 14 }

    @Observable
    final class AppModel {
        var settings = Settings()
        var user = UserProfile()
    }

    // ------------------------------------------------------------------------
    // Использование во View: три роли
    // ------------------------------------------------------------------------

    struct StoreScreen: SwiftUI.View {
        // 1) ВЛАДЕЕМ моделью: @State (создаётся один раз)
        @State private var store = DataStore()

        var body: some SwiftUI.View {
            VStack {
                // 2) ЧИТАЕМ: передаём по значению, без обёрток
                StoreList(store: store)
                Button("Добавить") { store.add(name: "Новый") }
            }
        }
    }

    struct StoreList: SwiftUI.View {
        let store: DataStore                                  // только чтение: let
        var body: some SwiftUI.View {
            List(store.filtered) { item in Text(item.name) }  // чтение -> подписка
        }
    }

    // 3) НУЖНЫ $-биндинги (TextField, Toggle) к чужому объекту -> @Bindable
    struct StoreSearch: SwiftUI.View {
        @Bindable var store: DataStore
        var body: some SwiftUI.View { TextField("Поиск", text: $store.searchText) }
    }
    // Подробнее — Bindable_Explanation.swift.

    // Через окружение (замена @EnvironmentObject):
    //   .environment(store)                    // положить
    //   @Environment(DataStore.self) var store // достать

    // ========================================================================
    // 5. PRODUCTION-ПРИМЕР: ViewModel экрана заказов
    // ========================================================================
    //
    //   OrdersView (SwiftUI) ── владеет @State ──▶ OrdersViewModel (@Observable, @MainActor)
    //                                                    │ зависит от протокола
    //                                                    ▼
    //                                             OrdersRepository (Domain protocol)
    //
    // Принципы:
    //  - @MainActor на ViewModel: все изменения состояния на main thread
    //  - состояние экрана — один enum Phase (+ мелкие поля)
    //  - зависимости — через init, помечены @ObservationIgnored
    //  - async-загрузка с отменой устаревших запросов

    struct Order: Identifiable, Equatable, Sendable {
        let id: Int
        let title: String
        let isPaid: Bool
    }

    protocol OrdersRepository: Sendable {
        func orders() async throws -> [Order]
        func pay(orderID: Int) async throws
    }

    struct StubOrdersRepository: OrdersRepository {
        func orders() async throws -> [Order] {
            [Order(id: 1, title: "Заказ #1", isPaid: false), Order(id: 2, title: "Заказ #2", isPaid: true)]
        }
        func pay(orderID: Int) async throws {}
    }

    @MainActor
    @Observable
    final class OrdersViewModel {
        enum Phase: Equatable { case idle, loading, content, failed(String) }

        // --- наблюдаемое состояние ---
        private(set) var phase: Phase = .idle
        private(set) var orders: [Order] = []
        var showPaidOnly = false                     // меняется из UI (через @Bindable)

        // --- зависимости: не часть UI-состояния ---
        @ObservationIgnored private let repository: any OrdersRepository
        @ObservationIgnored private var loadTask: Task<Void, Never>?

        init(repository: any OrdersRepository) { self.repository = repository }

        // Производное состояние
        var visibleOrders: [Order] { showPaidOnly ? orders.filter(\.isPaid) : orders }
        var isEmpty: Bool { phase == .content && visibleOrders.isEmpty }

        // Intent: UI вызывает синхронно; async-работа внутри.
        func onAppear() { reload() }

        func reload() {
            loadTask?.cancel()                       // отменяем устаревшую загрузку
            phase = .loading
            loadTask = Task { [repository] in
                do {
                    let result = try await repository.orders()
                    guard !Task.isCancelled else { return }
                    orders = result                  // мы на @MainActor: безопасно
                    phase = .content
                } catch is CancellationError {
                    // молча
                } catch {
                    phase = .failed(error.localizedDescription)
                }
            }
        }

        func pay(_ order: Order) async {
            do {
                try await repository.pay(orderID: order.id)
                reload()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    struct OrdersView: SwiftUI.View {
        @State private var viewModel: OrdersViewModel          // владение

        init(repository: any OrdersRepository) {
            _viewModel = State(initialValue: OrdersViewModel(repository: repository))
        }

        var body: some SwiftUI.View {
            @Bindable var vm = viewModel                       // локальный Bindable для $
            VStack {
                Toggle("Только оплаченные", isOn: $vm.showPaidOnly)
                switch vm.phase {
                case .idle, .loading: ProgressView()
                case .failed(let m):  Text(m)
                case .content:
                    if vm.isEmpty { Text("Пусто") }
                    List(vm.visibleOrders) { order in
                        HStack {
                            Text(order.title)
                            Spacer()
                            if !order.isPaid { Button("Оплатить") { Task { await vm.pay(order) } } }
                        }
                    }
                }
            }
            .task { vm.onAppear() }                            // отмена при исчезновении View
        }
    }

    // ------------------------------------------------------------------------
    // Observation вне SwiftUI
    // ------------------------------------------------------------------------
    // Для UIKit/сервисов: withObservationTracking срабатывает ОДИН раз
    // при изменении — нужно перепривязывать. Удобно обернуть в AsyncStream
    // (см. AsyncStream_Explanation) или использовать `Observations` (Swift 6.2+).
    @MainActor
    static func trackManually(_ profile: UserProfile) {
        withObservationTracking {
            _ = profile.name                       // что читаем — за тем и следим
        } onChange: {
            print("name изменился")                // вызывается до применения изменения
        }
    }

    // ========================================================================
    // 6. АРХИТЕКТУРНЫЙ АНАЛИЗ
    // ========================================================================
    //
    // ЧТО ВЫБРАТЬ:
    //  struct + @State          — локальное простое состояние View
    //  @Observable class        — состояние экрана/фичи со ссылочной
    //                             семантикой, общее для нескольких View,
    //                             содержит логику и зависимости
    //  actor                    — разделяемое изменяемое состояние БЕЗ UI
    //  ObservableObject         — только если нужна поддержка iOS < 17
    //
    // ПЛЮСЫ: гранулярные обновления (меньше лишних body), меньше шаблонного
    //   кода, нет Combine, работает с Optional и вложенностью, легче
    //   тестировать (обычный класс).
    // МИНУСЫ: iOS 17+; ссылочная семантика (общее изменяемое состояние
    //   требует дисциплины); нет публикатора objectWillChange (интеграция с
    //   Combine — вручную); макрос усложняет отладку; не Sendable по умолчанию.
    //
    // МАСШТАБИРУЕМОЕ УПРАВЛЕНИЕ СОСТОЯНИЕМ (большие приложения):
    //  1) Один владелец у каждого состояния; вниз — let/@Bindable, вверх —
    //     замыкания/intents (однонаправленный поток данных).
    //  2) ViewModel на ЭКРАН/ФИЧУ, а не глобальный God-object.
    //  3) Общие данные (сессия, настройки, корзина) — в @Observable-сервисе в
    //     @Environment; на уровне фичи — только то, что нужно.
    //  4) Domain не знает про Observation: домен = struct + протоколы.
    //  5) Состояние экрана — enum/struct; derived — computed.
    //  6) Побочные эффекты (сеть, БД) — в UseCase/Repository; VM лишь
    //     запускает и отображает результат.
    //  7) Навигацию выноси из VM (Coordinator/Router/NavigationPath).
    //
    // ОШИБКИ:
    //  1. Забыли @MainActor -> запись из фонового потока -> гонки/крэши UI.
    //  2. Хранение зависимостей без @ObservationIgnored -> лишнее отслеживание.
    //  3. Ожидание, что @Observable вызовет обновление при изменении
    //     ВНУТРИ обычного class-свойства (не @Observable) — не вызовет.
    //  4. Создание модели в body/инициализаторе родителя без @State ->
    //     пересоздание при каждом обновлении, потеря состояния.
    //  5. Широкие модели (App-wide) -> сложно рассуждать и тестировать.
    //  6. Чтение дорогих computed внутри body -> пересчёт при каждом обновлении;
    //     кэшируй в хранимом свойстве.
    //  7. Мутация из `didSet`-цепочек -> каскады обновлений.
    //
    // BEST PRACTICES: final class; @MainActor на VM; DI через init (протоколы);
    //  `private(set)` для состояния, меняемого только VM; intents как методы;
    //  тесты ViewModel без UI.

    // ========================================================================
    // 7. СВЯЗЬ С ДРУГИМИ МЕХАНИЗМАМИ
    // ========================================================================
    //  @State:    владение моделью (замена @StateObject).
    //  @Bindable: $-биндинги к свойствам @Observable (замена @ObservedObject
    //             в части создания биндингов).
    //  @Environment: передача модели вниз без prop drilling.
    //  Concurrency: @MainActor @Observable class — стандарт; Task внутри
    //             наследует main-изоляцию; передача между изоляциями —
    //             через Sendable-значения (Order).
    //  Combine:   @Observable не публикует objectWillChange; для потоков —
    //             AsyncStream/Observations или явный Subject.
    //  Clean Architecture: VM — Presentation; UseCase/Repository — Domain/Data;
    //             модель домена (struct) не зависит от Observation.
    //  SOLID: DIP — репозиторий по протоколу; SRP — VM только состояние
    //             экрана и intents.

    @MainActor
    static func run() async {
        let vm = OrdersViewModel(repository: StubOrdersRepository())
        vm.reload()
        try? await Task.sleep(for: .milliseconds(50))
        print(vm.phase, vm.visibleOrders.count)
    }
}
