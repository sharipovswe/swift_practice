// ============================================================================
// AsyncStream_Explanation.swift
// AsyncStream<T>, AsyncThrowingStream, makeStream(), consumer/listener,
// SDKListener — доставка событий от SDK в приложение
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: AsyncSequence, AsyncStream, producer/consumer
//  2. Создание: init(unfolding:) / init(build:) / makeStream()
//  3. Политики буферизации, завершение, отмена, onTermination
//  4. Consumer: как правильно слушать
//  5. SDKListener: мост delegate/callback SDK -> AsyncStream
//  6. Broadcast: несколько потребителей одного источника
//  7. Production-пример: SDK (BLE/платежи/сокет) -> Repository -> ViewModel
//  8. Архитектурный анализ, ошибки, best practices
//
// Типы в неймспейсе `AsyncStreamLesson`.
// ============================================================================

import Foundation
import Synchronization

enum AsyncStreamLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // AsyncSequence — последовательность, элементы которой приходят
    // АСИНХРОННО во времени; обход: `for await x in seq { }`.
    // Аналог Sequence, только `next()` — async.
    //
    // AsyncStream<Element> — готовая реализация AsyncSequence, которая
    // превращает ПУШ-события (callbacks, delegates, нотификации) в PULL-обход.
    // Два конца трубы:
    //   PRODUCER (источник)   — Continuation: `yield(value)`, `finish()`
    //   CONSUMER (потребитель)— сам AsyncStream: `for await`
    //
    // Это главный инструмент замены:
    //   delegate-протоколов с кучей методов,
    //   `var onEvent: ((Event) -> Void)?`,
    //   NotificationCenter/KVO/Combine там, где Combine избыточен.
    //
    // Важно: Element должен быть Sendable (события пересекают изоляции).
    // Однопотребительский: один AsyncStream = ОДИН итератор "по-настоящему".
    // Два параллельных `for await` по одному stream делят элементы
    // между собой (каждый элемент достаётся одному), а не дублируются!

    // ------------------------------------------------------------------------
    // 2. СПОСОБЫ СОЗДАНИЯ
    // ------------------------------------------------------------------------

    // (A) makeStream() — РЕКОМЕНДУЕМЫЙ (Swift 5.9+, SE-0388).
    // Возвращает (stream, continuation) кортежем: continuation можно
    // сохранить в свойство и использовать позже, из любого места.
    static func makeStreamBasic() async {
        let (stream, continuation) = AsyncStream<Int>.makeStream()

        // Producer: может жить где угодно (другой Task, callback, delegate)
        Task {
            for i in 1...3 {
                continuation.yield(i)                       // отправить значение
                try? await Task.sleep(for: .milliseconds(10))
            }
            continuation.finish()                           // ВАЖНО: завершить поток
        }

        // Consumer
        for await value in stream { print("получили", value) }
        print("поток завершён")                              // достигается после finish()
    }

    // (B) Старый closure-стиль: continuation доступен только внутри build-замыкания.
    // Неудобно, когда источник создаётся/живёт отдельно -> именно поэтому
    // появился makeStream().
    static func closureStyle() -> AsyncStream<Int> {
        AsyncStream { continuation in
            continuation.yield(1)
            continuation.finish()
        }
    }

    // (C) unfolding: pull-стиль — следующий элемент вычисляется по запросу.
    // Подходит для генераторов/пагинации (нет push-источника).
    static func ticker() -> AsyncStream<Int> {
        // Замыкание unfolding — @Sendable: изменяемое состояние держим в Mutex.
        let counter = Mutex(0)
        return AsyncStream(unfolding: {
            try? await Task.sleep(for: .milliseconds(10))
            let n = counter.withLock { $0 += 1; return $0 }
            return n < 4 ? n : nil                          // nil = конец потока
        })
    }

    // ------------------------------------------------------------------------
    // 3. БУФЕРИЗАЦИЯ, ЗАВЕРШЕНИЕ, ОТМЕНА
    // ------------------------------------------------------------------------
    //
    // Если producer быстрее consumer'а, элементы копятся в буфере.
    // Политика (bufferingPolicy):
    //   .unbounded            — по умолчанию; безлимит (риск роста памяти!)
    //   .bufferingNewest(n)   — храним n последних, старые выбрасываем
    //                           (позиция GPS, уровень сигнала: важно актуальное)
    //   .bufferingOldest(n)   — храним n первых, новые выбрасываем
    //
    // yield возвращает YieldResult: .enqueued / .dropped / .terminated —
    // позволяет узнать, что значение отброшено или поток закрыт.
    //
    // onTermination — вызывается при finish(), ошибке или ОТМЕНЕ consumer'а
    // (Task отменён / вышли из цикла). Единственное правильное место
    // отписаться от источника (removeObserver, disconnect, stopScanning).

    static func policyDemo() async {
        let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
        continuation.onTermination = { reason in
            // reason: .finished или .cancelled
            print("termination:", reason)
        }
        for i in 1...10 {
            let r = continuation.yield(i)
            if case .dropped(let old) = r { _ = old }       // 1..8 вытеснены
        }
        continuation.finish()
        for await v in stream { print(v) }                  // 9, 10
    }

    // AsyncThrowingStream<Element, Error> — то же, но поток может завершиться
    // ошибкой: `continuation.finish(throwing: error)`; consumer: `try await`.
    static func throwingDemo() async {
        let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        continuation.yield(1)
        continuation.finish(throwing: URLError(.notConnectedToInternet))
        do {
            for try await v in stream { print(v) }
        } catch {
            print("ошибка потока:", error)
        }
    }

    // ------------------------------------------------------------------------
    // 4. CONSUMER: КАК ПРАВИЛЬНО СЛУШАТЬ
    // ------------------------------------------------------------------------
    //
    // Правила:
    //  1) `for await` ВСЕГДА внутри Task (или async-функции) — он
    //     приостанавливает текущий контекст до конца потока.
    //  2) Хранить Task и отменять её, когда слушатель не нужен (иначе утечка).
    //  3) Отмена Task = выход из for await + вызов onTermination у источника.
    //  4) [weak self] в Task слушателя ОБЯЗАТЕЛЕН для долгоживущих циклов:
    //     `guard let self` ВНУТРИ цикла, не снаружи (иначе self удержан навсегда).
    //  5) Обновление UI — на @MainActor.

    @MainActor
    final class StreamConsumer {
        private(set) var received: [Int] = []
        private var listenTask: Task<Void, Never>?

        func start(listening stream: AsyncStream<Int>) {
            listenTask?.cancel()
            listenTask = Task { [weak self] in
                for await value in stream {
                    // guard ВНУТРИ цикла: self удерживается только на время итерации
                    guard let self else { return }
                    self.received.append(value)
                }
            }
        }

        func stop() { listenTask?.cancel(); listenTask = nil }
        deinit { listenTask?.cancel() }
    }

    // Операторы: map/filter/prefix/first(where:) доступны для AsyncSequence.
    static func operatorsDemo() async {
        let (stream, c) = AsyncStream<Int>.makeStream()
        (1...6).forEach { c.yield($0) }
        c.finish()
        let result = stream.filter { $0 % 2 == 0 }.map { $0 * 10 }
        for await v in result { print(v) }                  // 20, 40, 60
        // Для debounce/throttle/merge/combineLatest — пакет swift-async-algorithms.
    }

    // ------------------------------------------------------------------------
    // 5. SDKListener: МОСТ ОТ SDK К ПРИЛОЖЕНИЮ
    // ------------------------------------------------------------------------
    //
    // Типичная ситуация: сторонний SDK (BLE, платёжный терминал, чат,
    // WebSocket, геопозиция, аналитика) сообщает о событиях через
    // delegate/listener-протокол — зачастую с вызовом на СВОЁМ потоке.
    //
    // Цель: изолировать SDK за собственным интерфейсом и отдавать наружу
    // типобезопасный `AsyncStream<SDKEvent>` — приложение ничего не знает
    // про SDK-протоколы (DIP, Anti-Corruption Layer).

    // --- 5.1 Эмуляция чужого SDK (то, что нам дано) ---

    /// Listener-протокол SDK. Вызовы приходят с произвольного потока.
    protocol SDKListener: AnyObject {
        func sdkDidConnect()
        func sdkDidReceive(message: String)
        func sdkDidDisconnect(error: Error?)
    }

    /// Сам SDK (в реальности — бинарный фреймворк).
    // @unchecked: имитация чужого SDK, который сам отвечает за потоки
    final class ThirdPartySDK: @unchecked Sendable {
        weak var listener: SDKListener?                      // SDK хранит weak-ссылку
        func connect()    { listener?.sdkDidConnect()
                            DispatchQueue.global().async { [weak self] in
                                self?.listener?.sdkDidReceive(message: "hello") } }
        func disconnect() { listener?.sdkDidDisconnect(error: nil) }
    }

    // --- 5.2 Наш доменный тип событий (Sendable enum, без типов SDK) ---

    enum ConnectionEvent: Sendable, Equatable {
        case connected
        case message(String)
        case disconnected(reason: String?)
    }

    // --- 5.3 Адаптер: реализует SDKListener, публикует AsyncStream ---

    /// Адаптер = "listener" со стороны SDK + "producer" со стороны потока.
    /// Принцип: создали stream ОДИН РАЗ в init через makeStream(), continuation
    /// сохранили, слушатель SDK только вызывает continuation.yield(...).
    ///
    /// @unchecked Sendable не нужен: все свойства — let, а
    /// AsyncStream.Continuation сама потокобезопасна (Sendable).
    final class SDKEventAdapter: NSObject, SDKListener, Sendable {

        /// Публичный поток для потребителей.
        let events: AsyncStream<ConnectionEvent>
        private let continuation: AsyncStream<ConnectionEvent>.Continuation

        override init() {
            // newest(…): при шторме событий важнее актуальные
            (events, continuation) = AsyncStream.makeStream(of: ConnectionEvent.self,
                                                            bufferingPolicy: .bufferingNewest(64))
            super.init()
        }

        // --- SDKListener: вызывается SDK на ЛЮБОМ потоке. yield потокобезопасен. ---
        func sdkDidConnect() { continuation.yield(.connected) }
        func sdkDidReceive(message: String) { continuation.yield(.message(message)) }
        func sdkDidDisconnect(error: Error?) {
            continuation.yield(.disconnected(reason: error?.localizedDescription))
            // Если сессия закончилась навсегда — закрываем поток:
            // continuation.finish()
        }

        func shutdown() { continuation.finish() }
        deinit { continuation.finish() }                      // никогда не оставляем поток висеть
    }

    // --- 5.4 Фасад над SDK: жизненный цикл + подписка/отписка ---

    protocol ConnectionClient: Sendable {
        var events: AsyncStream<ConnectionEvent> { get }
        func connect() async
        func disconnect() async
    }

    /// actor: serialize доступ к SDK (он не потокобезопасен сам по себе).
    actor SDKConnectionClient: ConnectionClient {
        // nonisolated let: stream — Sendable и неизменяем, читать можно без await
        nonisolated let events: AsyncStream<ConnectionEvent>

        private let sdk = ThirdPartySDK()
        private let adapter = SDKEventAdapter()

        init() {
            events = adapter.events
            sdk.listener = adapter                            // SDK -> адаптер (weak!)
        }

        func connect() { sdk.connect() }
        func disconnect() { sdk.disconnect() }
    }

    // --- 5.5 Использование: UseCase/Repository/ViewModel ---

    @MainActor
    final class ConnectionViewModel {
        enum Status: Equatable { case idle, online, offline }
        private(set) var status: Status = .idle
        private(set) var log: [String] = []

        private let client: ConnectionClient
        private var listenTask: Task<Void, Never>?

        init(client: ConnectionClient) { self.client = client }

        func start() {
            guard listenTask == nil else { return }
            listenTask = Task { [weak self, client] in
                // Захватили client (Sendable) отдельно, чтобы не удерживать self
                for await event in client.events {
                    guard let self else { return }
                    self.handle(event)
                }
            }
            Task { await client.connect() }
        }

        func stop() {
            listenTask?.cancel(); listenTask = nil
            Task { await client.disconnect() }
        }

        private func handle(_ event: ConnectionEvent) {
            switch event {
            case .connected:             status = .online
            case .message(let text):     log.append(text)
            case .disconnected:          status = .offline
            }
        }
    }

    // ------------------------------------------------------------------------
    // 6. BROADCAST: НЕСКОЛЬКО ПОТРЕБИТЕЛЕЙ
    // ------------------------------------------------------------------------
    //
    // Один AsyncStream = один потребитель (элементы делятся). Если нужно,
    // чтобы событие получили ВСЕ (UI, аналитика, логгер) — делаем hub:
    // каждый подписчик получает СВОЙ AsyncStream, hub рассылает им yield.

    actor EventHub<Element: Sendable> {
        private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

        /// Новый независимый поток для каждого подписчика.
        func subscribe() -> AsyncStream<Element> {
            let id = UUID()
            let (stream, continuation) = AsyncStream<Element>.makeStream()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                // Отписка при отмене/завершении подписчика — без утечек
                Task { await self?.remove(id) }
            }
            return stream
        }

        func publish(_ value: Element) {
            continuations.values.forEach { $0.yield(value) }
        }

        func finishAll() {
            continuations.values.forEach { $0.finish() }
            continuations.removeAll()
        }

        private func remove(_ id: UUID) { continuations[id] = nil }
    }

    // ------------------------------------------------------------------------
    // Другие источники -> AsyncStream
    // ------------------------------------------------------------------------

    /// NotificationCenter: у него уже есть `notifications(named:)`, но так
    /// пишется общий шаблон для любых observer-API.
    static func appStateStream() -> AsyncStream<Date> {
        AsyncStream { continuation in
            let token = NotificationCenter.default.addObserver(
                forName: Notification.Name("AppDidBecomeActive"), object: nil, queue: nil
            ) { _ in continuation.yield(Date()) }

            // NSObjectProtocol не Sendable; removeObserver потокобезопасен ->
            // осознанно снимаем проверку (комментарий обязателен!).
            nonisolated(unsafe) let observer = token
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)    // обязательная очистка
            }
        }
    }

    // ========================================================================
    // 7. PRODUCTION-ПРИМЕР: что делает команда в большом приложении
    // ========================================================================
    //
    //  Feature (SwiftUI) -> @MainActor ViewModel
    //        │ for await
    //  Domain: protocol ConnectionClient { var events: AsyncStream<ConnectionEvent> }
    //        ▲ реализует
    //  Data:   SDKConnectionClient (actor) + SDKEventAdapter (SDKListener)
    //        ▲ вызывает
    //  3rd-party SDK (бинарник, delegate на своём потоке)
    //
    // Что это даёт:
    //  - SDK заменяем (Twilio -> свой) без правок UI: меняется только Data
    //  - в тестах подставляем FakeClient с makeStream() и вручную yield-им
    //  - потоковая безопасность: SDK-потоки -> continuation (thread-safe) ->
    //    consumer на @MainActor
    //  - отмена/жизненный цикл = отмена Task (structured)

    /// Фейк для юнит-тестов: тест сам "вбрасывает" события.
    struct FakeConnectionClient: ConnectionClient {
        let events: AsyncStream<ConnectionEvent>
        let push: AsyncStream<ConnectionEvent>.Continuation

        init() {
            (events, push) = AsyncStream.makeStream()
        }
        func connect() async { push.yield(.connected) }
        func disconnect() async { push.yield(.disconnected(reason: nil)); push.finish() }
    }

    // ========================================================================
    // 8. АРХИТЕКТУРНЫЙ АНАЛИЗ, ОШИБКИ, BEST PRACTICES
    // ========================================================================
    //
    // AsyncStream vs альтернативы:
    //  - один раз получить результат     -> async функция (не stream)
    //  - повторяющиеся события, 1 слушатель -> AsyncStream
    //  - много слушателей, операторы (debounce, combineLatest) -> Combine
    //    либо swift-async-algorithms + hub
    //  - текущее состояние + изменения  -> Combine CurrentValueSubject /
    //    @Observable (SwiftUI) / AsyncStream, где первым yield — текущее значение
    //  - delegate с 1–2 методами        -> AsyncStream (чище, чем делегат)
    //  - delegate с 15 методами и ответами SDK (return value) -> оставь
    //    delegate; стрим работает в одну сторону (SDK -> app)
    //
    // ПЛЮСЫ: структурная отмена, нет retain cycle через `var onEvent`, линейный
    //   код `for await`, потокобезопасный continuation, backpressure-политики.
    // МИНУСЫ: один потребитель, нет "replay" последнего значения, нет
    //   встроенных операторов времени, события теряются без подписчика
    //   (кроме буфера), сложнее "hot/cold" семантика.
    //
    // ОШИБКИ:
    //  1. Не вызвали finish() -> for await висит вечно, Task не завершается.
    //  2. Два consumer'а на один stream -> события делятся, а не дублируются.
    //  3. unbounded-буфер для высокочастотных данных -> рост памяти.
    //  4. Не очистили источник в onTermination -> утечка observer/сокета.
    //  5. `guard let self` ВНЕ цикла for await -> вечный strong self.
    //  6. yield после finish() молча игнорируется (.terminated) — проверяй.
    //  7. Создание stream в вычисляемом свойстве `var events: AsyncStream {...}`:
    //     каждый вызов = НОВЫЙ поток и новая подписка на SDK. Создавай один раз.
    //  8. Забыли, что Element: Sendable.
    //
    // BEST PRACTICES:
    //  - makeStream() вместо closure-инициализатора для долгоживущих источников
    //  - события = `enum` + `Sendable` + без типов сторонних SDK
    //  - политика буфера выбирается осознанно (state -> newest; commands -> unbounded)
    //  - завершение потока в deinit адаптера
    //  - тестовый двойник через makeStream()
    //  - Consumer: хранимая Task, отмена в stop()/deinit

    static func run() async {
        await makeStreamBasic()
        await policyDemo()
        await throwingDemo()
        await operatorsDemo()

        let client = SDKConnectionClient()
        let vm = await ConnectionViewModel(client: client)
        await vm.start()
        try? await Task.sleep(for: .milliseconds(100))
        print(await vm.status, await vm.log)
        await vm.stop()
    }
}
