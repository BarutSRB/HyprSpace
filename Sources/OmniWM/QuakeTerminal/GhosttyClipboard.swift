// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Foundation
import GhosttyKit
import UniformTypeIdentifiers

struct GhosttyClipboardContent: Equatable {
    let mime: String
    let data: Data

    var string: String? {
        String(data: data, encoding: .utf8)
    }

    init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }

    init?(_ content: ghostty_clipboard_content_s) {
        guard let mime = content.mime, let bytes = content.data else { return nil }
        self.mime = String(cString: mime)
        data = content.len > 0 ? Data(bytes: bytes, count: content.len) : Data()
    }
}

struct GhosttyClipboardPayload: Equatable {
    let contents: [GhosttyClipboardContent]
    let available: [String]
    let programName: String?
    let canRemember: Bool

    init(
        contents: [GhosttyClipboardContent],
        available: [String],
        programName: String? = nil,
        canRemember: Bool = false
    ) {
        self.contents = contents
        self.available = available
        self.programName = programName
        self.canRemember = canRemember
    }

    init(_ confirmation: ghostty_clipboard_confirm_s) {
        var copiedContents: [GhosttyClipboardContent] = []
        if let contents = confirmation.contents {
            copiedContents.reserveCapacity(confirmation.contents_len)
            for index in 0 ..< confirmation.contents_len {
                if let content = GhosttyClipboardContent(contents[index]) {
                    copiedContents.append(content)
                }
            }
        }
        contents = copiedContents

        var copiedAvailable: [String] = []
        if let available = confirmation.available {
            copiedAvailable.reserveCapacity(confirmation.available_len)
            for index in 0 ..< confirmation.available_len {
                if let mime = available[index] {
                    copiedAvailable.append(String(cString: mime))
                }
            }
        }
        available = copiedAvailable
        programName = confirmation.name.map { String(cString: $0) }
        canRemember = confirmation.can_remember
    }

    var preview: String {
        if let text = contents.first(where: { $0.mime == "text/plain" })?.string {
            return text
        }
        return contents.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")
    }

    var previewImage: NSImage? {
        contents.lazy
            .filter { $0.mime.hasPrefix("image/") }
            .compactMap { NSImage(data: $0.data) }
            .first
    }

    func complete(
        on surface: ghostty_surface_t,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool,
        remember: Bool = false
    ) {
        var strings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            strings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }

        var copiedContents: [ghostty_clipboard_content_s] = []
        copiedContents.reserveCapacity(contents.count)
        for content in contents {
            guard let mime = strdup(content.mime) else { continue }
            strings.append(mime)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(content.data.count, 1), alignment: 1)
            buffers.append(buffer)
            content.data.withUnsafeBytes { source in
                if let baseAddress = source.baseAddress {
                    buffer.copyMemory(from: baseAddress, byteCount: source.count)
                }
            }
            copiedContents.append(ghostty_clipboard_content_s(
                mime: mime,
                data: buffer.assumingMemoryBound(to: CChar.self),
                len: content.data.count
            ))
        }

        var copiedAvailable: [UnsafePointer<CChar>?] = []
        copiedAvailable.reserveCapacity(available.count)
        for availableMime in available {
            guard let mime = strdup(availableMime) else { continue }
            strings.append(mime)
            copiedAvailable.append(UnsafePointer(mime))
        }

        copiedContents.withUnsafeBufferPointer { contentsBuffer in
            copiedAvailable.withUnsafeBufferPointer { availableBuffer in
                var completion = ghostty_clipboard_complete_s(
                    contents: contentsBuffer.baseAddress,
                    contents_len: contentsBuffer.count,
                    available: availableBuffer.baseAddress,
                    available_len: availableBuffer.count,
                    confirmed: confirmed,
                    remember: remember
                )
                ghostty_surface_complete_clipboard_request(surface, &completion, state)
            }
        }
    }
}

extension NSPasteboard.PasteboardType {
    init?(ghosttyMIMEType mime: String) {
        if mime == "text/plain" {
            self = .string
            return
        }
        guard let type = UTType(mimeType: mime) else {
            self.init(mime)
            return
        }
        self.init(type.identifier)
    }
}

@MainActor
extension NSPasteboard {
    private static let ghosttySelection = NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
    private static let ghosttyShellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    static func ghostty(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            general
        case GHOSTTY_CLIPBOARD_SELECTION:
            ghosttySelection
        default:
            nil
        }
    }

    func ghosttyData(forMIME mime: String) -> Data? {
        switch mime {
        case "text/plain":
            ghosttyOpinionatedStringContents().map { Data($0.utf8) }
        case "text/uri-list":
            ghosttyFileURLs.isEmpty
                ? nil
                : Data(ghosttyFileURLs.map { $0.absoluteString + "\r\n" }.joined().utf8)
        default:
            NSPasteboard.PasteboardType(ghosttyMIMEType: mime).flatMap { data(forType: $0) }
        }
    }

    func ghosttyAvailableMIMEs() -> [String] {
        let declaredTypes = types ?? []
        let MIMEType: (NSPasteboard.PasteboardType) -> String? = { type in
            guard let mime = UTType(type.rawValue)?.preferredMIMEType else { return nil }
            return mime == "text/plain;charset=utf-8" ? "text/plain" : mime
        }
        var result: [String] = []
        var seen: Set<String> = []
        let hasFileURL = declaredTypes.contains(.fileURL)
        let hasPlainText = hasFileURL || declaredTypes.contains { MIMEType($0) == "text/plain" }
        if hasPlainText {
            result.append("text/plain")
            seen.insert("text/plain")
        }
        if hasFileURL {
            result.append("text/uri-list")
            seen.insert("text/uri-list")
        }
        for type in declaredTypes {
            guard let mime = MIMEType(type), seen.insert(mime).inserted else { continue }
            result.append(mime)
        }
        return result
    }

    func replaceGhosttyContents(_ contents: [GhosttyClipboardContent]) {
        let typedContents = contents.compactMap { content in
            NSPasteboard.PasteboardType(ghosttyMIMEType: content.mime).map { ($0, content.data) }
        }
        declareTypes(typedContents.map(\.0), owner: nil)
        for (type, data) in typedContents {
            setData(data, forType: type)
        }
    }

    private var ghosttyFileURLs: [URL] {
        (pasteboardItems ?? []).compactMap { item in
            guard let propertyList = item.propertyList(forType: .fileURL),
                  let url = NSURL(pasteboardPropertyList: propertyList, ofType: .fileURL) as URL?,
                  url.isFileURL else { return nil }
            return url
        }
    }

    private func ghosttyOpinionatedStringContents() -> String? {
        let strings = (pasteboardItems ?? []).compactMap { item in
            if let propertyList = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: propertyList, ofType: .fileURL) as URL?,
               url.isFileURL
            {
                return Self.ghosttyShellEscape(url.path)
            }
            return item.string(forType: .string)
        }
        return strings.isEmpty ? nil : strings.joined(separator: " ")
    }

    private static func ghosttyShellEscape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)
        for character in value {
            if ghosttyShellEscapeCharacters.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}
