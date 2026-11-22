// ============================================================================
// Swift6Migration_Explanation.swift
// Миграция на Swift 6: strict concurrency, @preconcurrency, @concurrent,
// nonisolated(nonsending), sending, region-based isolation, Approachable
// Concurrency
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: что меняется в Swift 6 и зачем
//  2. План миграции по шагам (для большого проекта)
//  3. Типовые диагнозы и их исправления (шпаргалка)
//  4. @preconcurrency
//  5. Swift 6.2: nonisolated(nonsending), @concurrent, default actor isolation
//  6. sending и region-based isolation
//  7. Production-пример: миграция сервиса с GCD и делегатом
//  8. Архитектурный анализ, ошибки, best practices
//
// Типы в неймспейсе `Swift6MigrationLesson`.
// ============================================================================

import Foundation
import Synchronization

enum Swift6MigrationLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // Swift 6 language mode = ПОЛНАЯ проверка data race на этапе компиляции.
    // То, что в Swift 5 было предупреждением (при strict-concurrency=complete),
    // в Swift 6 — ОШИБКА. Цель: если код скомпилировался — в нём нет data race.
    //
    // Что проверяется:
    //  - значения, пересекающие границы изоляции, должны быть Sendable
    //  - замыкания, уходящие в другую изоляцию, — @Sendable
    //  - глобальные/static переменные: либо let+Sendable, либо изолированы
    //    (@MainActor/actor), либо nonisolated(unsafe) (явное обещание)
    //  - не-Sendable значения можно "отдавать" только через `sending`,
    //    если компилятор докажет, что на них больше никто не ссылается
    //
    // Режимы (Build Settings):
    //   SWIFT_VERSION = 5 | 6                    — язык
    //   SWIFT_STRICT_CONCURRENCY = minimal | targeted | complete  (в режиме 5)
    // Включать ПОСТЕПЕННО, а не сразу 6.

    // ========================================================================
    // 2. ПЛАН МИГРАЦИИ (для большой кодовой базы)
    // ========================================================================
    //
    //  Шаг 0. Обнови Xcode/зависимости до версий с поддержкой Swift 6.
    //         Проверь, что сторонние SDK/пакеты имеют Sendable-аннотации.
    //  Шаг 1. Включи async/await и actor в новых фичах; убери новый GCD-код.
    //  Шаг 2. SWIFT_STRICT_CONCURRENCY = targeted (Swift 5 mode):
    //         предупреждения только там, где вы уже используете concurrency.
    //  Шаг 3. По модулям СНИЗУ ВВЕРХ (Core -> Data -> Domain -> UI):
    //         включай `complete` в одном модуле, чини, мерджи. Нижние модули
    //         первыми: их типы нужны верхним как Sendable.
    //  Шаг 4. Модели -> Sendable struct/enum; сервисы -> actor или Sendable
    //         struct; UI -> @MainActor.
    //  Шаг 5. Включи Swift 6 mode для модуля (по одному).
    //  Шаг 6. Включи upcoming features: NonisolatedNonsendingByDefault,
    //         InferIsolatedConformances, MemberImportVisibility (в проекте уже
    //         есть) — как предупреждения -> затем включай.
    //  Шаг 7. Прогон с Thread Sanitizer на CI; запрет новых предупреждений.
    //
    // Правило: в любой момент проект собирается. Миграция — серия маленьких PR.
    //
    // В SPM:
    //   .target(name: "Core", swiftSettings: [
    //       .swiftLanguageMode(.v6),
    //       .enableUpcomingFeature("NonisolatedNonsendingByDefault")
    //   ])

    // ========================================================================
    // 3. ШПАРГАЛКА: ДИАГНОЗ -> ЛЕЧЕНИЕ
    // ========================================================================

    // (1) "Stored property of Sendable-conforming struct has non-Sendable type"
    //     -> сделай поле Sendable (class -> struct/actor/final+let), либо
    //        убери Sendable с типа.

    // (2) "Mutation of captured var in concurrently-executing code"
    //     -> захвати копию [x], либо перенеси состояние в actor/Mutex.
    static func fix2() {
        let counter = Mutex(0)
        DispatchQueue.global().async { counter.withLock { $0 += 1 } }   // Mutex вместо var
    }

    // (3) "Static property 'shared' is not concurrency-safe because non-'Sendable'"
    //     -> сделай тип Sendable (actor/immutable), либо @MainActor static,
    //        либо `nonisolated(unsafe)` как ПОСЛЕДНЕЕ средство.
    actor Registry { static let shared = Registry(); private var items: [String] = []
        func add(_ s: String) { items.append(s) } }

    // (4) "Call to main actor-isolated instance method in a synchronous
    //      nonisolated context"
    //     -> пометь вызывающую функцию @MainActor, либо сделай её async и
    //        используй await, либо MainActor.assumeIsolated (если знаешь).

    // (5) "Capture of 'self' with non-Sendable type in a @Sendable closure"
    //     -> сделай класс @MainActor / Sendable, либо не захватывай self
    //        (захвати нужные значения).

    // (6) "Non-Sendable type cannot cross actor boundary"
    //     -> Sendable-тип; либо `sending`; либо передавай значение-копию.

    // (7) Делегаты старых SDK: вызывается на любом потоке, а класс @MainActor
    //     -> методы делегата `nonisolated` + внутри Task { @MainActor in ... }
    //        или `MainActor.assumeIsolated` если SDK гарантирует main.

    // (8) Протокол-требование синхронное, а реализация изолирована (actor)
    //     -> nonisolated реализация, либо сделай требование async.

    // (9) Замыкание-параметр, вызываемое из другой изоляции
    //     -> @Sendable и/или @MainActor в типе параметра.

    // (10) Старые API без аннотаций (ObjC/сторонние) -> @preconcurrency (п. 4).

    // ========================================================================
    // 4. @preconcurrency
    // ========================================================================
    //
    // "Это старый код, не требуй от него строгой проверки — пока."
    //
    // (a) @preconcurrency import SomeSDK
    //     Подавляет ошибки Sendable для типов ИЗ этого модуля. Используй,
    //     когда SDK не обновлён. Не навсегда: ставь TODO и следи за релизами.
    //
    // (b) @preconcurrency на соответствии протоколу:
    //     class VC: @preconcurrency SomeLegacyDelegate — проверки изоляции
    //     делегируются в runtime (assert) вместо compile-time.
    //
    // (c) @preconcurrency на своём объявлении (в библиотеке): сохраняет
    //     обратную совместимость для клиентов в Swift 5 mode.
    //
    // Пример (псевдо):
    //   @preconcurrency import LegacyPaymentSDK
    //   extension PaymentService: @preconcurrency LegacyPaymentDelegate { ... }
    //
    // Риск: runtime-проверка может упасть, если SDK вызовет не на том потоке.
    // Лечение: изолировать SDK в одном месте (адаптер-actor, см. AsyncStream_Explanation).

    // ========================================================================
    // 5. SWIFT 6.2: nonisolated(nonsending), @concurrent, DEFAULT ISOLATION
    // ========================================================================
    //
    // ПРОБЛЕМА (до 6.2): `nonisolated async` функция ВСЕГДА уходила на
    // глобальный пул (вне актора вызывающего). Значит при вызове из
    // @MainActor приходилось пересекать границу, а аргументы требовали
    // Sendable — неудобно и часто лишне.
    //
    // РЕШЕНИЕ (SE-0461): `nonisolated(nonsending)` — async-функция
    // ВЫПОЛНЯЕТСЯ В ИЗОЛЯЦИИ ВЫЗЫВАЮЩЕГО. Переключения нет, Sendable для
    // аргументов не нужен. Включается по умолчанию флагом
    // `NonisolatedNonsendingByDefault` (upcoming feature).
    //
    // `@concurrent` — явное "выполни ВНЕ изоляции вызывающего, на пуле"
    // (старое поведение). Нужно для реально тяжёлой работы (CPU, I/O).

    final class NonSendableParser {                 // не Sendable!
        var buffer: [UInt8] = []
    }

    /// Выполняется в изоляции вызывающего: можно передать не-Sendable объект.
    nonisolated(nonsending)
    static func parseInPlace(_ parser: NonSendableParser) async -> Int {
        parser.buffer.append(1)                     // тот же актор -> безопасно
        return parser.buffer.count
    }

    /// Тяжёлая работа: явно уходим на пул потоков, UI не блокируем.
    @concurrent
    static func heavyCompute(_ n: Int) async -> Int {
        (1...n).reduce(0, +)                        // CPU-работа вне main
    }

    @MainActor
    static func callerDemo() async {
        let parser = NonSendableParser()
        _ = await parseInPlace(parser)              // остаёмся на main, без Sendable
        let total = await heavyCompute(1_000_000)   // ушли на пул, вернулись на main
        print(total)
    }

    // DEFAULT ACTOR ISOLATION (Xcode 26: "Default Actor Isolation = MainActor",
    // SwiftSettings `.defaultIsolation(MainActor.self)`):
    //   Весь модуль по умолчанию @MainActor — для UI-приложений: нет
    //   `@MainActor` на каждом типе, меньше ошибок. Сетевой/тяжёлый код явно
    //   помечается `nonisolated` или `@concurrent`.
    //   Вместе с NonisolatedNonsendingByDefault это "Approachable
    //   Concurrency": код однопоточен по умолчанию, параллелизм — явный.
    //
    // КОГДА ЧТО:
    //   UI-приложение, новый проект      -> MainActor default + Approachable
    //   Библиотека / серверный код       -> nonisolated default, явные actor'ы
    //   Смешанный legacy                 -> по модулям, начиная с targeted

    // ========================================================================
    // 6. sending И REGION-BASED ISOLATION
    // ========================================================================
    //
    // Region-based isolation (SE-0414): компилятор отслеживает "регионы" —
    // группы значений, на которые есть ссылки. Не-Sendable значение МОЖНО
    // передать в другую изоляцию, если после передачи оно больше не
    // используется в исходной (регион "перемещён").

    final class Draft { var text = "" }             // не Sendable

    actor Archive {
        private var drafts: [Draft] = []
        func store(_ draft: sending Draft) { drafts.append(draft) }   // принимаем с владением
        var count: Int { drafts.count }
    }

    static func regionDemo() async {
        let archive = Archive()
        let draft = Draft()
        draft.text = "черновик"
        await archive.store(draft)                  // OK: draft больше не используется здесь
        // draft.text = "ещё"                       // ОШИБКА: использован после передачи
        print(await archive.count)
    }

    /// `sending` в результате: функция возвращает значение, "свободное" от
    /// своей изоляции (можно использовать откуда угодно).
    static func makeDraft() -> sending Draft { Draft() }

    // ========================================================================
    // 7. PRODUCTION-ПРИМЕР: МИГРАЦИЯ СЕРВИСА С GCD И ДЕЛЕГАТОМ
    // ========================================================================

    // --- БЫЛО (Swift 5, GCD, потокобезопасность "на честном слове") ---
    //
    //   class LocationService: NSObject, CLLocationManagerDelegate {
    //       static let shared = LocationService()                 // небезопасный синглтон
    //       private var listeners: [(CLLocation) -> Void] = []     // гонки
    //       private let queue = DispatchQueue(label: "loc")
    //       func subscribe(_ l: @escaping (CLLocation) -> Void) { queue.async { self.listeners.append(l) } }
    //       func locationManager(_ m: ..., didUpdateLocations ...) { queue.async { self.listeners.forEach { ... } } }
    //   }
    //
    // --- СТАЛО (Swift 6): изолированное состояние + поток событий ---

    struct Coordinate: Sendable, Equatable { let lat: Double; let lon: Double }

    /// Эмуляция legacy-делегата SDK (вызывается с любого потока).
    protocol LegacyLocationDelegate: AnyObject {
        func didUpdate(lat: Double, lon: Double)
    }

    final class LocationAdapter: NSObject, LegacyLocationDelegate, Sendable {
        let updates: AsyncStream<Coordinate>
        private let continuation: AsyncStream<Coordinate>.Continuation

        override init() {
            (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
            super.init()
        }
        // Метод делегата — nonisolated по природе (любой поток); yield потокобезопасен
        func didUpdate(lat: Double, lon: Double) { continuation.yield(Coordinate(lat: lat, lon: lon)) }
        deinit { continuation.finish() }
    }

    /// Новый сервис: actor хранит последнюю позицию, публикует поток.
    actor LocationService {
        private(set) var last: Coordinate?
        nonisolated let updates: AsyncStream<Coordinate>
        private let adapter: LocationAdapter
        private var pump: Task<Void, Never>?

        init(adapter: LocationAdapter = LocationAdapter()) {
            self.adapter = adapter
            self.updates = adapter.updates
        }
        func start() {
            guard pump == nil else { return }
            pump = Task { [adapter] in
                for await coordinate in adapter.updates { self.remember(coordinate) }   // Task наследует изоляцию actor -> await не нужен
            }
        }
        private func remember(_ c: Coordinate) { last = c }
        func stop() { pump?.cancel(); pump = nil }
    }
    // Синглтон `shared` больше не нужен: сервис создаётся в Composition Root и
    // внедряется (DI) -> нет глобального изменяемого состояния.

    // Чек-лист миграции конкретного типа:
    //  1. Что у него изменяемое состояние? -> actor / @MainActor / Mutex
    //  2. Кто и откуда его вызывает? -> какая изоляция нужна клиентам
    //  3. Какие значения пересекают границы? -> Sendable struct/enum
    //  4. Колбэки/делегаты? -> AsyncStream / @Sendable / nonisolated
    //  5. Глобальные переменные/синглтоны? -> DI или изоляция
    //  6. Тесты: добавлены ДО миграции, чтобы поймать регрессии

    // ========================================================================
    // 8. АРХИТЕКТУРНЫЙ АНАЛИЗ, ОШИБКИ, BEST PRACTICES
    // ========================================================================
    //
    // ЗАЧЕМ МИГРИРОВАТЬ: гонки данных — самый дорогой класс багов (редкие,
    //   невоспроизводимые, крэши в production). Swift 6 переносит их из
    //   runtime в compile-time. Для больших команд — главный выигрыш
    //   масштабируемости: границы изоляции — часть API.
    //
    // ЦЕНА: время миграции, "вирусность" Sendable, переписывание синглтонов
    //   и делегатов, зависимость от обновлений сторонних SDK.
    //
    // ОШИБКИ:
    //  1. Включить Swift 6 сразу на весь проект -> тысячи ошибок, "стоп работам".
    //  2. Массовый @unchecked Sendable / nonisolated(unsafe) ради зелёной
    //     сборки — долг, который прячет настоящие гонки.
    //  3. Всё помечать @MainActor "чтобы заработало" -> тяжёлая работа на main.
    //  4. Миграция сверху вниз (UI первым) -> ошибки от нижних модулей.
    //  5. Игнорировать @preconcurrency-проверки в runtime (падения в проде).
    //  6. Не писать тесты до миграции.
    //  7. Путать `Task {}` (наследует изоляцию) и `Task.detached`.
    //
    // BEST PRACTICES:
    //  - Миграция по модулям, снизу вверх, малыми PR
    //  - Предпочитай значения (Sendable struct) общему изменяемому состоянию
    //  - Синхронизацию — через actor/Mutex, не вручную
    //  - Каждый `unsafe`/`@unchecked` — с комментарием-обоснованием и ссылкой
    //    на ревью; периодически пересматривай (grep по CI)
    //  - Для нового кода: Default MainActor (приложение) + @concurrent там,
    //    где нужен параллелизм

    static func run() async {
        fix2()
        await callerDemo()
        await regionDemo()
        _ = makeDraft()

        let adapter = LocationAdapter()
        let service = LocationService(adapter: adapter)
        await service.start()
        adapter.didUpdate(lat: 41.3, lon: 69.2)
        try? await Task.sleep(for: .milliseconds(30))
        print(await service.last as Any)
        await service.stop()
    }
}
