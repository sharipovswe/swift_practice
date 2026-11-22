// StructuresTests.swift — Swift Testing (import Testing, Xcode 16+).
// Тесты чистой логики на struct: быстрые, без UI и сети.

import Testing
import Foundation
@testable import SwiftPractice

@Suite("Structures: CartReducer, Value Objects, Mapper")
struct StructuresTests {
    typealias L = StructuresLesson
    let tea = L.CartState.Line(id: 1, title: "Чай", price: .init(minorUnits: 12_000, currency: "UZS"), quantity: 1)

    // MARK: CartReducer

    @Test("Добавление нового товара")
    func addNewLine() {
        var state = L.CartState()
        L.CartReducer.reduce(&state, .add(tea))
        #expect(state.lines.count == 1)
        #expect(state.total.minorUnits == 12_000)
    }

    @Test("Повторное добавление увеличивает количество, а не дублирует строку")
    func addSameLineIncrementsQuantity() {
        var state = L.CartState()
        L.CartReducer.reduce(&state, .add(tea))
        L.CartReducer.reduce(&state, .add(tea))
        #expect(state.lines.count == 1)
        #expect(state.lines[0].quantity == 2)
        #expect(state.total.minorUnits == 24_000)
    }

    @Test("Количество 0 удаляет строку")
    func zeroQuantityRemoves() {
        var state = L.CartState()
        L.CartReducer.reduce(&state, .add(tea))
        L.CartReducer.reduce(&state, .setQuantity(id: 1, 0))
        #expect(state.lines.isEmpty)
    }

    @Test("Неизвестный id не ломает состояние")
    func unknownIdIsIgnored() {
        var state = L.CartState()
        L.CartReducer.reduce(&state, .add(tea))
        let before = state
        L.CartReducer.reduce(&state, .setQuantity(id: 999, 5))
        L.CartReducer.reduce(&state, .remove(id: 999))
        #expect(state == before)
    }

    // MARK: Value semantics

    @Test("Копия struct независима от оригинала")
    func valueSemantics() {
        let a = L.Coordinate(latitude: 1, longitude: 2)
        var b = a
        b.longitude = 99
        #expect(a.longitude == 2)
        #expect(a != b)
    }

    // MARK: Value Object

    @Test("Email нормализуется", arguments: ["  USER@Mail.UZ ", "user@mail.uz"])
    func emailNormalized(raw: String) throws {
        let email = try L.Email(raw)
        #expect(email.rawValue == "user@mail.uz")
    }

    @Test("Невалидный Email бросает ошибку", arguments: ["", "no-at-sign", "a@b@c"])
    func emailInvalid(raw: String) {
        #expect(throws: L.Email.ValidationError.invalidFormat) { try L.Email(raw) }
    }

    @Test("Money суммируется в минимальных единицах (без ошибок Double)")
    func moneyAddition() {
        let a = L.Money(minorUnits: 10, currency: "USD")
        let b = L.Money(minorUnits: 20, currency: "USD")
        #expect((a + b).minorUnits == 30)
    }

    // MARK: Mapper

    @Test("Mapper подставляет значения по умолчанию на границе слоёв")
    func mapperDefaults() {
        let dto = L.UserDTO(id: 7, full_name: nil, email: "bad", balance_minor: nil)
        let user = L.UserMapper().map(dto)
        #expect(user.name == "Без имени")
        #expect(user.email == nil)
        #expect(user.balance.minorUnits == 0)
    }

    // MARK: Property wrapper & CoW

    @Test("@Clamped ограничивает значение")
    func clamped() {
        var s = L.VolumeSettings()
        s.volume = 500
        #expect(s.volume == 100)
        s.volume = -5
        #expect(s.volume == 0)
    }

    @Test("Copy-on-Write: изменение копии не меняет оригинал")
    func copyOnWrite() {
        var a = L.BigBuffer(count: 4)
        let b = a
        a[0] = 42
        #expect(a[0] == 42)
        #expect(b[0] == 0)
    }
}
