// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

@preconcurrency import AppKit
import Foundation

@MainActor
protocol ClipboardHistoryTimer: AnyObject {
    func invalidate()
}

@MainActor
private final class ClipboardHistoryRunLoopTimer: ClipboardHistoryTimer {
    private var timer: Timer?

    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                action()
            }
        }
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}

struct ClipboardHistoryServiceEnvironment {
    var pasteboardChangeCount: @MainActor () -> Int = {
        NSPasteboard.general.changeCount
    }

    var frontmostBundleIdentifier: @MainActor () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    var date: () -> Date = {
        Date()
    }

    var capturePasteboard: @Sendable (ClipboardPasteboardCaptureConfiguration) -> ClipboardPasteboardCapture? = {
        ClipboardHistoryPasteboard.capture(configuration: $0)
    }

    var writePasteboard: @MainActor (ClipboardHistoryItem) -> Bool = {
        ClipboardHistoryPasteboard.write($0)
    }

    var makeTimer: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> ClipboardHistoryTimer = {
        ClipboardHistoryRunLoopTimer(interval: $0, action: $1)
    }
}

final class ClipboardPasteboardReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.omniwm.clipboard-history.reader", qos: .utility)
    private let provider: @Sendable (ClipboardPasteboardCaptureConfiguration) -> ClipboardPasteboardCapture?

    init(provider: @escaping @Sendable (ClipboardPasteboardCaptureConfiguration) -> ClipboardPasteboardCapture?) {
        self.provider = provider
    }

    func capture(
        configuration: ClipboardPasteboardCaptureConfiguration,
        completion: @escaping @Sendable (ClipboardPasteboardCapture?) -> Void
    ) {
        queue.async { [provider] in
            completion(provider(configuration))
        }
    }
}

@MainActor
final class ClipboardHistoryService: @unchecked Sendable {
    struct PerformanceSnapshot: Equatable, Sendable {
        let timerFires: UInt64
    }

    private(set) var paletteItems: [ClipboardPaletteItem] = []
    var onPaletteItemsChanged: (([ClipboardPaletteItem]) -> Void)?

    private var configuration: ClipboardHistoryConfiguration
    private var environment: ClipboardHistoryServiceEnvironment
    private var store: ClipboardHistoryStore
    private var reader: ClipboardPasteboardReader
    private var timer: ClipboardHistoryTimer?
    private var lastChangeCount: Int
    private var captureGeneration = 0
    private var performanceTimerFires: UInt64?

    init(
        configuration: ClipboardHistoryConfiguration,
        environment: ClipboardHistoryServiceEnvironment = .init()
    ) {
        self.configuration = configuration
        self.environment = environment
        store = ClipboardHistoryStore(configuration: configuration)
        reader = ClipboardPasteboardReader(provider: environment.capturePasteboard)
        lastChangeCount = environment.pasteboardChangeCount()
    }

    func updateConfiguration(_ configuration: ClipboardHistoryConfiguration) {
        self.configuration = configuration
        reader = ClipboardPasteboardReader(provider: environment.capturePasteboard)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshots = await store.updateConfiguration(configuration)
            applyPaletteItems(configuration.isEnabled ? snapshots : [])
        }
        if configuration.isEnabled {
            start()
        } else {
            stop()
            applyPaletteItems([])
        }
    }

    func start() {
        guard configuration.isEnabled, timer == nil else { return }
        lastChangeCount = environment.pasteboardChangeCount()
        timer = environment.makeTimer(0.5) { [weak self] in
            self?.pollPasteboard()
        }
        let generation = captureGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshots = await store.load()
            guard generation == captureGeneration else { return }
            applyPaletteItems(configuration.isEnabled ? snapshots : [])
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        captureGeneration &+= 1
    }

    func beginPerformanceCapture() {
        performanceTimerFires = 0
    }

    func performanceSnapshot() -> PerformanceSnapshot? {
        performanceTimerFires.map { PerformanceSnapshot(timerFires: $0) }
    }

    func endPerformanceCapture() -> PerformanceSnapshot? {
        let snapshot = performanceSnapshot()
        performanceTimerFires = nil
        return snapshot
    }

    func copyItemToPasteboard(id: UUID) async -> Bool {
        guard configuration.isEnabled,
              let item = await store.itemForUse(id: id)
        else {
            return false
        }
        let didWrite = environment.writePasteboard(item)
        let snapshots = await store.paletteItems()
        applyPaletteItems(snapshots)
        return didWrite
    }

    func deleteItem(id: UUID) async -> [ClipboardPaletteItem] {
        let snapshots = await store.delete(id: id)
        applyPaletteItems(snapshots)
        return snapshots
    }

    func clearHistory() async -> [ClipboardPaletteItem] {
        let snapshots = await store.clear()
        applyPaletteItems(snapshots)
        return snapshots
    }

    private func pollPasteboard() {
        performanceTimerFires? &+= 1
        guard configuration.isEnabled else { return }
        let changeCount = environment.pasteboardChangeCount()
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        captureGeneration &+= 1
        let generation = captureGeneration
        let captureConfiguration = ClipboardPasteboardCaptureConfiguration(
            maxItemBytes: configuration.maxItemBytes,
            sourceBundleIdentifier: environment.frontmostBundleIdentifier(),
            capturedAt: environment.date()
        )
        reader.capture(configuration: captureConfiguration) { [weak self] capture in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.captureGeneration,
                      self.configuration.isEnabled,
                      let capture
                else {
                    return
                }
                let snapshots = await self.store.handleCapture(capture)
                self.applyPaletteItems(snapshots)
            }
        }
    }

    private func applyPaletteItems(_ items: [ClipboardPaletteItem]) {
        paletteItems = items
        onPaletteItemsChanged?(items)
    }
}

enum ClipboardHistoryPasteboard {
    static let markerType = NSPasteboard.PasteboardType("org.omniwm.clipboard-history")
    static let sourceType = NSPasteboard.PasteboardType("org.omniwm.clipboard-source")

    private static let supportedTypes: [(NSPasteboard.PasteboardType, ClipboardContentKind)] = [
        (.string, .text),
        (.rtf, .richText),
        (.html, .html),
        (.png, .image),
        (.tiff, .image),
        (.fileURL, .fileURL)
    ]

    private static let rejectedTypeValues: Set<String> = [
        markerType.rawValue,
        "org.nspasteboard.AutoGeneratedType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "com.agilebits.onepassword",
        "com.typeit4me.clipping",
        "de.petermaurer.TransientPasteboardType",
        "net.antelle.keeweb"
    ]

    private static let ignoredTypeValues: Set<String> = [
        sourceType.rawValue,
        "com.apple.linkpresentation.metadata",
        "com.apple.WebKit.custom-pasteboard-data",
        "org.chromium.web-custom-data",
        "org.chromium.source-url",
        "org.chromium.internal.source-rfh-token",
        "com.apple.notes.richtext",
        "com.microsoft.ObjectLink",
        "com.microsoft.Link-Source"
    ]

    static func capture(configuration: ClipboardPasteboardCaptureConfiguration) -> ClipboardPasteboardCapture? {
        guard let pasteboardItems = NSPasteboard.general.pasteboardItems,
              !pasteboardItems.isEmpty
        else {
            return nil
        }

        return capture(pasteboardItems: pasteboardItems, configuration: configuration)
    }

    static func capture(
        pasteboardItems: [NSPasteboardItem],
        configuration: ClipboardPasteboardCaptureConfiguration
    ) -> ClipboardPasteboardCapture? {
        guard !pasteboardItems.isEmpty else { return nil }

        var contents: [ClipboardHistoryContent] = []
        var textContents: [ClipboardHistoryContent] = []
        var totalBytes = 0
        var textBytes = 0

        for (itemIndex, pasteboardItem) in pasteboardItems.enumerated() {
            let typeValues = Set(pasteboardItem.types.map(\.rawValue))
            guard typeValues.isDisjoint(with: rejectedTypeValues) else {
                return nil
            }

            for (type, kind) in supportedTypes where pasteboardItem.types.contains(type) {
                guard !ignoredTypeValues.contains(type.rawValue),
                      !type.rawValue.hasPrefix("dyn."),
                      !type.rawValue.hasPrefix("com.microsoft.ole.source."),
                      let data = pasteboardItem.data(forType: type),
                      !data.isEmpty
                else {
                    continue
                }

                let content = ClipboardHistoryContent(
                    itemIndex: itemIndex,
                    type: type.rawValue,
                    kind: kind,
                    data: data
                )
                totalBytes += data.count
                contents.append(content)
                if kind == .text || kind == .richText || kind == .html {
                    textBytes += data.count
                    textContents.append(content)
                }
            }
        }

        if totalBytes > configuration.maxItemBytes {
            guard !textContents.isEmpty, textBytes <= configuration.maxItemBytes else {
                return nil
            }
            contents = textContents
        }

        guard !contents.isEmpty else { return nil }
        return ClipboardPasteboardCapture(
            contents: contents,
            sourceBundleIdentifier: configuration.sourceBundleIdentifier,
            capturedAt: configuration.capturedAt
        )
    }

    @MainActor
    static func write(_ item: ClipboardHistoryItem) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if item.contents.allSatisfy({ $0.kind == .fileURL }),
           let urls = fileURLs(from: item.contents),
           !urls.isEmpty
        {
            let didWrite = pasteboard.writeObjects(urls as [NSURL])
            pasteboard.setString("1", forType: markerType)
            if let source = item.sourceBundleIdentifier {
                pasteboard.setString(source, forType: sourceType)
            }
            return didWrite
        }

        let grouped = Dictionary(grouping: item.contents, by: \.itemIndex)
        let pasteboardItems = grouped.keys.sorted().compactMap { itemIndex -> NSPasteboardItem? in
            guard let contents = grouped[itemIndex], !contents.isEmpty else { return nil }
            let pasteboardItem = NSPasteboardItem()
            for content in contents {
                pasteboardItem.setData(content.data, forType: NSPasteboard.PasteboardType(content.type))
            }
            if itemIndex == grouped.keys.min() {
                pasteboardItem.setString("1", forType: markerType)
                if let source = item.sourceBundleIdentifier {
                    pasteboardItem.setString(source, forType: sourceType)
                }
            }
            return pasteboardItem
        }
        guard !pasteboardItems.isEmpty else { return false }
        return pasteboard.writeObjects(pasteboardItems)
    }

    private static func fileURLs(from contents: [ClipboardHistoryContent]) -> [URL]? {
        let urls = contents.compactMap { content in
            URL(dataRepresentation: content.data, relativeTo: nil)
        }
        return urls.count == contents.count ? urls : nil
    }
}
