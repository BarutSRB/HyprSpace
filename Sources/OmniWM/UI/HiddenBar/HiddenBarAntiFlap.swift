// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import Foundation

struct HiddenBarAppliedConfig: Equatable {
    let allowed: Set<String>
    let concealed: Set<String>
    let at: ContinuousClock.Instant
}

struct HiddenBarDesiredConfig: Equatable {
    let allowed: Set<String>
    let concealed: Set<String>
}

enum HiddenBarAntiFlap {
    static let defaultWindow: Duration = .seconds(3)

    static func reactivationDelay(
        desired: HiddenBarDesiredConfig,
        current: HiddenBarAppliedConfig?,
        previousConfig: HiddenBarAppliedConfig?,
        now: ContinuousClock.Instant
    ) -> Duration? {
        guard current != nil,
              let previousConfig,
              previousConfig.allowed == desired.allowed,
              previousConfig.concealed == desired.concealed
        else { return nil }
        let elapsed = previousConfig.at.duration(to: now)
        guard elapsed < defaultWindow else { return nil }
        return defaultWindow - elapsed
    }

    static func shouldReactivate(
        desired: HiddenBarDesiredConfig,
        current: HiddenBarAppliedConfig?,
        previousConfig: HiddenBarAppliedConfig?,
        now: ContinuousClock.Instant
    ) -> Bool {
        let handleIsNil = current == nil
        let concealedChanged = desired.concealed != (current?.concealed ?? [])
        let newlyAppeared = !desired.allowed.subtracting(current?.allowed ?? []).isEmpty

        guard handleIsNil || concealedChanged || newlyAppeared else {
            return false
        }

        if reactivationDelay(
            desired: desired,
            current: current,
            previousConfig: previousConfig,
            now: now
        ) != nil {
            return false
        }

        return true
    }
}
