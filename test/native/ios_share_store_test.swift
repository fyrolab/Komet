import Foundation

@main
struct KometShareStoreTests {
  static func main() throws {
    let manager = FileManager.default
    let container = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? manager.removeItem(at: container) }
    let store = try KometShareStore(containerURL: container)

    let abandoned = try store.beginRequest()
    _ = try store.saveData(Data("uncommitted".utf8), suggestedName: "draft.txt", typeIdentifier: "public.plain-text", into: abandoned)
    try expect(store.nextPayload() == nil, "Uncommitted requests must not be visible")
    store.discard(abandoned)

    let first = try store.beginRequest()
    let attachment = try store.saveData(Data(), suggestedName: "empty.txt", typeIdentifier: "public.plain-text", into: first)
    let firstID = try store.commit(first, files: [attachment], text: " Synthetic caption ", subject: nil)
    let second = try store.beginRequest()
    let secondID = try store.commit(second, files: [], text: "https://example.test/shared", subject: nil)
    let payload = try require(store.nextPayload(), "First payload is missing")
    try expect(payload["id"] as? String == firstID, "Requests must preserve order")
    try expect(payload["text"] as? String == "Synthetic caption", "Text must be normalized")
    let files = try require(payload["files"] as? [[String: Any]], "File metadata is missing")
    let path = try require(files.first?["path"] as? String, "Attachment path is missing")
    try expect(manager.fileExists(atPath: path), "Empty documents must be accepted")

    let restarted = try KometShareStore(containerURL: container)
    try expect(restarted.nextPayload()?["id"] as? String == firstID, "Claim must survive process restart")
    try restarted.acknowledge(id: firstID)
    try expect(manager.fileExists(atPath: path), "Acknowledgment must not remove attachment bytes")
    try expect(restarted.nextPayload()?["id"] as? String == secondID, "Acknowledgment must advance the queue")
    try restarted.removeCompleted(id: firstID)
    try expect(!manager.fileExists(atPath: path), "Explicit release must remove exact completed request")
    try restarted.acknowledge(id: firstID)
    try restarted.removeCompleted(id: firstID)
    try expect(restarted.nextPayload()?["id"] as? String == secondID, "Idempotent release must preserve the next request")

    try expectThrows { try restarted.removeCompleted(id: secondID) }
    try expectThrows { try restarted.acknowledge(id: "../invalid") }
    try restarted.acknowledge(id: secondID)
    try restarted.removeCompleted(id: secondID)

    let broken = try restarted.beginRequest()
    let brokenFile = try restarted.saveData(Data("fixture".utf8), suggestedName: "sample.txt", typeIdentifier: "public.plain-text", into: broken)
    let brokenID = try restarted.commit(broken, files: [brokenFile], text: nil, subject: nil)
    let missing = container.appendingPathComponent("KometShare/requests/\(brokenID)/\(brokenFile.relativePath)")
    try manager.removeItem(at: missing)
    let later = try restarted.beginRequest()
    let laterID = try restarted.commit(later, files: [], text: "Later synthetic share", subject: nil)
    try expectThrows { _ = try restarted.nextPayload() }
    try expect(restarted.nextPayload()?["id"] as? String == laterID, "Corrupt requests must not permanently block the queue")

    let oversized = try restarted.beginRequest()
    for index in 0..<KometShareStore.maximumAttachments {
      _ = try restarted.saveData(Data(), suggestedName: "fixture-\(index).txt", typeIdentifier: "public.plain-text", into: oversized)
    }
    try expectThrows {
      _ = try restarted.saveData(Data(), suggestedName: "overflow.txt", typeIdentifier: "public.plain-text", into: oversized)
    }
    restarted.discard(oversized)

    let external = container.appendingPathComponent("external.txt")
    try Data("Imported synthetic document".utf8).write(to: external)
    _ = try restarted.importDocument(documentURL: external)
    try expect(manager.fileExists(atPath: external.path), "Document import must preserve the original")
    print("KometShareStore: all tests passed")
  }

  static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw Failure(message: message) }
  }

  static func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value = value else { throw Failure(message: message) }
    return value
  }

  static func expectThrows(_ operation: () throws -> Void) throws {
    do {
      try operation()
    } catch {
      return
    }
    throw Failure(message: "Expected operation to reject invalid input")
  }

  struct Failure: Error {
    let message: String
  }
}
