// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation
@testable import OmniWM
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class MetricsQueryContractTests: XCTestCase {
    func testManifestDescribesTheMetricsQuery() throws {
        let descriptor = try XCTUnwrap(IPCAutomationManifest.queryDescriptor(for: .metrics))
        XCTAssertEqual(descriptor.name, .metrics)
        XCTAssertFalse(descriptor.summary.isEmpty)
        XCTAssertTrue(IPCAutomationManifest.queryDescriptors.contains { $0.name == .metrics })
    }

    func testParserBuildsTheMetricsQuery() throws {
        let parsed = try CLIParser.parse(arguments: ["omniwmctl", "query", "metrics"])
        guard case let .query(request) = parsed.request.payload else {
            return XCTFail("Expected a query payload")
        }
        XCTAssertEqual(request.name, .metrics)
        XCTAssertEqual(parsed.outputFormat, .json)
        XCTAssertFalse(parsed.expectsEventStream)
    }

    func testCompletionsOfferTheMetricsQuery() {
        for shell in CLIShell.allCases {
            let script = CLICompletionGenerator.script(for: shell)
            XCTAssertTrue(script.contains("metrics"), "\(shell) completions should offer the metrics query")
        }
    }

    func testMetricsResultRoundTripsOnTheWire() throws {
        let result = IPCMetricsQueryResult(
            traceCaptureActive: false,
            axWrites: IPCAXWriteMetrics(
                count: 3,
                failureCount: 1,
                meanMicroseconds: 4_530.5,
                maxMicroseconds: 13_600,
                totalMicroseconds: 13_591.5,
                byApp: [
                    IPCAXWriteMetricsBucket(
                        pid: 42,
                        context: 3,
                        app: "Blender",
                        bundleId: "org.blenderfoundation.blender",
                        lane: "ordinary",
                        count: 2,
                        failureCount: 0,
                        meanMicroseconds: 13_600,
                        maxMicroseconds: 15_000,
                        totalMicroseconds: 27_200
                    )
                ]
            ),
            displayTicks: IPCDisplayTickMetrics(
                tickCount: 120,
                timingAnomalyCount: 9,
                longTimestampGapCount: 7,
                workExceededNominalPeriodCount: 3,
                completionPastTargetCount: 5,
                timingAnomalyPercent: 7.5,
                meanWorkMicroseconds: 1_200,
                maxWorkMicroseconds: 24_000,
                maxIntervalMicroseconds: 33_000,
                minEntrySlackMicroseconds: -2_500,
                minCompletionSlackMicroseconds: -13_000
            ),
            layoutBuilds: IPCLayoutBuildMetrics(totalBuilds: 7, completedRelayoutCycles: 5),
            process: IPCProcessResourceMetrics(
                energyNanojoules: 1_234,
                userTimeNanoseconds: 10,
                systemTimeNanoseconds: 20,
                packageIdleWakeups: 30,
                interruptWakeups: 40,
                residentSizeBytes: 50,
                physicalFootprintBytes: 60
            )
        )

        let encoded = try IPCWire.encodeResponseLine(
            .success(id: "metrics", kind: .query, result: IPCResult(metrics: result))
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 15)
        let resultObject = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(resultObject["kind"] as? String, "metrics")

        let decoded = try IPCWire.decodeResponse(from: encoded)
        guard case let .metrics(payload) = try XCTUnwrap(decoded.result).payload else {
            return XCTFail("Expected a metrics payload")
        }
        XCTAssertEqual(payload, result)
    }

    func testMachTimebaseConversionTruncatesAndSaturates() {
        let appleSilicon = MachTimebase(numerator: 125, denominator: 3)
        XCTAssertEqual(appleSilicon.nanoseconds(fromMachTicks: 0), 0)
        XCTAssertEqual(appleSilicon.nanoseconds(fromMachTicks: 1), 41)
        XCTAssertEqual(appleSilicon.nanoseconds(fromMachTicks: 3), 125)
        XCTAssertEqual(appleSilicon.nanoseconds(fromMachTicks: 7), 291)
        XCTAssertEqual(appleSilicon.nanoseconds(fromMachTicks: .max), .max)
        XCTAssertEqual(appleSilicon.seconds(fromMachTicks: 24_000_000), 1, accuracy: 0.000_001)

        let identity = MachTimebase(numerator: 1, denominator: 1)
        XCTAssertEqual(identity.nanoseconds(fromMachTicks: 41), 41)
        XCTAssertEqual(identity.nanoseconds(fromMachTicks: .max), .max)
        XCTAssertEqual(MachTimebase(numerator: 1, denominator: 0).nanoseconds(fromMachTicks: 1), .max)
    }

    func testRouterProjectsProcessCPUTimeThroughTheMachTimebase() {
        let process = ProcessResourceSnapshot(
            capturedAt: 0,
            energyNanojoules: 5,
            userTime: 3,
            systemTime: 7,
            runnableTime: 0,
            packageIdleWakeups: 11,
            interruptWakeups: 13,
            qosTime: .init(
                background: 0,
                maintenance: 0,
                utility: 0,
                default: 0,
                userInitiated: 0,
                userInteractive: 0,
                legacy: 0
            ),
            instructions: 0,
            cycles: 0,
            pageIns: 0,
            diskBytesRead: 0,
            diskBytesWritten: 0,
            residentSize: 17,
            physicalFootprint: 19,
            intervalMaxPhysicalFootprint: 0
        )

        let result = IPCQueryRouter.metricsResult(
            axWrites: .empty,
            displayTicks: DisplayTickMetrics(),
            layoutBuilds: (totalBuilds: 2, completedRelayoutCycles: 1),
            process: process,
            traceCaptureActive: false,
            timebase: MachTimebase(numerator: 125, denominator: 3)
        )

        XCTAssertEqual(
            result.process,
            IPCProcessResourceMetrics(
                energyNanojoules: 5,
                userTimeNanoseconds: 125,
                systemTimeNanoseconds: 291,
                packageIdleWakeups: 11,
                interruptWakeups: 13,
                residentSizeBytes: 17,
                physicalFootprintBytes: 19
            )
        )
        XCTAssertEqual(result.layoutBuilds, IPCLayoutBuildMetrics(totalBuilds: 2, completedRelayoutCycles: 1))
        XCTAssertNil(
            IPCQueryRouter.metricsResult(
                axWrites: .empty,
                displayTicks: DisplayTickMetrics(),
                layoutBuilds: (totalBuilds: 0, completedRelayoutCycles: 0),
                process: nil,
                traceCaptureActive: true
            ).process
        )
    }

    func testDisplayTickMetricsClassifyTicksWithoutACaptureSession() {
        var metrics = DisplayTickMetrics()
        XCTAssertEqual(metrics.tickCount, 0)
        XCTAssertEqual(metrics.timingAnomalyFraction, 0)

        let expectedMs = 1_000.0 / 120
        for _ in 0 ..< 8 {
            metrics.record(
                intervalMs: expectedMs,
                expectedMs: expectedMs,
                workMs: 1.0,
                hasPreviousTick: true,
                entrySlackMs: 5.0,
                completionSlackMs: 4.0
            )
        }
        let gap = metrics.record(
            intervalMs: expectedMs * 3,
            expectedMs: expectedMs,
            workMs: 1.0,
            hasPreviousTick: true,
            entrySlackMs: -2.5,
            completionSlackMs: -3.5
        )
        let overPeriod = metrics.record(
            intervalMs: expectedMs,
            expectedMs: expectedMs,
            workMs: 20.0,
            hasPreviousTick: true,
            entrySlackMs: 7.0,
            completionSlackMs: -13.0
        )

        XCTAssertEqual(
            gap,
            DisplayTickClassification(
                longTimestampGap: true,
                workExceededNominalPeriod: false,
                completionPastTarget: true
            )
        )
        XCTAssertEqual(
            overPeriod,
            DisplayTickClassification(
                longTimestampGap: false,
                workExceededNominalPeriod: true,
                completionPastTarget: true
            )
        )
        XCTAssertEqual(metrics.tickCount, 10)
        XCTAssertEqual(metrics.timingAnomalyCount, 2)
        XCTAssertEqual(metrics.longTimestampGapCount, 1)
        XCTAssertEqual(metrics.workExceededNominalPeriodCount, 1)
        XCTAssertEqual(metrics.completionPastTargetCount, 2)
        XCTAssertEqual(metrics.timingAnomalyFraction, 0.2, accuracy: 0.0001)
        XCTAssertEqual(metrics.meanWorkMicros, 2_900)
        XCTAssertEqual(metrics.maxWorkMicros, 20_000)
        XCTAssertEqual(metrics.maxIntervalMicros, 25_000)
        XCTAssertEqual(metrics.minEntrySlackMicros, -2_500)
        XCTAssertEqual(metrics.minCompletionSlackMicros, -13_000)
    }

    func testOneTickCanCarryEveryClassificationAndCountsOnceAsAnAnomaly() {
        var metrics = DisplayTickMetrics()
        let expectedMs = 1_000.0 / 144

        let classification = metrics.record(
            intervalMs: expectedMs * 5,
            expectedMs: expectedMs,
            workMs: expectedMs * 5,
            hasPreviousTick: true,
            entrySlackMs: 1.0,
            completionSlackMs: -30.0
        )

        XCTAssertTrue(classification.timingAnomaly)
        XCTAssertEqual(metrics.timingAnomalyCount, 1)
        XCTAssertEqual(metrics.longTimestampGapCount, 1)
        XCTAssertEqual(metrics.workExceededNominalPeriodCount, 1)
        XCTAssertEqual(metrics.completionPastTargetCount, 1)
    }

    func testCompletionPastTargetIsIndependentOfTheAnomalyArmsAndFirstTicksNeverGap() {
        var metrics = DisplayTickMetrics()
        let expectedMs = 1_000.0 / 120

        let pastTargetOnly = metrics.record(
            intervalMs: expectedMs,
            expectedMs: expectedMs,
            workMs: expectedMs / 2,
            hasPreviousTick: true,
            entrySlackMs: -1.0,
            completionSlackMs: -0.5
        )
        let firstTick = metrics.record(
            intervalMs: expectedMs * 99,
            expectedMs: expectedMs,
            workMs: expectedMs / 2,
            hasPreviousTick: false,
            entrySlackMs: 3.0,
            completionSlackMs: 2.0
        )

        XCTAssertEqual(
            pastTargetOnly,
            DisplayTickClassification(
                longTimestampGap: false,
                workExceededNominalPeriod: false,
                completionPastTarget: true
            )
        )
        XCTAssertFalse(pastTargetOnly.timingAnomaly)
        XCTAssertEqual(
            firstTick,
            DisplayTickClassification(
                longTimestampGap: false,
                workExceededNominalPeriod: false,
                completionPastTarget: false
            )
        )
        XCTAssertEqual(metrics.timingAnomalyCount, 0)
        XCTAssertEqual(metrics.completionPastTargetCount, 1)
        XCTAssertEqual(metrics.minEntrySlackMicros, -1_000)
        XCTAssertEqual(metrics.minCompletionSlackMicros, -500)
    }

    func testRouterProjectsSignedSlackAndAnomalyPercent() {
        var ticks = DisplayTickMetrics()
        let expectedMs = 1_000.0 / 120
        ticks.record(
            intervalMs: expectedMs,
            expectedMs: expectedMs,
            workMs: 1.0,
            hasPreviousTick: true,
            entrySlackMs: 6.0,
            completionSlackMs: 5.0
        )
        ticks.record(
            intervalMs: expectedMs * 4,
            expectedMs: expectedMs,
            workMs: 2.0,
            hasPreviousTick: true,
            entrySlackMs: -4.0,
            completionSlackMs: -6.0
        )

        let result = IPCQueryRouter.metricsResult(
            axWrites: .empty,
            displayTicks: ticks,
            layoutBuilds: (totalBuilds: 0, completedRelayoutCycles: 0),
            process: nil,
            traceCaptureActive: false
        )

        XCTAssertEqual(
            result.displayTicks,
            IPCDisplayTickMetrics(
                tickCount: 2,
                timingAnomalyCount: 1,
                longTimestampGapCount: 1,
                workExceededNominalPeriodCount: 0,
                completionPastTargetCount: 1,
                timingAnomalyPercent: 50,
                meanWorkMicroseconds: 1_500,
                maxWorkMicroseconds: 2_000,
                maxIntervalMicroseconds: 33_333,
                minEntrySlackMicroseconds: -4_000,
                minCompletionSlackMicroseconds: -6_000
            )
        )
    }

    func testRouterProjectsRegisteredContextIdentityIntoLiveRows() {
        let metrics = AXWriteMetrics()
        let blender = AXWriteMetrics.ContextToken(pid: 4_242, callbackGeneration: 9)
        metrics.register(blender, app: "Blender", bundleId: "org.blenderfoundation.blender")
        metrics.record(blender, lane: .ordinary, nanoseconds: 13_600_000, succeeded: true)
        metrics.record(blender, lane: .ordinary, nanoseconds: 1_400_000, succeeded: false)
        let retired = AXWriteMetrics.ContextToken(pid: 99, callbackGeneration: 4)
        metrics.register(retired, app: "Gone", bundleId: nil)
        metrics.record(retired, lane: .park, nanoseconds: 2_000_000, succeeded: true)
        metrics.retire(retired)

        let result = IPCQueryRouter.metricsResult(
            axWrites: metrics.snapshot(),
            displayTicks: DisplayTickMetrics(),
            layoutBuilds: (totalBuilds: 0, completedRelayoutCycles: 0),
            process: nil,
            traceCaptureActive: false
        )

        XCTAssertEqual(result.axWrites.count, 3)
        XCTAssertEqual(result.axWrites.failureCount, 1)
        XCTAssertEqual(result.axWrites.maxMicroseconds, 13_600)
        XCTAssertEqual(result.axWrites.totalMicroseconds, 17_000)
        XCTAssertEqual(
            result.axWrites.byApp,
            [
                IPCAXWriteMetricsBucket(
                    pid: 4_242,
                    context: 9,
                    app: "Blender",
                    bundleId: "org.blenderfoundation.blender",
                    lane: "ordinary",
                    count: 2,
                    failureCount: 1,
                    meanMicroseconds: 7_500,
                    maxMicroseconds: 13_600,
                    totalMicroseconds: 15_000
                )
            ]
        )
    }
}
