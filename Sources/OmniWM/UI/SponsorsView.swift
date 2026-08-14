// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/BarutSRB/OmniWM

import AppKit
import SwiftUI

struct Sponsor: Identifiable {
    let id = UUID()
    let name: String
    let githubUsername: String?
    let imageName: String?
    let imageExtension: String?
}

private let sponsors: [Sponsor] = [
    Sponsor(name: "Christopher2K", githubUsername: "Christopher2K", imageName: "christopher2k", imageExtension: "jpg"),
    Sponsor(name: "Aelte", githubUsername: "aelte", imageName: "aelte", imageExtension: "png"),
    Sponsor(name: "captainpryce", githubUsername: "captainpryce", imageName: "captainpryce", imageExtension: "jpg"),
    Sponsor(name: "sgrimee", githubUsername: "sgrimee", imageName: "sgrimee", imageExtension: "jpg"),
    Sponsor(name: "aidansunbury", githubUsername: "aidansunbury", imageName: "aidansunbury", imageExtension: "png"),
    Sponsor(name: "dwstevens", githubUsername: "dwstevens", imageName: "dwstevens", imageExtension: "png"),
    Sponsor(name: "swilson2020", githubUsername: "swilson2020", imageName: "swilson2020", imageExtension: "jpg"),
    Sponsor(name: "Jeff Windsor", githubUsername: "jeffwindsor", imageName: "jeffwindsor", imageExtension: "png"),
    Sponsor(name: "Jason Martin", githubUsername: "jsonMartin", imageName: "jsonmartin", imageExtension: "png"),
    Sponsor(name: "dagi3d", githubUsername: "dagi3d", imageName: "dagi3d", imageExtension: "jpg"),
    Sponsor(name: "Aleksei Gurianov", githubUsername: "Guria", imageName: "guria", imageExtension: "png"),
    Sponsor(name: "Stefan Antoni", githubUsername: nil, imageName: nil, imageExtension: nil),
    Sponsor(name: "Naoki Ikeguchi", githubUsername: "siketyan", imageName: "siketyan", imageExtension: "png"),
    Sponsor(name: "Justin Miller", githubUsername: "incanus", imageName: "incanus", imageExtension: "png"),
    Sponsor(name: "benhaotang", githubUsername: "benhaotang", imageName: "benhaotang", imageExtension: "png"),
    Sponsor(name: "Chris M", githubUsername: "tebriel", imageName: "tebriel", imageExtension: "jpg"),
    Sponsor(name: "marckeelingiv", githubUsername: "marckeelingiv", imageName: "marckeelingiv", imageExtension: "png"),
    Sponsor(name: "Nader Akoury", githubUsername: "dojoteef", imageName: "dojoteef", imageExtension: "jpg"),
    Sponsor(name: "Earl Gresh", githubUsername: "earl-gresh", imageName: "earl-gresh", imageExtension: "jpg"),
    Sponsor(name: "Carson Full", githubUsername: "CarsonF", imageName: "carsonf", imageExtension: "jpg")
]

private func rankLabel(for index: Int) -> String {
    let rank = index + 1
    let mod100 = rank % 100
    let suffix: String
    if mod100 >= 11 && mod100 <= 13 {
        suffix = "th"
    } else {
        switch rank % 10 {
        case 1:
            suffix = "st"
        case 2:
            suffix = "nd"
        case 3:
            suffix = "rd"
        default:
            suffix = "th"
        }
    }
    return "\(rank)\(suffix)"
}

private func openURL(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
}

private let sponsorColumnWidth: CGFloat = 760

struct SponsorsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var motionPolicy: MotionPolicy
    @State private var appeared = false
    let onClose: () -> Void

    private var sparkleGradient: LinearGradient {
        LinearGradient(
            colors: [.yellow, .orange],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(motionPolicy: motionPolicy)

            contentVStack
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 480, minHeight: 440)
        .background(.ultraThinMaterial.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .scaleEffect(appeared ? 1.0 : 0.98)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            if motionPolicy.animationsEnabled {
                withAnimation(.easeOut(duration: 0.2)) {
                    appeared = true
                }
            } else {
                appeared = true
            }
        }
        .onChange(of: motionPolicy.animationsEnabled) { _, enabled in
            if !enabled {
                appeared = true
            }
        }
    }

    private var contentVStack: some View {
        VStack(spacing: 16) {
            headerSection

            ReservedSlotsRow(motionPolicy: motionPolicy)
                .padding(.horizontal, 28)

            SupporterScroll(motionPolicy: motionPolicy)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footerSection
        }
        .padding(.vertical, 22)
    }

    private var headerSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22))
                    .foregroundStyle(sparkleGradient)
                    .symbolEffect(.pulse, options: .repeating, isActive: motionPolicy.animationsEnabled)
                Text("Omni Sponsors")
                    .font(.system(size: 26, weight: .bold))
                Image(systemName: "sparkles")
                    .font(.system(size: 22))
                    .foregroundStyle(sparkleGradient)
                    .symbolEffect(.pulse, options: .repeating, isActive: motionPolicy.animationsEnabled)
            }

            Text("Thank you to our amazing supporters!")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            Button(action: { openURL("https://github.com/sponsors/BarutSRB") }) {
                Label("Become a Sponsor", systemImage: "heart.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(OmniGlassButtonStyle(isProminent: true))
            .accessibilityLabel("Become a sponsor on GitHub")
        }
        .padding(.horizontal, 28)
    }

    private var footerSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(action: { openURL("https://paypal.me/beacon2024") }) {
                    Text("Sponsor on PayPal")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(OmniGlassButtonStyle())

                Button(action: onClose) {
                    Text("Close")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 80)
                }
                .buttonStyle(OmniGlassButtonStyle())
            }

            Text("Ranks reflect sponsorship order, not donation amounts")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
    }
}

struct ReservedSlotsRow: View {
    @Bindable var motionPolicy: MotionPolicy

    var body: some View {
        if motionPolicy.animationsEnabled {
            TimelineView(.animation) { context in
                row(time: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            row(time: 0)
        }
    }

    private func row(time: Double) -> some View {
        HStack(spacing: 16) {
            ForEach(0 ..< 3, id: \.self) { _ in
                ReservedSlotCard(motionPolicy: motionPolicy, time: time)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: sponsorColumnWidth)
        .frame(maxWidth: .infinity)
    }
}

struct ReservedSlotCard: View {
    @Bindable var motionPolicy: MotionPolicy
    let time: Double

    private let borderColors: [Color] = [
        Color(white: 0.85),
        Color(white: 0.5),
        Color(white: 0.85)
    ]

    var body: some View {
        Button(action: { openURL("https://github.com/sponsors/BarutSRB") }) {
            cardContent
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reserved for company sponsors — become a sponsor")
    }

    private var cardContent: some View {
        VStack(spacing: 10) {
            Image(systemName: "building.2.crop.circle")
                .font(.system(size: 42))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            Text("Reserved for company sponsors")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            HStack(spacing: 4) {
                Text("Become a sponsor")
                Image(systemName: "arrow.up.right")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .omniGlassEffect(in: RoundedRectangle(cornerRadius: 22))
        .overlay(AnimatedBorder(motionPolicy: motionPolicy, colors: borderColors, time: time))
    }
}

struct SupporterScroll: View {
    @Bindable var motionPolicy: MotionPolicy

    var body: some View {
        AutoScrollList(
            animationsEnabled: motionPolicy.animationsEnabled,
            speed: 18,
            spacing: 16
        ) {
            grid
                .frame(maxWidth: sponsorColumnWidth)
                .frame(maxWidth: .infinity)
        }
        .mask(edgeFade)
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 16)],
            spacing: 16
        ) {
            ForEach(Array(sponsors.enumerated()), id: \.element.id) { index, sponsor in
                SponsorCardView(
                    motionPolicy: motionPolicy,
                    name: sponsor.name,
                    githubUsername: sponsor.githubUsername,
                    imageName: sponsor.imageName,
                    imageExtension: sponsor.imageExtension,
                    tier: .standard,
                    rankLabel: rankLabel(for: index)
                )
            }
        }
    }

    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.05),
                .init(color: .black, location: 0.95),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct AutoScrollList<Content: View>: View {
    let animationsEnabled: Bool
    let speed: CGFloat
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var scrollPosition = ScrollPosition()
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var lastTick: TimeInterval?
    @State private var isUserScrolling = false
    @State private var resumeTask: Task<Void, Never>?

    private var canAutoScroll: Bool {
        animationsEnabled && contentHeight > viewportHeight && contentHeight > 1 && viewportHeight > 1
    }

    private var loopDistance: CGFloat {
        contentHeight + spacing
    }

    private var timelinePaused: Bool {
        !canAutoScroll || isUserScrolling
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: spacing) {
                measuredContent

                if canAutoScroll {
                    content()
                }
            }
        }
        .scrollIndicators(.visible)
        .scrollPosition($scrollPosition)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newValue in
            viewportHeight = newValue
            reconcileAutoScrollState()
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newValue in
            scrollOffsetChanged(newValue)
        }
        .onScrollPhaseChange { _, newPhase in
            scrollPhaseChanged(newPhase)
        }
        .overlay {
            timelineDriver
                .allowsHitTesting(false)
        }
        .onChange(of: animationsEnabled) { _, _ in
            reconcileAutoScrollState()
        }
        .onChange(of: canAutoScroll) { _, _ in
            reconcileAutoScrollState()
        }
        .onDisappear {
            resumeTask?.cancel()
            resumeTask = nil
            lastTick = nil
            isUserScrolling = false
        }
    }

    private var measuredContent: some View {
        content()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newValue in
                contentHeight = newValue
                reconcileAutoScrollState()
            }
    }

    private var timelineDriver: some View {
        TimelineView(.animation(paused: timelinePaused)) { context in
            Color.clear
                .onAppear {
                    tick(context.date)
                }
                .onChange(of: context.date) { _, date in
                    tick(date)
                }
        }
    }

    private func scrollOffsetChanged(_ newValue: CGFloat) {
        guard newValue.isFinite else { return }
        scrollOffset = newValue
        guard canAutoScroll else { return }
        let wrappedOffset = wrapped(newValue)
        guard abs(wrappedOffset - newValue) > 0.5 else { return }
        scrollOffset = wrappedOffset
        scrollPosition.scrollTo(y: wrappedOffset)
        lastTick = nil
    }

    private func scrollPhaseChanged(_ phase: ScrollPhase) {
        guard canAutoScroll else { return }
        let manualPhase = phase == .tracking || phase == .interacting || phase == .decelerating
        if manualPhase {
            resumeTask?.cancel()
            resumeTask = nil
            isUserScrolling = true
            lastTick = nil
        } else if isUserScrolling {
            resumeTask?.cancel()
            resumeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                isUserScrolling = false
                lastTick = nil
            }
        }
    }

    private func tick(_ date: Date) {
        guard canAutoScroll, !isUserScrolling else {
            lastTick = nil
            return
        }

        let timestamp = date.timeIntervalSinceReferenceDate
        guard let lastTick else {
            self.lastTick = timestamp
            return
        }

        let delta = min(max(timestamp - lastTick, 0), 0.1)
        self.lastTick = timestamp
        guard delta > 0 else { return }
        let nextOffset = wrapped(scrollOffset + speed * CGFloat(delta))
        scrollOffset = nextOffset
        scrollPosition.scrollTo(y: nextOffset)
    }

    private func reconcileAutoScrollState() {
        lastTick = nil
        if canAutoScroll {
            let wrappedOffset = wrapped(scrollOffset)
            guard abs(wrappedOffset - scrollOffset) > 0.5 else { return }
            scrollOffset = wrappedOffset
            scrollPosition.scrollTo(y: wrappedOffset)
        } else {
            resumeTask?.cancel()
            resumeTask = nil
            isUserScrolling = false
            let clampedOffset = clamped(scrollOffset)
            guard abs(clampedOffset - scrollOffset) > 0.5 else { return }
            scrollOffset = clampedOffset
            scrollPosition.scrollTo(y: clampedOffset)
        }
    }

    private func wrapped(_ offset: CGFloat) -> CGFloat {
        guard loopDistance > 1 else { return max(0, offset) }
        let remainder = offset.truncatingRemainder(dividingBy: loopDistance)
        return remainder >= 0 ? remainder : remainder + loopDistance
    }

    private func clamped(_ offset: CGFloat) -> CGFloat {
        let maxOffset = max(0, contentHeight - viewportHeight)
        return min(max(offset, 0), maxOffset)
    }
}

private let auroraDark = Color(red: 0.04, green: 0.05, blue: 0.09)

private func auroraInteriorPoints(phase: Double) -> [SIMD2<Float>] {
    let drift = Float(0.05)
    func point(_ baseX: Float, _ baseY: Float, _ offset: Double) -> SIMD2<Float> {
        SIMD2(
            baseX + Float(sin(phase + offset)) * drift,
            baseY + Float(cos(phase + offset)) * drift
        )
    }
    return [
        SIMD2(0.0, 0.0), SIMD2(0.5, 0.0), SIMD2(1.0, 0.0),
        SIMD2(0.0, 0.5), point(0.5, 0.5, 0.0), SIMD2(1.0, 0.5),
        SIMD2(0.0, 1.0), SIMD2(0.5, 1.0), SIMD2(1.0, 1.0)
    ]
}

private var auroraColors: [Color] {
    let gold = SponsorTier.gold.glowColor
    let silver = SponsorTier.silver.glowColor
    let bronze = SponsorTier.bronze.glowColor
    func blend(_ color: Color, _ amount: Double) -> Color {
        color.mix(with: auroraDark, by: amount)
    }
    return [
        blend(gold, 0.55), blend(silver, 0.7), blend(bronze, 0.55),
        blend(silver, 0.6), blend(gold, 0.35), blend(bronze, 0.6),
        blend(bronze, 0.55), blend(gold, 0.7), blend(silver, 0.55)
    ]
}

struct AuroraBackdrop: View {
    @Bindable var motionPolicy: MotionPolicy

    var body: some View {
        ZStack {
            auroraDark
            mesh
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var mesh: some View {
        if motionPolicy.animationsEnabled {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate * 0.12
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: auroraInteriorPoints(phase: phase),
                    colors: auroraColors
                )
            }
        } else {
            MeshGradient(
                width: 3,
                height: 3,
                points: auroraInteriorPoints(phase: 0),
                colors: auroraColors
            )
        }
    }
}

struct AnimatedBorder: View {
    @Bindable var motionPolicy: MotionPolicy
    let colors: [Color]
    let time: Double

    private var angle: Double {
        motionPolicy.animationsEnabled ? time * 60 : 0
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 22)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(colors: colors + [colors[0]]),
                    center: .center,
                    angle: .degrees(angle)
                ),
                lineWidth: 2
            )
    }
}

enum SponsorTier {
    case gold
    case silver
    case bronze
    case standard

    var gradientColors: [Color] {
        switch self {
        case .gold:
            return [
                Color(red: 1.0, green: 0.84, blue: 0.0),
                Color(red: 1.0, green: 0.55, blue: 0.0)
            ]
        case .silver:
            return [
                Color(red: 0.91, green: 0.91, blue: 0.91),
                Color(red: 0.66, green: 0.75, blue: 0.85)
            ]
        case .bronze:
            return [
                Color(red: 0.82, green: 0.41, blue: 0.12),
                Color(red: 0.42, green: 0.24, blue: 0.10)
            ]
        case .standard:
            return [
                Color(red: 0.16, green: 0.62, blue: 0.56),
                Color(red: 0.12, green: 0.44, blue: 0.36)
            ]
        }
    }

    var glowColor: Color {
        switch self {
        case .gold:
            return Color(red: 1.0, green: 0.7, blue: 0.0)
        case .silver:
            return Color(red: 0.6, green: 0.7, blue: 0.85)
        case .bronze:
            return Color(red: 0.75, green: 0.38, blue: 0.12)
        case .standard:
            return Color(red: 0.16, green: 0.62, blue: 0.56)
        }
    }
}

struct SponsorCardView: View {
    @Bindable var motionPolicy: MotionPolicy
    let name: String
    let githubUsername: String?
    let imageName: String?
    let imageExtension: String?
    let tier: SponsorTier
    let rankLabel: String

    @State private var isHovered = false

    private var githubURL: URL? {
        guard let githubUsername else { return nil }
        return URL(string: "https://github.com/\(githubUsername)")
    }

    var body: some View {
        linkedCardContent
            .onHover { hovering in
                isHovered = hovering
            }
    }

    @ViewBuilder private var linkedCardContent: some View {
        if let githubURL {
            Button(action: {
                NSWorkspace.shared.open(githubURL)
            }) {
                cardContent
            }
            .buttonStyle(.plain)
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        VStack(spacing: 16) {
            GlowingAvatarView(
                motionPolicy: motionPolicy,
                imageName: imageName,
                imageExtension: imageExtension,
                tier: tier
            )

            VStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)

                profileLabel
            }

            Text(rankLabel)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: tier.gradientColors,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: tier.glowColor.opacity(isHovered ? 0.3 : 0.1), radius: isHovered ? 12 : 6)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(motionPolicy.animationsEnabled ? .easeOut(duration: 0.15) : nil, value: isHovered)
    }

    @ViewBuilder private var profileLabel: some View {
        if let githubUsername {
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 11))
                Text("@\(githubUsername)")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
            }
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                Text("GitHub profile unknown")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct GlowingAvatarView: View {
    @Bindable var motionPolicy: MotionPolicy
    let imageName: String?
    let imageExtension: String?
    let tier: SponsorTier
    var ringSize: CGFloat = 88

    @State private var isAnimating = false

    private var avatarImage: NSImage? {
        guard let imageName,
              let imageExtension,
              let url = Bundle.module.url(forResource: imageName, withExtension: imageExtension),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        return image
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    LinearGradient(
                        colors: tier.gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 4
                )
                .frame(width: ringSize, height: ringSize)
                .shadow(
                    color: tier.glowColor.opacity(isAnimating ? 0.8 : 0.5),
                    radius: isAnimating ? 12 : 8
                )

            if let image = avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: ringSize - 12, height: ringSize - 12)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(.quaternary)
                    .frame(width: ringSize - 12, height: ringSize - 12)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .onAppear {
            updateAnimationState()
        }
        .onChange(of: motionPolicy.animationsEnabled) { _, _ in
            updateAnimationState()
        }
    }

    private func updateAnimationState() {
        guard motionPolicy.animationsEnabled, tier != .standard else {
            isAnimating = false
            return
        }

        isAnimating = false
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            isAnimating = true
        }
    }
}
