// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Darwin
import Foundation

struct ProcessResourceSnapshot: Equatable, Sendable {
    struct QoSTime: Equatable, Sendable {
        let background: UInt64
        let maintenance: UInt64
        let utility: UInt64
        let `default`: UInt64
        let userInitiated: UInt64
        let userInteractive: UInt64
        let legacy: UInt64
    }

    let capturedAt: UInt64
    let energyNanojoules: UInt64
    let userTime: UInt64
    let systemTime: UInt64
    let runnableTime: UInt64
    let packageIdleWakeups: UInt64
    let interruptWakeups: UInt64
    let qosTime: QoSTime
    let instructions: UInt64
    let cycles: UInt64
    let pageIns: UInt64
    let diskBytesRead: UInt64
    let diskBytesWritten: UInt64
    let residentSize: UInt64
    let physicalFootprint: UInt64
    let intervalMaxPhysicalFootprint: UInt64

    static func capture() -> ProcessResourceSnapshot? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, rebound)
            }
        }
        guard result == 0 else { return nil }
        return ProcessResourceSnapshot(
            capturedAt: mach_continuous_time(),
            energyNanojoules: info.ri_energy_nj,
            userTime: info.ri_user_time,
            systemTime: info.ri_system_time,
            runnableTime: info.ri_runnable_time,
            packageIdleWakeups: info.ri_pkg_idle_wkups,
            interruptWakeups: info.ri_interrupt_wkups,
            qosTime: QoSTime(
                background: info.ri_cpu_time_qos_background,
                maintenance: info.ri_cpu_time_qos_maintenance,
                utility: info.ri_cpu_time_qos_utility,
                default: info.ri_cpu_time_qos_default,
                userInitiated: info.ri_cpu_time_qos_user_initiated,
                userInteractive: info.ri_cpu_time_qos_user_interactive,
                legacy: info.ri_cpu_time_qos_legacy
            ),
            instructions: info.ri_instructions,
            cycles: info.ri_cycles,
            pageIns: info.ri_pageins,
            diskBytesRead: info.ri_diskio_bytesread,
            diskBytesWritten: info.ri_diskio_byteswritten,
            residentSize: info.ri_resident_size,
            physicalFootprint: info.ri_phys_footprint,
            intervalMaxPhysicalFootprint: info.ri_interval_max_phys_footprint
        )
    }

    func delta(to end: ProcessResourceSnapshot) -> ProcessResourceDelta? {
        guard end.capturedAt >= capturedAt,
              end.userTime >= userTime,
              end.systemTime >= systemTime,
              end.runnableTime >= runnableTime,
              end.packageIdleWakeups >= packageIdleWakeups,
              end.interruptWakeups >= interruptWakeups,
              end.instructions >= instructions,
              end.cycles >= cycles,
              end.pageIns >= pageIns,
              end.diskBytesRead >= diskBytesRead,
              end.diskBytesWritten >= diskBytesWritten,
              end.qosTime.background >= qosTime.background,
              end.qosTime.maintenance >= qosTime.maintenance,
              end.qosTime.utility >= qosTime.utility,
              end.qosTime.default >= qosTime.default,
              end.qosTime.userInitiated >= qosTime.userInitiated,
              end.qosTime.userInteractive >= qosTime.userInteractive,
              end.qosTime.legacy >= qosTime.legacy
        else {
            return nil
        }
        let elapsedSeconds = Self.seconds(fromMachTicks: end.capturedAt - capturedAt)
        guard elapsedSeconds > 0 else { return nil }
        let energyNanojoules: UInt64? = if energyNanojoules == 0 || end.energyNanojoules == 0 {
            nil
        } else if end.energyNanojoules >= energyNanojoules {
            end.energyNanojoules - energyNanojoules
        } else {
            nil
        }
        return ProcessResourceDelta(
            elapsedSeconds: elapsedSeconds,
            energyNanojoules: energyNanojoules,
            userSeconds: Self.seconds(fromMachTicks: end.userTime - userTime),
            systemSeconds: Self.seconds(fromMachTicks: end.systemTime - systemTime),
            runnableSeconds: Self.seconds(fromMachTicks: end.runnableTime - runnableTime),
            packageIdleWakeups: end.packageIdleWakeups - packageIdleWakeups,
            interruptWakeups: end.interruptWakeups - interruptWakeups,
            qosSeconds: .init(
                background: Self.seconds(fromMachTicks: end.qosTime.background - qosTime.background),
                maintenance: Self.seconds(fromMachTicks: end.qosTime.maintenance - qosTime.maintenance),
                utility: Self.seconds(fromMachTicks: end.qosTime.utility - qosTime.utility),
                default: Self.seconds(fromMachTicks: end.qosTime.default - qosTime.default),
                userInitiated: Self.seconds(
                    fromMachTicks: end.qosTime.userInitiated - qosTime.userInitiated
                ),
                userInteractive: Self.seconds(
                    fromMachTicks: end.qosTime.userInteractive - qosTime.userInteractive
                ),
                legacy: Self.seconds(fromMachTicks: end.qosTime.legacy - qosTime.legacy)
            ),
            instructions: end.instructions - instructions,
            cycles: end.cycles - cycles,
            pageIns: end.pageIns - pageIns,
            diskBytesRead: end.diskBytesRead - diskBytesRead,
            diskBytesWritten: end.diskBytesWritten - diskBytesWritten,
            residentSizeStart: residentSize,
            residentSizeEnd: end.residentSize,
            physicalFootprintStart: physicalFootprint,
            physicalFootprintEnd: end.physicalFootprint,
            intervalMaxPhysicalFootprint: end.intervalMaxPhysicalFootprint
        )
    }

    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    private static func seconds(fromMachTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}

struct ProcessResourceDelta: Equatable, Sendable {
    struct QoSTime: Equatable, Sendable {
        let background: Double
        let maintenance: Double
        let utility: Double
        let `default`: Double
        let userInitiated: Double
        let userInteractive: Double
        let legacy: Double
    }

    let elapsedSeconds: Double
    let energyNanojoules: UInt64?
    let userSeconds: Double
    let systemSeconds: Double
    let runnableSeconds: Double
    let packageIdleWakeups: UInt64
    let interruptWakeups: UInt64
    let qosSeconds: QoSTime
    let instructions: UInt64
    let cycles: UInt64
    let pageIns: UInt64
    let diskBytesRead: UInt64
    let diskBytesWritten: UInt64
    let residentSizeStart: UInt64
    let residentSizeEnd: UInt64
    let physicalFootprintStart: UInt64
    let physicalFootprintEnd: UInt64
    let intervalMaxPhysicalFootprint: UInt64

    var energyJoules: Double? {
        energyNanojoules.map { Double($0) / 1_000_000_000 }
    }

    var averageMilliwatts: Double? {
        energyJoules.map { $0 / elapsedSeconds * 1_000 }
    }

    func formatted() -> String {
        let energy = if let energyJoules, let averageMilliwatts {
            String(format: "energy=%.6fJ averagePower=%.3fmW", energyJoules, averageMilliwatts)
        } else {
            "energy=unavailable averagePower=unavailable"
        }
        let cpu = String(
            format: "elapsed=%.3fs user=%.6fs userRate=%.3f%% system=%.6fs systemRate=%.3f%%"
                + " runnable=%.6fs runnableRate=%.3f%%",
            elapsedSeconds,
            userSeconds,
            userSeconds / elapsedSeconds * 100,
            systemSeconds,
            systemSeconds / elapsedSeconds * 100,
            runnableSeconds,
            runnableSeconds / elapsedSeconds * 100
        )
        let wakeups = String(
            format: "packageIdleWakeups=%llu rate=%.3f/s interruptWakeups=%llu rate=%.3f/s",
            packageIdleWakeups,
            Double(packageIdleWakeups) / elapsedSeconds,
            interruptWakeups,
            Double(interruptWakeups) / elapsedSeconds
        )
        let qos = String(
            format: "qos background=%.6fs maintenance=%.6fs utility=%.6fs default=%.6fs"
                + " userInitiated=%.6fs userInteractive=%.6fs legacy=%.6fs",
            qosSeconds.background,
            qosSeconds.maintenance,
            qosSeconds.utility,
            qosSeconds.default,
            qosSeconds.userInitiated,
            qosSeconds.userInteractive,
            qosSeconds.legacy
        )
        let qosRates = String(
            format: "qosRates background=%.6f/s maintenance=%.6f/s utility=%.6f/s default=%.6f/s"
                + " userInitiated=%.6f/s userInteractive=%.6f/s legacy=%.6f/s",
            qosSeconds.background / elapsedSeconds,
            qosSeconds.maintenance / elapsedSeconds,
            qosSeconds.utility / elapsedSeconds,
            qosSeconds.default / elapsedSeconds,
            qosSeconds.userInitiated / elapsedSeconds,
            qosSeconds.userInteractive / elapsedSeconds,
            qosSeconds.legacy / elapsedSeconds
        )
        let counters = String(
            format: "instructions=%llu rate=%.3f/s cycles=%llu rate=%.3f/s pageIns=%llu rate=%.3f/s"
                + " diskRead=%llu rate=%.3fB/s diskWritten=%llu rate=%.3fB/s",
            instructions,
            Double(instructions) / elapsedSeconds,
            cycles,
            Double(cycles) / elapsedSeconds,
            pageIns,
            Double(pageIns) / elapsedSeconds,
            diskBytesRead,
            Double(diskBytesRead) / elapsedSeconds,
            diskBytesWritten,
            Double(diskBytesWritten) / elapsedSeconds
        )
        let memory = "residentStart=\(residentSizeStart) residentEnd=\(residentSizeEnd)"
            + " footprintStart=\(physicalFootprintStart) footprintEnd=\(physicalFootprintEnd)"
            + " intervalMaxFootprint=\(intervalMaxPhysicalFootprint)"
        return [energy, cpu, wakeups, qos, qosRates, counters, memory].joined(separator: "\n")
    }
}
