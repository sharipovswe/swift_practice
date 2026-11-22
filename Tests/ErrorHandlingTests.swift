// ErrorHandlingTests.swift — XCTest-стиль (для сравнения со Swift Testing).
// Тестируем retry/backoff, маппинг ошибок и ViewModel, не используя сеть.

import XCTest
@testable import SwiftPractice

final class ErrorHandlingTests: XCTestCase {
    typealias L = ErrorHandlingLesson

    /// Потокобезопасный счётчик вызовов для замыканий-@Sendable.
    actor Calls { private(set) var n = 0; func hit() -> Int { n += 1; return n } }

    func test_retrying_succeedsAfterTransientFailures() async throws {
        let calls = Calls()
        let value = try await L.retrying(maxAttempts: 3, initialDelay: .milliseconds(1)) { () async throws -> String in
            if await calls.hit() < 3 { throw L.HTTPError.status(503, body: Data()) }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        let n = await calls.n
        XCTAssertEqual(n, 3)
    }

    func test_retrying_doesNotRetryClientErrors() async {
        let calls = Calls()
        do {
            _ = try await L.retrying(maxAttempts: 5, initialDelay: .milliseconds(1)) { () async throws -> Int in
                _ = await calls.hit()
                throw L.HTTPError.status(404, body: Data())       // 404 не транзитная
            }
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(L.mapToDomain(error), .notFound)
        }
        let n = await calls.n
        XCTAssertEqual(n, 1, "404 повторять нельзя")
    }

    func test_retrying_givesUpAfterMaxAttempts() async {
        let calls = Calls()
        do {
            _ = try await L.retrying(maxAttempts: 3, initialDelay: .milliseconds(1)) { () async throws -> Int in
                _ = await calls.hit()
                throw L.HTTPError.status(500, body: Data())
            }
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(L.mapToDomain(error), .server)
        }
        let n = await calls.n
        XCTAssertEqual(n, 3)
    }

    func test_retrying_propagatesCancellationWithoutRetry() async {
        let calls = Calls()
        let task = Task {
            try await L.retrying(maxAttempts: 10, initialDelay: .seconds(10)) { () async throws -> Int in
                _ = await calls.hit()
                throw L.HTTPError.status(503, body: Data())
            }
        }
        try? await Task.sleep(for: .milliseconds(50))              // первая попытка прошла, спим в backoff
        task.cancel()
        do { _ = try await task.value; XCTFail() }
        catch { XCTAssertTrue(L.isCancellation(error)) }
        let n = await calls.n
        XCTAssertEqual(n, 1)
    }

    func test_mapToDomain_table() {
        XCTAssertEqual(L.mapToDomain(L.HTTPError.status(401, body: Data())), .unauthorized)
        XCTAssertEqual(L.mapToDomain(L.HTTPError.status(403, body: Data())), .unauthorized)
        XCTAssertEqual(L.mapToDomain(L.HTTPError.status(502, body: Data())), .server)
        XCTAssertEqual(L.mapToDomain(L.HTTPError.transport(URLError(.notConnectedToInternet))), .offline)
        XCTAssertEqual(L.mapToDomain(URLError(.badURL)), .unknown)
    }

    func test_validate_password() {
        XCTAssertThrowsError(try L.validate(password: "")) { XCTAssertEqual($0 as? L.ValidationError, .empty) }
        XCTAssertThrowsError(try L.validate(password: "abc")) { XCTAssertEqual($0 as? L.ValidationError, .tooShort(min: 8)) }
        XCTAssertNoThrow(try L.validate(password: "correct-horse"))
    }

    func test_typedThrows() {
        XCTAssertEqual(try? L.parseAge("30"), 30)
        XCTAssertThrowsError(try L.parseAge("x"))
    }

    @MainActor
    func test_viewModel_mapsErrorToScreenState() async {
        let repo = L.UserRepository(fetch: { throw L.HTTPError.status(401, body: Data()) })
        let vm = L.UserScreenModel(repo: repo)
        await vm.load()
        XCTAssertEqual(vm.state, .failure(L.ErrorViewModel(.unauthorized)))
    }

    func test_loadAll_failsFast() async {
        do { _ = try await L.loadAll(ids: [1, -1, 3]); XCTFail() }
        catch { XCTAssertEqual(error as? L.ValidationError, .empty) }
    }
}
