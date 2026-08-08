// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import ApplicationServices
import Foundation

typealias SLPSMode = UInt32
let kCPSUserGenerated: SLPSMode = 0x200

@_silgen_name("_SLPSSetFrontProcessWithOptions")
func _SLPSSetFrontProcessWithOptions(
    _ psn: inout ProcessSerialNumber,
    _ wid: UInt32,
    _ mode: SLPSMode
) -> OSStatus

@_silgen_name("SLPSPostEventRecordTo")
func SLPSPostEventRecordTo(
    _ psn: inout ProcessSerialNumber,
    _ bytes: UnsafeMutablePointer<UInt8>
) -> OSStatus

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowId: inout CGWindowID) -> AXError

func getWindowId(from windowRef: AXUIElement) -> CGWindowID? {
    var windowId: CGWindowID = 0
    let result = _AXUIElementGetWindow(windowRef, &windowId)
    return result == .success ? windowId : nil
}

@discardableResult
func performAXAction(_ element: AXUIElement, _ action: CFString, noteKey: String) -> Bool {
    let ok = AXUIElementPerformAction(element, action) == .success
    if !ok { FallbackFiringRecorder.shared.note(.ax, noteKey) }
    return ok
}

enum KeyWindowEventRecord {
    private static let bufferSize = 0x100
    private static let declaredLength: UInt8 = 0xF8
    private static let declaredLengthOffset = 0x04
    private static let eventTypeOffset = 0x08
    private static let mouseDownEventType: UInt8 = 0x01
    private static let windowLocationOffset = 0x20
    private static let keyWindowFlagOffset = 0x3A
    private static let keyWindowFlag: UInt8 = 0x10
    private static let windowIdOffset = 0x3C
    private static let farOffContentLocation = CGPoint(x: 300_000, y: 300_000)

    static func make(windowId: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: bufferSize)
        bytes[declaredLengthOffset] = declaredLength
        bytes[eventTypeOffset] = mouseDownEventType
        bytes[keyWindowFlagOffset] = keyWindowFlag
        encode(farOffContentLocation, in: &bytes, at: windowLocationOffset)
        encode(windowId, in: &bytes, at: windowIdOffset)
        return bytes
    }

    private static func encode<Value>(_ value: Value, in bytes: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value) { encodedValue in
            for index in encodedValue.indices {
                bytes[offset + index] = encodedValue[index]
            }
        }
    }
}

func makeKeyWindow(psn: inout ProcessSerialNumber, windowId: UInt32) {
    var eventBytes = KeyWindowEventRecord.make(windowId: windowId)
    if SLPSPostEventRecordTo(&psn, &eventBytes) != noErr {
        FallbackFiringRecorder.shared.note(.skylight, "postEventRecordFailed")
    }
}

func focusWindow(pid: pid_t, windowId: UInt32, windowRef _: AXUIElement) {
    var psn = ProcessSerialNumber()
    guard GetProcessForPID(pid, &psn) == noErr else {
        FallbackFiringRecorder.shared.note(.skylight, "getProcessForPIDFailed")
        return
    }

    if _SLPSSetFrontProcessWithOptions(&psn, windowId, kCPSUserGenerated) != noErr {
        FallbackFiringRecorder.shared.note(.skylight, "setFrontProcessFailed")
    }
    makeKeyWindow(psn: &psn, windowId: windowId)
}
