import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, features, permissions, preferences, done
}

/// Container: soft glow background, animated step content, page dots and Back / Continue.
struct OnboardingView: View {
    /// Called when the user finishes. `section` is an AppSection raw value to open, if any.
    var onFinish: (_ section: String?) -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var forward = true
    @State private var model = PermissionsModel()

    private var isFirst: Bool { step == .welcome }
    private var isLast: Bool { step == .done }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                footer
            }
            .padding(.top, 28)   // clear the transparent titlebar
        }
        .frame(width: 720, height: 520)
        .onChange(of: step) { _, new in
            if new == .permissions { model.start() } else { model.stop() }
        }
        .onDisappear { model.stop() }
    }

    // MARK: Background

    private var background: some View {
        ZStack {
            Circle().fill(Theme.Palette.blue[1].opacity(0.22)).frame(width: 380).blur(radius: 90)
                .offset(x: -240, y: -170)
            Circle().fill(Theme.Palette.purple[1].opacity(0.20)).frame(width: 340).blur(radius: 90)
                .offset(x: 260, y: 150)
            Circle().fill(Theme.Palette.mint[1].opacity(0.14)).frame(width: 260).blur(radius: 80)
                .offset(x: 230, y: -190)
        }
        .allowsHitTesting(false)
    }

    // MARK: Content

    private var content: some View {
        ZStack {
            switch step {
            case .welcome: OnboardingWelcomeStep()
            case .features: OnboardingFeaturesStep()
            case .permissions: OnboardingPermissionsStep(model: model)
            case .preferences: OnboardingPreferencesStep()
            case .done: OnboardingDoneStep(model: model) { onFinish("permissions") }
            }
        }
        .id(step)
        .transition(.asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
        .padding(.horizontal, 44)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Group {
                if isFirst || isLast {
                    Color.clear
                } else {
                    Button("Back") { go(-1) }
                        .buttonStyle(.mmSecondary)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
            }
            .frame(width: 130, alignment: .leading)

            Spacer(minLength: 0)
            dots
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if step == .permissions {
                    Button("Skip for now") { go(1) }.buttonStyle(.mmGhost)
                }
                Button(primaryTitle) { primaryAction() }
                    .buttonStyle(.mmPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(minWidth: 130, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .done: "Open MacMaster"
        default: "Continue"
        }
    }

    private func primaryAction() {
        if isLast { onFinish("dashboard") } else { go(1) }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s == step ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: s == step ? 20 : 7, height: 7)
            }
        }
        .animation(.smooth(duration: 0.3), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    private func go(_ delta: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        // Let the new direction land first so the outgoing view uses the right transition.
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.38)) { step = next }
        }
    }
}
