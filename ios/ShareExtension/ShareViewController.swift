import UIKit
import MobileCoreServices

final class ShareViewController: UIViewController {
  private let worker = DispatchQueue(label: "ru.komet.app.share-extension")
  private let titleLabel = UILabel()
  private let messageLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .large)
  private let button = UIButton(type: .system)
  private var store: KometShareStore?
  private var draft: KometShareDraft?
  private var providers: [NSItemProvider] = []
  private var files: [KometSharedFile] = []
  private var texts: [String] = []
  private var subject: String?
  private var index = 0
  private var progress: Progress?
  private var cancelled = false
  private var completed = false
  private var started = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    titleLabel.text = "Передать в Komet"
    titleLabel.font = .preferredFont(forTextStyle: .title2)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 0
    messageLabel.font = .preferredFont(forTextStyle: .body)
    messageLabel.adjustsFontForContentSizeCategory = true
    messageLabel.textAlignment = .center
    messageLabel.numberOfLines = 0
    messageLabel.textColor = .secondaryLabel
    messageLabel.text = "Подготавливаем вложения…"
    button.setTitle("Отмена", for: .normal)
    button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
    button.titleLabel?.adjustsFontForContentSizeCategory = true
    button.addTarget(self, action: #selector(close), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, messageLabel, button])
    stack.axis = .vertical
    stack.spacing = 22
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
      stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
    ])
    preferredContentSize = CGSize(width: 360, height: 340)
    spinner.startAnimating()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    begin()
  }

  private func begin() {
    let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    for item in items {
      appendText(item.attributedContentText?.string)
      if subject == nil { subject = item.attributedTitle?.string }
      providers.append(contentsOf: item.attachments ?? [])
    }
    guard providers.count <= KometShareStore.maximumAttachments else {
      fail(KometShareError.tooManyAttachments)
      return
    }
    worker.async {
      let result = Result { () -> (KometShareStore, KometShareDraft) in
        let store = try KometShareStore()
        return (store, try store.beginRequest())
      }
      DispatchQueue.main.async {
        switch result {
        case .success(let (store, draft)):
          self.store = store
          self.draft = draft
          if self.cancelled {
            self.worker.async { store.discard(draft) }
          } else {
            self.processNext()
          }
        case .failure(let error):
          if !self.cancelled { self.fail(error) }
        }
      }
    }
  }

  private func processNext() {
    guard !cancelled, let store = store, let draft = draft else { return }
    guard index < providers.count else {
      commit(store: store, draft: draft)
      return
    }
    let provider = providers[index]
    messageLabel.text = "Подготавливаем вложение \(index + 1) из \(providers.count)…"
    if provider.hasItemConformingToTypeIdentifier(kUTTypeFileURL as String) {
      progress = nil
      provider.loadItem(forTypeIdentifier: kUTTypeFileURL as String, options: nil) { item, error in
        let result = Result { () -> KometSharedFile in
          if let error = error { throw error }
          guard let url = item as? URL else { throw KometShareError.unsupportedAttachment }
          return try self.worker.sync {
            try store.copyFile(at: url, suggestedName: provider.suggestedName, typeIdentifier: nil, into: draft)
          }
        }
        DispatchQueue.main.async { self.receivedFile(result) }
      }
      return
    }
    let types = provider.registeredTypeIdentifiers
    let fileType = types.first {
      Self.conforms($0, to: kUTTypeImage) || Self.conforms($0, to: kUTTypeMovie) ||
        Self.conforms($0, to: kUTTypeAudio)
    } ?? types.first {
      Self.conforms($0, to: kUTTypeData) && !Self.conforms($0, to: kUTTypeText) &&
        !Self.conforms($0, to: kUTTypeURL)
    }
    if let type = fileType {
      loadFile(provider: provider, type: type, store: store, draft: draft)
    } else if provider.hasItemConformingToTypeIdentifier(kUTTypeURL as String) {
      loadText(provider: provider, type: kUTTypeURL as String)
    } else if let textType = types.first(where: { Self.conforms($0, to: kUTTypeText) }) {
      if let name = provider.suggestedName, !(name as NSString).pathExtension.isEmpty {
        loadFile(provider: provider, type: textType, store: store, draft: draft)
      } else {
        loadText(provider: provider, type: textType)
      }
    } else {
      fail(KometShareError.unsupportedAttachment)
    }
  }

  private func loadFile(
    provider: NSItemProvider, type: String, store: KometShareStore, draft: KometShareDraft
  ) {
    progress = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
      if let url = url {
        let result = Result {
          try self.worker.sync {
            try store.copyFile(
              at: url, suggestedName: provider.suggestedName, typeIdentifier: type, into: draft
            )
          }
        }
        DispatchQueue.main.async { self.receivedFile(result) }
      } else {
        DispatchQueue.main.async {
          guard !self.cancelled else { return }
          self.loadData(provider: provider, type: type, store: store, draft: draft)
        }
      }
    }
  }

  private func loadData(
    provider: NSItemProvider, type: String, store: KometShareStore, draft: KometShareDraft
  ) {
    progress = provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
      if let data = data {
        let result = Result {
          try self.worker.sync {
            try store.saveData(data, suggestedName: provider.suggestedName, typeIdentifier: type, into: draft)
          }
        }
        DispatchQueue.main.async { self.receivedFile(result) }
      } else if Self.conforms(type, to: kUTTypeImage) {
        DispatchQueue.main.async {
          guard !self.cancelled else { return }
          self.loadImage(provider: provider, type: type, store: store, draft: draft)
        }
      } else {
        DispatchQueue.main.async { self.fail(error ?? KometShareError.unreadableAttachment) }
      }
    }
  }

  private func loadImage(
    provider: NSItemProvider, type: String, store: KometShareStore, draft: KometShareDraft
  ) {
    progress = nil
    provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
      let result = Result { () -> KometSharedFile in
        if let error = error { throw error }
        guard let image = item as? UIImage, let data = image.pngData() else {
          throw KometShareError.unreadableAttachment
        }
        let name = provider.suggestedName.map { ($0 as NSString).deletingPathExtension + ".png" }
        return try self.worker.sync {
          try store.saveData(data, suggestedName: name, typeIdentifier: kUTTypePNG as String, into: draft)
        }
      }
      DispatchQueue.main.async { self.receivedFile(result) }
    }
  }

  private func loadText(provider: NSItemProvider, type: String) {
    progress = nil
    provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
      let result = Result { () -> String in
        if let error = error { throw error }
        if let url = item as? URL { return url.absoluteString }
        if let text = item as? String { return text }
        if let text = item as? NSAttributedString { return text.string }
        if let data = item as? Data, let text = String(data: data, encoding: .utf8) { return text }
        throw KometShareError.unsupportedAttachment
      }
      DispatchQueue.main.async {
        guard !self.cancelled else { return }
        switch result {
        case .success(let text):
          self.appendText(text)
          self.index += 1
          self.processNext()
        case .failure(let error):
          self.fail(error)
        }
      }
    }
  }

  private func receivedFile(_ result: Result<KometSharedFile, Error>) {
    guard !cancelled else { return }
    switch result {
    case .success(let file):
      files.append(file)
      index += 1
      processNext()
    case .failure(let error):
      fail(error)
    }
  }

  private func appendText(_ value: String?) {
    guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty, !texts.contains(text) else { return }
    texts.append(text)
  }

  private func commit(store: KometShareStore, draft: KometShareDraft) {
    button.isEnabled = false
    messageLabel.text = "Сохраняем вложения…"
    let files = self.files
    let text = texts.joined(separator: "\n")
    let subject = self.subject
    worker.async {
      let result = Result { try store.commit(draft, files: files, text: text, subject: subject) }
      DispatchQueue.main.async {
        self.button.isEnabled = true
        switch result {
        case .success:
          self.completed = true
          self.draft = nil
          self.spinner.stopAnimating()
          self.titleLabel.text = "Сохранено в Komet"
          self.messageLabel.text = "Откройте Komet и выберите чат, чтобы отправить вложения."
          self.button.setTitle("Готово", for: .normal)
          UIAccessibility.post(notification: .announcement, argument: self.messageLabel.text)
        case .failure(let error):
          self.fail(error)
        }
      }
    }
  }

  private func fail(_ error: Error) {
    guard !cancelled else { return }
    if let store = store, let draft = draft {
      worker.async { store.discard(draft) }
      self.draft = nil
    }
    spinner.stopAnimating()
    titleLabel.text = "Не удалось передать"
    messageLabel.text = error.localizedDescription
    button.isEnabled = true
    button.setTitle("Закрыть", for: .normal)
  }

  @objc private func close() {
    if completed {
      extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
      return
    }
    cancelled = true
    progress?.cancel()
    if let store = store, let draft = draft {
      worker.async { store.discard(draft) }
      self.draft = nil
    }
    extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
  }

  private static func conforms(_ type: String, to parent: CFString) -> Bool {
    UTTypeConformsTo(type as CFString, parent)
  }
}
