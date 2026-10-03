import Flutter
import UIKit

final class KometShareBridge {
  private let queue = DispatchQueue(label: "ru.komet.app.share", qos: .userInitiated)
  private var store: KometShareStore?
  private var sink: FlutterEventSink?

  func attach(_ sink: FlutterEventSink?) {
    self.sink = sink
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "consumeInitialShare":
      perform(result) { try $0.nextPayload() }
    case "acknowledgeShare":
      guard let id = (call.arguments as? [String: Any])?["id"] as? String else {
        result(FlutterError(code: "INVALID_SHARE", message: "Missing share ID", details: nil))
        return
      }
      perform(result) { store in
        try store.acknowledge(id: id)
        try store.removeCompleted(id: id)
        return nil
      }
    case "clearCache":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func importDocument(_ url: URL, onError: @escaping (Error) -> Void) {
    let scoped = url.startAccessingSecurityScopedResource()
    queue.async {
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      do {
        _ = try self.sharedStore().importDocument(documentURL: url)
        DispatchQueue.main.async { self.sink?(["changed": true]) }
      } catch {
        DispatchQueue.main.async { onError(error) }
      }
    }
  }

  private func sharedStore() throws -> KometShareStore {
    if let store = store { return store }
    let store = try KometShareStore()
    self.store = store
    return store
  }

  private func perform(_ result: @escaping FlutterResult,
                       _ action: @escaping (KometShareStore) throws -> Any?) {
    queue.async {
      do {
        let value = try action(self.sharedStore())
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "SHARE_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}
