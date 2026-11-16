import AppKit
import SwiftUI

/// ⌘, で開く設定ウインドウ
struct SettingsView: View {
    @State private var viewModel: ViewModel

    init(viewModel: ViewModel = ViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Form {
            Section {
                // システム設定 > 一般 > ログイン項目の表記に合わせる
                Toggle(
                    "Open at Login",
                    isOn: Binding(get: { viewModel.launchesAtLogin }, set: { viewModel.setLaunchesAtLogin($0) })
                )

                // 一度だけの設定の案内なので、異常のように目立たせず小さく添える。文だけで何をすればよいか読めるよう、許可する場所（ログイン項目）も文で言う
                if viewModel.loginItemStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items") {
                            viewModel.openSystemSettings()
                        }
                    } label: {
                        Label {
                            Text("Approve Breaker in Login Items to open it at login.")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.caution)
                        }
                        .font(.Base.regular)
                    }
                }

                if let failureMessage = viewModel.failureMessage {
                    Label(failureMessage, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(Color.Status.failure)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Breaker keeps running after you close its window, so it can notify you when something breaks.")
                    .font(.Small.regular)
                    .foregroundStyle(.secondary)
            }

            /**
             通信量の注意は速度の計測にだけ掛かるので、ネットワーク名の行の下に付いて見えないよう節を分ける。
             自動の計測は利用者の知らないうちに通信量を使うので、量と、測らない場面を選ぶところで言っておく
             */
            Section {
                Picker("Speed Test", selection: $viewModel.speedTestInterval) {
                    ForEach(SpeedTestInterval.allCases, id: \.self) { interval in
                        Text(interval.title)
                    }
                }
            } header: {
                Text("Network")
            } footer: {
                Text("Each speed test sends and receives about 300 MB. Breaker doesn't run speed tests automatically over a personal hotspot or in Low Data Mode.")
                    .font(.Small.regular)
                    .foregroundStyle(.secondary)
            }

            Section {
                NetworkNameRow(
                    isOn: Binding(
                        get: { viewModel.showsNetworkName },
                        set: { isOn in
                            Task {
                                await viewModel.setShowsNetworkName(isOn)
                            }
                        }
                    ),
                    locationStatus: viewModel.locationStatus,
                    openSystemSettings: viewModel.openLocationSettings
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                viewModel.reloadStatus()
            }
        }
    }
}

extension SettingsView {
    /**
     ネットワーク名のためだけに位置情報を求めるので、トグルをオンにしたときにだけ尋ねる。
     オンなのに拒否されているときは名前が出ない理由が分からないので、オフになっていることを言い、システム設定へ案内する
     */
    struct NetworkNameRow: View {
        @Binding var isOn: Bool
        let locationStatus: LocationAuthorizationStatus
        let openSystemSettings: () -> Void

        var body: some View {
            let isBlocked = isOn && locationStatus == .denied
            Toggle(isOn: $isOn) {
                Text("Show Wi-Fi Network Name")

                if isBlocked {
                    Text("Location Services is off for Breaker")
                } else {
                    Text("Requires Location Services")
                }
            }

            if isBlocked {
                Button("Open Location Services", action: openSystemSettings)
            }
        }
    }
}

#Preview("Enabled") {
    SettingsView(viewModel: .init(loginItem: PreviewLoginItem(status: .enabled), locationAuthorization: PreviewLocationAuthorization(status: .notDetermined), defaults: .preview))
}

#Preview("Requires Approval") {
    SettingsView(viewModel: .init(loginItem: PreviewLoginItem(status: .requiresApproval), locationAuthorization: PreviewLocationAuthorization(status: .authorized), defaults: .preview))
}

#Preview("Not Registered") {
    SettingsView(viewModel: .init(loginItem: PreviewLoginItem(status: .disabled), locationAuthorization: PreviewLocationAuthorization(status: .denied), defaults: .preview))
}
