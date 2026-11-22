// AsyncStreamTests.swift — тесты EventHub и SDK-адаптера (Swift Testing).
// Правило: ждём СОБЫТИЯ, а не времени; источник подменяем через makeStream().

import Testing
import Foundation
@testable import SwiftPractice

@Suite("AsyncStream: EventHub и SDKEventAdapter")
struct AsyncStreamTests {
    typealias L = AsyncStreamLesson

    @Test("Каждый подписчик EventHub получает ВСЕ события")
    func hubBroadcastsToAllSubscribers() async {
        let hub = L.EventHub<Int>()
        let a = await hub.subscribe()
        let b = await hub.subscribe()

        await hub.publish(1)
        await hub.publish(2)
        await hub.finishAll()

        var gotA: [Int] = [], gotB: [Int] = []
        for await x in a { gotA.append(x) }
        for await x in b { gotB.append(x) }
        #expect(gotA == [1, 2])
        #expect(gotB == [1, 2])
    }

    @Test("Отмена подписчика не ломает остальных")
    func cancelledSubscriberIsRemoved() async {
        let hub = L.EventHub<Int>()
        let cancelled = await hub.subscribe()
        let alive = await hub.subscribe()

        let listener = Task { for await _ in cancelled {} }
        listener.cancel()
        await listener.value                                   // подписчик завершился

        await hub.publish(10)
        await hub.finishAll()
        var got: [Int] = []
        for await x in alive { got.append(x) }
        #expect(got == [10])
    }

    @Test("makeStream: события, отправленные до чтения, не теряются (буфер)")
    func makeStreamBuffersEvents() async {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        continuation.yield(1); continuation.yield(2); continuation.finish()
        var out: [Int] = []
        for await x in stream { out.append(x) }
        #expect(out == [1, 2])
    }

    @Test("bufferingNewest оставляет только свежие значения")
    func bufferingNewest() async {
        let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
        (1...10).forEach { continuation.yield($0) }
        continuation.finish()
        var out: [Int] = []
        for await x in stream { out.append(x) }
        #expect(out == [9, 10])
    }

    @Test("SDK-адаптер превращает вызовы делегата в доменные события")
    func sdkAdapterEmitsEvents() async {
        let adapter = L.SDKEventAdapter()
        adapter.sdkDidConnect()
        adapter.sdkDidReceive(message: "hi")
        adapter.sdkDidDisconnect(error: nil)
        adapter.shutdown()

        var events: [L.ConnectionEvent] = []
        for await e in adapter.events { events.append(e) }
        #expect(events == [.connected, .message("hi"), .disconnected(reason: nil)])
    }

    @MainActor
    @Test("ViewModel реагирует на события фейкового клиента")
    func viewModelReactsToFakeClient() async {
        let fake = L.FakeConnectionClient()
        let vm = L.ConnectionViewModel(client: fake)
        vm.start()
        fake.push.yield(.connected)
        fake.push.yield(.message("a"))
        fake.push.yield(.message("b"))
        fake.push.finish()
        // ждём завершения потока, а не времени
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.log == ["a", "b"])
        #expect(vm.status == .online)
        vm.stop()
    }
}
