import Foundation
import Testing
@testable import LoftLineMCP

/// Claims and Allow, in one place for both apps (spec 2, "Allow").
@Suite struct ClaimBookTests {
    static func book(timeout: Duration = .seconds(5)) -> ClaimBook { ClaimBook(timeout: timeout) { } }

    /// Starts a claim and waits until the book is asking about it.
    static func asking(_ book: ClaimBook, _ doc: String, _ connection: Int) async -> Task<ClaimResult, Never> {
        let task = Task { await book.claim(doc, connection: connection) }
        for _ in 0..<2000 where await !book.asking.contains(doc) { try? await Task.sleep(for: .milliseconds(5)) }
        return task
    }

    @Test func allowLetsTheClaimIn() async {
        let book = Self.book()
        let claim = await Self.asking(book, "sign", 1)
        await book.answer("sign", allow: true)
        #expect(await claim.value == .allowed)
        #expect(await book.holder(of: "sign") == 1)
    }

    @Test func denyRefuses() async {
        let book = Self.book()
        let claim = await Self.asking(book, "sign", 1)
        await book.answer("sign", allow: false)
        #expect(await claim.value == .denied)
        #expect(await book.holder(of: "sign") == nil)
    }

    @Test func noAnswerAfterTimeout() async {
        let book = Self.book(timeout: .milliseconds(50))
        #expect(await book.claim("sign", connection: 1) == .noAnswer)
        #expect(await book.asking.isEmpty)
    }

    @Test func oneQuestionAtATime() async {
        let book = Self.book()
        let first = await Self.asking(book, "sign", 1)
        #expect(await book.claim("sign", connection: 2) == .alreadyAsking)
        await book.answer("sign", allow: true)
        #expect(await first.value == .allowed)
    }

    @Test func refusedAfterDenyUntilRevokeAll() async {
        let book = Self.book()
        let claim = await Self.asking(book, "sign", 1)
        await book.answer("sign", allow: false)
        _ = await claim.value
        #expect(await book.claim("sign", connection: 2) == .refusedAfterDeny)
        await book.revokeAll()
        let again = await Self.asking(book, "sign", 3)
        await book.answer("sign", allow: true)
        #expect(await again.value == .allowed)
    }

    @Test func allowedWindowSkipsTheQuestion() async {
        let book = Self.book()
        let claim = await Self.asking(book, "sign", 1)
        await book.answer("sign", allow: true)
        _ = await claim.value
        await book.release(connection: 1)
        #expect(await book.allowed.contains("sign"))
        #expect(await book.claim("sign", connection: 2) == .allowed)
    }

    @Test func revokeAsksAgain() async {
        let book = Self.book(timeout: .milliseconds(50))
        let claim = await Self.asking(book, "sign", 1)
        await book.answer("sign", allow: true)
        _ = await claim.value
        await book.revoke("sign")
        #expect(await book.holder(of: "sign") == nil)
        #expect(await !book.allowed.contains("sign"))
        #expect(await book.claim("sign", connection: 2) == .noAnswer)
    }

    @Test func revokeAllAsksAgain() async {
        let book = Self.book(timeout: .milliseconds(50))
        let claim = await Self.asking(book, "sign", 1)
        await book.answer("sign", allow: true)
        _ = await claim.value
        await book.revokeAll()
        #expect(await book.claim("sign", connection: 2) == .noAnswer)
    }

    @Test func secondHolderIsTaken() async {
        let book = Self.book()
        let claim = await Self.asking(book, "sign", 1)
        await book.answer("sign", allow: true)
        _ = await claim.value
        #expect(await book.claim("sign", connection: 2) == .taken)
    }

    @Test func releaseKeepsAllow() async {
        let book = Self.book()
        let claim = await Self.asking(book, "sign", 1)
        await book.answer("sign", allow: true)
        _ = await claim.value
        await book.release(connection: 1)
        #expect(await book.holder(of: "sign") == nil)
        #expect(await book.allowed.contains("sign"))
    }

    @Test func revokingAPendingQuestionEndsIt() async {
        let book = Self.book()
        let claim = await Self.asking(book, "sign", 1)
        await book.revoke("sign")
        #expect(await claim.value == .closed)
    }
}
