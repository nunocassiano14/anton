import GilfoyleCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var permissionManager: PermissionManager

    init(controller: AppController) {
        self.controller = controller
        self.permissionManager = controller.permissionManager
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                title

                SettingsSection(title: "AGENT INTEGRATIONS", icon: "point.3.connected.trianglepath.dotted") {
                    IntegrationSettingsRow(
                        agent: .claude,
                        status: controller.claudeIntegration,
                        install: { controller.installIntegration(.claude) },
                        remove: { controller.removeIntegration(.claude) }
                    )
                    Divider()
                    IntegrationSettingsRow(
                        agent: .codex,
                        status: controller.codexIntegration,
                        install: { controller.installIntegration(.codex) },
                        remove: { controller.removeIntegration(.codex) }
                    )
                }

                SettingsSection(title: "TERMINAL AUTOMATION", icon: "terminal") {
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 9) {
                                Image(systemName: permissionManager.automationRequestAttempted ? "checkmark.circle.fill" : "circle.dashed")
                                    .foregroundStyle(permissionManager.automationRequestAttempted ? Color.green : Color.orange)
                                Text("Terminal & iTerm")
                                    .font(.system(size: 12.5, weight: .medium))
                            }
                            Text("Required to reply directly to the original agent tab.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(permissionManager.automationRequestAttempted ? "Check again" : "Enable…") {
                            permissionManager.requestAutomation { failures in
                                if !failures.isEmpty {
                                    controller.transientMessage = "Automation was not granted for \(failures.joined(separator: ", "))."
                                } else {
                                    controller.transientMessage = "Terminal automation is ready."
                                }
                            }
                        }
                    }
                }

            }
            .padding(26)
        }
        .background(Color(red: 0.035, green: 0.04, blue: 0.05))
        .foregroundStyle(.white.opacity(0.9))
        .frame(minWidth: 600, minHeight: 360)
        .onAppear {
            controller.refreshEnvironment()
            controller.refreshIntegrations()
        }
    }

    private var title: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(red: 0.57, green: 0.88, blue: 0.73).opacity(0.15))
                AntonMark(size: 23, glows: false)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("Anton")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Local agent handoff for your Mac")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.42))
            }
            Spacer()
            Text("LOCAL ONLY")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(Color(red: 0.57, green: 0.88, blue: 0.73))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color(red: 0.57, green: 0.88, blue: 0.73).opacity(0.1)))
        }
    }

}

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title)
                    .tracking(0.8)
            }
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.36))

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

struct SettingsRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            content
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 48)
    }
}

private struct IntegrationSettingsRow: View {
    let agent: AgentKind
    let status: IntegrationStatus?
    let install: () -> Void
    let remove: () -> Void

    var body: some View {
        SettingsRow {
            Circle()
                .fill(agentColor(agent))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                Text(status?.detail ?? "Checking integration…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status?.state == .installed {
                Text("READY")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.green)
                Button("Remove", action: remove)
            } else {
                Button(status?.state == .incomplete ? "Repair" : "Install", action: install)
            }
        }
    }
}
