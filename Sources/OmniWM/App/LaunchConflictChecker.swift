// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import Darwin

struct LaunchProcessSnapshot: Equatable {
    let pid: pid_t
    let bundleIdentifier: String?
    let executableName: String?
}

enum ConflictingWindowManager: CaseIterable, Equatable {
    case omniWM
    case aeroSpace
    case amethyst
    case bobrwm
    case glide
    case komorebi
    case nehir
    case paneru
    case parket
    case rift
    case tangrid
    case trimWM
    case yabai
    case yashiki

    var displayName: String {
        switch self {
        case .omniWM:
            "Another OmniWM instance"
        case .aeroSpace:
            "AeroSpace"
        case .amethyst:
            "Amethyst"
        case .bobrwm:
            "bobrwm"
        case .glide:
            "Glide"
        case .komorebi:
            "komorebi"
        case .nehir:
            "Nehir"
        case .paneru:
            "Paneru"
        case .parket:
            "parket"
        case .rift:
            "Rift"
        case .tangrid:
            "Tangrid"
        case .trimWM:
            "TrimWM"
        case .yabai:
            "yabai"
        case .yashiki:
            "Yashiki"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .omniWM:
            ["com.barut.OmniWM"]
        case .aeroSpace:
            ["bobko.aerospace", "bobko.aerospace.debug"]
        case .amethyst:
            ["com.amethyst.Amethyst"]
        case .bobrwm:
            ["com.bobrwm.bobrwm"]
        case .glide:
            ["org.glidewm.glide"]
        case .komorebi:
            []
        case .nehir:
            ["dev.guria.nehir"]
        case .paneru:
            ["com.github.karinushka.paneru"]
        case .parket:
            ["com.parket.app"]
        case .rift:
            ["git.acsandmann.rift"]
        case .tangrid:
            ["com.wrapper.Tangrid"]
        case .trimWM:
            ["de.cornz.TrimWM"]
        case .yabai:
            ["com.asmvik.yabai", "com.koekeishiya.yabai"]
        case .yashiki:
            ["dev.typester.yashiki"]
        }
    }

    var executableNames: [String] {
        switch self {
        case .omniWM:
            ["OmniWM"]
        case .aeroSpace:
            ["AeroSpace", "AeroSpace-Debug", "AeroSpaceApp"]
        case .amethyst:
            ["Amethyst"]
        case .bobrwm:
            ["Bobrwm"]
        case .glide:
            ["glide_server"]
        case .komorebi:
            ["komorebi"]
        case .nehir:
            ["Nehir"]
        case .paneru:
            ["paneru"]
        case .parket:
            ["parket"]
        case .rift:
            ["rift"]
        case .tangrid:
            ["Tangrid"]
        case .trimWM:
            ["TrimWM"]
        case .yabai:
            ["yabai"]
        case .yashiki:
            ["yashiki"]
        }
    }
}

enum LaunchConflictBlockReason: Equatable {
    case conflicts([ConflictingWindowManager])
    case scanUnavailable
}

enum LaunchConflictCheckResult: Equatable {
    case clear
    case blocked(LaunchConflictBlockReason)
}

enum LaunchConflictGateAction: Equatable {
    case checkAgain
    case quit
}

@MainActor
enum LaunchConflictGate {
    static func run(
        scan: () -> LaunchConflictCheckResult,
        present: (LaunchConflictBlockReason) -> LaunchConflictGateAction,
        onClear: () -> Void,
        onQuit: () -> Void
    ) {
        while true {
            switch scan() {
            case .clear:
                onClear()
                return
            case let .blocked(reason):
                if present(reason) == .quit {
                    onQuit()
                    return
                }
            }
        }
    }
}

@MainActor
final class LaunchConflictAutoRecheck {
    private let interval: TimeInterval
    private let scan: @MainActor () -> LaunchConflictCheckResult
    private let onClear: @MainActor () -> Void
    private var timer: Timer?

    init(
        interval: TimeInterval = 1,
        scan: @escaping @MainActor () -> LaunchConflictCheckResult,
        onClear: @escaping @MainActor () -> Void
    ) {
        self.interval = interval
        self.scan = scan
        self.onClear = onClear
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        guard timer != nil, scan() == .clear else { return }
        stop()
        onClear()
    }
}

@MainActor
struct LaunchConflictChecker {
    struct Environment {
        var applicationSnapshots: @MainActor () -> [LaunchProcessSnapshot]
        var processSnapshots: @MainActor (pid_t) throws -> [LaunchProcessSnapshot]
        var currentPID: @MainActor () -> pid_t

        @MainActor
        static var live: Environment {
            Environment(
                applicationSnapshots: {
                    NSWorkspace.shared.runningApplications.compactMap { application in
                        guard !application.isTerminated else { return nil }
                        return LaunchProcessSnapshot(
                            pid: application.processIdentifier,
                            bundleIdentifier: application.bundleIdentifier,
                            executableName: application.executableURL?.lastPathComponent
                        )
                    }
                },
                processSnapshots: { currentPID in
                    try LaunchProcessScanner.snapshots(excludingPID: currentPID)
                },
                currentPID: {
                    getpid()
                }
            )
        }
    }

    private let environment: Environment

    init(environment: Environment = .live) {
        self.environment = environment
    }

    func scan() -> LaunchConflictCheckResult {
        let currentPID = environment.currentPID()
        let processSnapshots: [LaunchProcessSnapshot]
        do {
            processSnapshots = try environment.processSnapshots(currentPID)
        } catch {
            return .blocked(.scanUnavailable)
        }

        let snapshots = (environment.applicationSnapshots() + processSnapshots).filter {
            $0.pid != currentPID
        }
        let conflicts = Self.conflicts(in: snapshots)
        return conflicts.isEmpty ? .clear : .blocked(.conflicts(conflicts))
    }

    nonisolated static func conflicts(in snapshots: [LaunchProcessSnapshot]) -> [ConflictingWindowManager] {
        ConflictingWindowManager.allCases.filter { manager in
            let bundleIdentifiers = manager.bundleIdentifiers
            let executableNames = manager.executableNames
            return snapshots.contains { snapshot in
                snapshot.bundleIdentifier.map(bundleIdentifiers.contains) == true
                    || snapshot.executableName.map(executableNames.contains) == true
            }
        }
    }
}

enum LaunchProcessScanError: Error, Equatable {
    case inventoryUnavailable
    case inventoryIncomplete
    case processIdentityUnavailable(pid_t)
}

enum LaunchExecutableResolution: Equatable {
    case identified(String)
    case exited
    case unavailable
}

@MainActor
enum LaunchProcessScanner {
    struct Environment {
        var processIDs: @MainActor () throws -> [pid_t]
        var executableResolution: @MainActor (pid_t) -> LaunchExecutableResolution

        @MainActor
        static var live: Environment {
            Environment(
                processIDs: currentUserProcessIDs,
                executableResolution: resolveExecutable
            )
        }
    }

    private static let inventoryAttempts = 3
    private static let inventoryHeadroom = 64
    private static let pathCapacity = Int(MAXPATHLEN) * 4
    private static let nameCapacity = Int(MAXPATHLEN)

    static func snapshots(
        excludingPID: pid_t? = nil,
        environment: Environment = .live
    ) throws -> [LaunchProcessSnapshot] {
        try environment.processIDs().compactMap { pid in
            guard pid > 0, pid != excludingPID else { return nil }
            switch environment.executableResolution(pid) {
            case let .identified(executableName):
                return LaunchProcessSnapshot(
                    pid: pid,
                    bundleIdentifier: nil,
                    executableName: executableName
                )
            case .exited:
                return nil
            case .unavailable:
                throw LaunchProcessScanError.processIdentityUnavailable(pid)
            }
        }
    }

    private static func currentUserProcessIDs() throws -> [pid_t] {
        let stride = MemoryLayout<pid_t>.stride
        let requiredBytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard requiredBytes > 0 else {
            throw LaunchProcessScanError.inventoryUnavailable
        }

        var capacity = Int(requiredBytes) / stride + inventoryHeadroom
        for _ in 0 ..< inventoryAttempts {
            var processIDs = [pid_t](repeating: 0, count: capacity)
            let bufferBytes = processIDs.count * stride
            guard bufferBytes <= Int(Int32.max) else {
                throw LaunchProcessScanError.inventoryIncomplete
            }
            let returnedBytes = proc_listpids(
                UInt32(PROC_UID_ONLY),
                getuid(),
                &processIDs,
                Int32(bufferBytes)
            )
            guard returnedBytes > 0 else {
                throw LaunchProcessScanError.inventoryUnavailable
            }
            let returnedByteCount = Int(returnedBytes)
            guard returnedByteCount <= bufferBytes, returnedByteCount % stride == 0 else {
                throw LaunchProcessScanError.inventoryIncomplete
            }
            guard returnedByteCount < bufferBytes else {
                capacity *= 2
                continue
            }
            return Array(processIDs.prefix(returnedByteCount / stride))
        }

        throw LaunchProcessScanError.inventoryIncomplete
    }

    private static func resolveExecutable(pid: pid_t) -> LaunchExecutableResolution {
        var pathBuffer = [CChar](repeating: 0, count: pathCapacity)
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            if let path = decode(pathBuffer),
               let executableName = path.split(separator: "/").last,
               !executableName.isEmpty
            {
                return .identified(String(executableName))
            }
        }

        var nameBuffer = [CChar](repeating: 0, count: nameCapacity)
        if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
            if let executableName = decode(nameBuffer), !executableName.isEmpty {
                return .identified(executableName)
            }
        }

        let status = processStatus(pid: pid)
        let processExited = kill(pid, 0) == -1 && errno == ESRCH
        return unidentifiedResolution(processStatus: status, processExited: processExited)
    }

    nonisolated static func unidentifiedResolution(
        processStatus: UInt32?,
        processExited: Bool
    ) -> LaunchExecutableResolution {
        if processStatus == UInt32(SZOMB) || processExited {
            .exited
        } else {
            .unavailable
        }
    }

    static func processStatus(pid: pid_t) -> UInt32? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var infoSize = MemoryLayout<kinfo_proc>.size
        let result = sysctl(&mib, UInt32(mib.count), &info, &infoSize, nil, 0)
        return result == 0 && infoSize == MemoryLayout<kinfo_proc>.size
            ? UInt32(info.kp_proc.p_stat)
            : nil
    }

    private static func decode(_ buffer: [CChar]) -> String? {
        buffer.withUnsafeBufferPointer { characters in
            let count = characters.firstIndex(of: 0) ?? characters.count
            let bytes = UnsafeRawBufferPointer(start: characters.baseAddress, count: count)
            return String(bytes: bytes, encoding: .utf8)
        }
    }
}
