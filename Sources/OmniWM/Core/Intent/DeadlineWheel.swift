// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

@MainActor
final class DeadlineWheel {
    private struct Entry {
        let intentId: IntentID
        let deadline: ContinuousClock.Instant
        let generation: UInt64
    }

    var clock: () -> ContinuousClock.Instant = { ContinuousClock().now }
    var sleepUntil: @MainActor (ContinuousClock.Instant) async throws -> Void = { deadline in
        try await Task.sleep(until: deadline, clock: .continuous)
    }

    private var entries: [Entry] = []
    private var currentGenerationByIntentId: [IntentID: UInt64] = [:]
    private var nextGeneration: UInt64 = 0
    private var timerTask: Task<Void, Never>?
    private var armedDeadline: ContinuousClock.Instant?

    @discardableResult
    func schedule(intentId: IntentID, after duration: Duration) -> UInt64 {
        schedule(intentId: intentId, deadline: clock().advanced(by: duration))
    }

    @discardableResult
    func schedule(intentId: IntentID, deadline: ContinuousClock.Instant) -> UInt64 {
        nextGeneration &+= 1
        let generation = nextGeneration
        entries.removeAll { $0.intentId == intentId }
        entries.append(Entry(intentId: intentId, deadline: deadline, generation: generation))
        currentGenerationByIntentId[intentId] = generation
        entries.sort { $0.deadline < $1.deadline }
        rearm()
        return generation
    }

    func cancel(intentId: IntentID) {
        entries.removeAll { $0.intentId == intentId }
        currentGenerationByIntentId.removeValue(forKey: intentId)
        rearm()
    }

    func consumeExpiration(intentId: IntentID, generation: UInt64) -> Bool {
        guard currentGenerationByIntentId[intentId] == generation else { return false }
        currentGenerationByIntentId.removeValue(forKey: intentId)
        return true
    }

    func stop() {
        entries.removeAll(keepingCapacity: false)
        currentGenerationByIntentId.removeAll(keepingCapacity: false)
        timerTask?.cancel()
        timerTask = nil
        armedDeadline = nil
    }

    func tick() {
        let now = clock()
        var due: [Entry] = []
        entries.removeAll { entry in
            guard entry.deadline <= now else { return false }
            due.append(entry)
            return true
        }
        for entry in due {
            EventIntake.post(
                .intentExpired(
                    intentId: entry.intentId,
                    deadlineGeneration: entry.generation
                )
            )
        }
        rearm()
    }

    private func rearm() {
        guard let next = entries.first else {
            timerTask?.cancel()
            timerTask = nil
            armedDeadline = nil
            return
        }
        if let armedDeadline, armedDeadline == next.deadline, timerTask != nil {
            return
        }
        timerTask?.cancel()
        armedDeadline = next.deadline
        timerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await sleepUntil(next.deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            timerTask = nil
            armedDeadline = nil
            tick()
        }
    }
}
