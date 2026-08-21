// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Dispatch
import Foundation
import os

enum CGSWindowEvent: Equatable {
    case created(windowId: UInt32, spaceId: UInt64)
    case destroyed(windowId: UInt32, spaceId: UInt64)
    case frameChanged(windowId: UInt32)
    case closed(windowId: UInt32)
    case frontAppChanged(pid: pid_t)
    case orderChanged(windowId: UInt32)
    case titleChanged(windowId: UInt32)
}

@MainActor
final class CGSEventObserver {
    static let shared = CGSEventObserver()

    private var isRegistered = false
    private var isWindowClosedNotifyRegistered = false
    private(set) var lastRegistrationSummary = "not started"

    private init() {}

    func start() {
        guard !isRegistered else { return }

        let eventsViaConnectionNotify: [CGSEventType] = [
            .spaceWindowCreated,
            .spaceWindowDestroyed,
            .windowMoved,
            .windowResized,
            .windowOrderChanged,
            .windowTitleChanged,
            .frontmostApplicationChanged
        ]

        var successCount = 0
        for event in eventsViaConnectionNotify {
            let success = SkyLight.shared.registerForNotification(
                event: event,
                callback: cgsConnectionCallback,
                context: nil
            )
            if success {
                successCount += 1
            } else {
                FallbackFiringRecorder.shared.note(.skylight, "eventRegistrationFailed")
            }
        }

        if isWindowClosedNotifyRegistered {
            successCount += 1
        } else {
            let cid = SkyLight.shared.getMainConnectionID()
            let cidContext = UnsafeMutableRawPointer(bitPattern: Int(cid))
            let windowClosedSuccess = SkyLight.shared.registerNotifyProc(
                event: .windowClosed,
                callback: notifyCallback,
                context: cidContext
            )
            if windowClosedSuccess {
                successCount += 1
                isWindowClosedNotifyRegistered = true
            } else {
                FallbackFiringRecorder.shared.note(.skylight, "windowClosedRegistrationFailed")
            }
        }

        let total = eventsViaConnectionNotify.count + 1
        lastRegistrationSummary = "\(successCount)/\(total) events registered"
        let registered = successCount > 0
        isRegistered = registered
        cgsTransportEnabled.withLock { $0 = registered }
    }

    func stop() {
        if isRegistered {
            let eventsToUnregister: [CGSEventType] = [
                .spaceWindowCreated,
                .spaceWindowDestroyed,
                .windowMoved,
                .windowResized,
                .windowOrderChanged,
                .windowTitleChanged,
                .frontmostApplicationChanged
            ]

            for event in eventsToUnregister {
                _ = SkyLight.shared.unregisterForNotification(
                    event: event,
                    callback: cgsConnectionCallback
                )
            }

            isRegistered = false
        }

        if isWindowClosedNotifyRegistered {
            let cid = SkyLight.shared.getMainConnectionID()
            let cidContext = UnsafeMutableRawPointer(bitPattern: Int(cid))
            if SkyLight.shared.unregisterNotifyProc(
                event: .windowClosed,
                callback: notifyCallback,
                context: cidContext
            ) {
                isWindowClosedNotifyRegistered = false
            }
        }

        cgsTransportEnabled.withLock { $0 = false }
    }

    @discardableResult
    func subscribeToWindows(_ windowIds: [UInt32]) -> Bool {
        SkyLight.shared.subscribeToWindowNotifications(windowIds)
    }
}

private let cgsTransportEnabled = OSAllocatedUnfairLock(initialState: false)

private enum DecodedCGSEvent {
    case ignored
    case malformed
    case event(CGSWindowEvent)
}

private func handleRawCGSEvent(
    eventType: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int
) {
    guard cgsTransportEnabled.withLock({ $0 }) else { return }
    switch decodeCGSEvent(eventType: eventType, data: data, length: length) {
    case .ignored,
         .malformed:
        return
    case let .event(event):
        if case let .frameChanged(windowId) = event,
           FrameApplyTrace.shared.isActive
        {
            FrameEffectObservationTracker.noteCGSFrameChanged(
                windowId: Int(windowId),
                eventNs: DispatchTime.now().uptimeNanoseconds
            )
        }
        DiagnosticsEventRecorder.shared.recordCGS(event)
        EventIntake.post(.cgs(event))
    }
}

private func decodeCGSEvent(
    eventType: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int
) -> DecodedCGSEvent {
    guard let cgsEvent = CGSEventType(rawValue: eventType) else {
        return .ignored
    }

    switch cgsEvent {
    case .spaceWindowCreated:
        guard let spaceId = copyUInt64(from: data, length: length, offset: 0),
              let windowId = copyUInt32(from: data, length: length, offset: 8)
        else {
            return .malformed
        }
        return .event(.created(windowId: windowId, spaceId: spaceId))

    case .spaceWindowDestroyed:
        guard let spaceId = copyUInt64(from: data, length: length, offset: 0),
              let windowId = copyUInt32(from: data, length: length, offset: 8)
        else {
            return .malformed
        }
        return .event(.destroyed(windowId: windowId, spaceId: spaceId))

    case .windowClosed:
        guard let windowId = copyUInt32(from: data, length: length, offset: 0) else {
            return .malformed
        }
        return .event(.closed(windowId: windowId))

    case .windowMoved,
         .windowResized:
        guard let windowId = copyUInt32(from: data, length: length, offset: 0) else {
            return .malformed
        }
        return .event(.frameChanged(windowId: windowId))

    case .windowOrderChanged:
        guard let windowId = copyUInt32(from: data, length: length, offset: 0) else {
            return .malformed
        }
        return .event(.orderChanged(windowId: windowId))

    case .frontmostApplicationChanged:
        guard let pid = copyInt32(from: data, length: length, offset: 0) else {
            return .malformed
        }
        return .event(.frontAppChanged(pid: pid))

    case .windowTitleChanged:
        guard let windowId = copyUInt32(from: data, length: length, offset: 0) else {
            return .malformed
        }
        return .event(.titleChanged(windowId: windowId))

    default:
        return .ignored
    }
}

private func copyUInt32(
    from data: UnsafeMutableRawPointer?,
    length: Int,
    offset: Int
) -> UInt32? {
    guard let data else { return nil }
    let valueSize = MemoryLayout<UInt32>.size
    guard length >= offset + valueSize else { return nil }

    var value: UInt32 = 0
    withUnsafeMutableBytes(of: &value) { destination in
        let source = UnsafeRawBufferPointer(
            start: UnsafeRawPointer(data).advanced(by: offset),
            count: valueSize
        )
        destination.copyBytes(from: source)
    }
    return value
}

private func copyUInt64(
    from data: UnsafeMutableRawPointer?,
    length: Int,
    offset: Int
) -> UInt64? {
    guard let data else { return nil }
    let valueSize = MemoryLayout<UInt64>.size
    guard length >= offset + valueSize else { return nil }

    var value: UInt64 = 0
    withUnsafeMutableBytes(of: &value) { destination in
        let source = UnsafeRawBufferPointer(
            start: UnsafeRawPointer(data).advanced(by: offset),
            count: valueSize
        )
        destination.copyBytes(from: source)
    }
    return value
}

private func copyInt32(
    from data: UnsafeMutableRawPointer?,
    length: Int,
    offset: Int
) -> Int32? {
    guard let data else { return nil }
    let valueSize = MemoryLayout<Int32>.size
    guard length >= offset + valueSize else { return nil }

    var value: Int32 = 0
    withUnsafeMutableBytes(of: &value) { destination in
        let source = UnsafeRawBufferPointer(
            start: UnsafeRawPointer(data).advanced(by: offset),
            count: valueSize
        )
        destination.copyBytes(from: source)
    }
    return value
}

private func cgsConnectionCallback(
    event: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int,
    context _: UnsafeMutableRawPointer?,
    cid _: Int32
) {
    handleRawCGSEvent(eventType: event, data: data, length: length)
}

private func notifyCallback(
    event: UInt32,
    data: UnsafeMutableRawPointer?,
    length: Int,
    cid _: Int32
) {
    handleRawCGSEvent(eventType: event, data: data, length: length)
}
