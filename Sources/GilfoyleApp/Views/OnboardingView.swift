import GilfoyleCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var permissionManager: PermissionManager

    init(controller: AppController) {
        self.controller = controller
        self.permissionManager = controller.permissionManager
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(spacing: 13) {
                    environmentCard
                    permissionsCard
                    integrationsCard
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            footer
        }
        .background(Color(red: 0.035, green: 0.04, blue: 0.05))
        .foregroundStyle(.white.opacity(0.9))
        .frame(minWidth: 680, minHeight: 650)
        .onAppear {
            controller.refreshEnvironment()
            controller.refreshIntegrations()
        }
    }

    private var hero: some View {
        HStack(spacing: 17) {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color(red: 0.57, green: 0.88, blue: 0.73).opacity(0.13))
                AntonMark(size: 30, glows: false)
            }
            .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: 4) {
                Text("Your agents stay in sight.")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Anton keeps Claude Code and Codex visible, reachable, and ready for your next decision.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.48))
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) {
            Divider().overlay(Color.white.opacity(0.07))
        }
    }

    private var environmentCard: some View {
        SetupCard(number: "01", title: "Detected on this Mac") {
            SetupStatusRow(
                title: "Claude Code",
                detail: controller.environment.claudePath ?? "Not found",
                ready: controller.environment.claudePath != nil
            )
            Divider()
            SetupStatusRow(
                title: "Codex",
                detail: controller.environment.codexPath ?? "Not found",
                ready: controller.environment.codexPath != nil
            )
            Divider()
            SetupStatusRow(
                title: "Terminal / iTerm",
                detail: "Exact window and tab targeting",
                ready: controller.environment.terminalInstalled || controller.environment.iTermInstalled
            )
        }
    }

    private var permissionsCard: some View {
        SetupCard(number: "02", title: "macOS permissions") {
            SetupActionRow(
                title: "Terminal automation",
                detail: (permissionManager.automationFailures ?? []).isEmpty
                    ? "Send replies to Terminal and iTerm."
                    : "Not granted for \(permissionManager.automationFailures?.joined(separator: ", ") ?? "").",
                ready: permissionManager.automationReady,
                buttonTitle: "Request…",
                action: {
                    permissionManager.requestAutomation { _ in }
                }
            )
        }
    }

    private var integrationsCard: some View {
        SetupCard(number: "03", title: "Agent integrations") {
            SetupActionRow(
                title: "Claude Code hooks",
                detail: controller.claudeIntegration?.detail ?? "Checking…",
                ready: controller.claudeIntegration?.state == .installed,
                buttonTitle: controller.claudeIntegration?.state == .incomplete ? "Repair" : "Install",
                action: { controller.installIntegration(.claude) }
            )
            Divider()
            SetupActionRow(
                title: "Codex hooks",
                detail: codexDetail,
                ready: controller.codexIntegration?.state == .installed,
                buttonTitle: controller.codexIntegration?.state == .incomplete ? "Repair" : "Install",
                action: { controller.installIntegration(.codex) }
            )
        }
    }

    private var footer: some View {
        HStack {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(Color(red: 0.57, green: 0.88, blue: 0.73))
            Text("No analytics. No cloud. No transcript storage.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
            Spacer()
            Button("Finish setup") {
                controller.completeOnboarding()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 28)
        .frame(height: 64)
        .overlay(alignment: .top) {
            Divider().overlay(Color.white.opacity(0.07))
        }
    }

    private var codexDetail: String {
        if controller.codexIntegration?.state == .installed {
            return "Installed. Review once with /hooks in Codex."
        }
        return controller.codexIntegration?.detail ?? "Checking…"
    }
}

private struct SetupCard<Content: View>: View {
    let number: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(number)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.57, green: 0.88, blue: 0.73))
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.38))
            }
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(0.048))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.8)
            }
        }
    }
}

private struct SetupStatusRow: View {
    let title: String
    let detail: String
    let ready: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ready ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 48)
    }
}

private struct SetupActionRow: View {
    let title: String
    let detail: String
    let ready: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !ready {
                Button(buttonTitle, action: action)
            } else {
                Text("READY")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.green)
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 52)
    }
}
