// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Synchronization

final class RunLoopJob: Sendable {
    private struct State: ~Copyable {
        var cancelled = false
        var scheduledBody: (@Sendable (RunLoopJob) -> Void)?
    }

    private let state = Mutex(State())

    var isCancelled: Bool {
        state.withLock { $0.cancelled }
    }

    func cancel() {
        state.withLock {
            $0.cancelled = true
            $0.scheduledBody = nil
        }
    }

    func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }

    func performUnlessCancelled<T>(_ body: () throws -> T) throws -> T {
        try state.withLock { state in
            if state.cancelled {
                throw CancellationError()
            }
            return try body()
        }
    }

    func schedule(_ body: @escaping @Sendable (RunLoopJob) -> Void) {
        state.withLock { $0.scheduledBody = body }
    }

    func takeScheduledBody() -> (@Sendable (RunLoopJob) -> Void)? {
        state.withLock { $0.scheduledBody.take() }
    }
}
