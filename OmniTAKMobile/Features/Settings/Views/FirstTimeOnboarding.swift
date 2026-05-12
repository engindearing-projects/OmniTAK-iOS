//
//  FirstTimeOnboarding.swift
//  OmniTAKMobile
//
//  Fat-thumb 8-page first-run onboarding (PR B).
//  Designed for users in gloves, in the field, who have never seen TAK.
//  Hard rules: 64pt primary buttons, 18pt body, single decision per page,
//  every visible string localized via String(localized:).
//

import SwiftUI
import CoreLocation
import CoreBluetooth
import UserNotifications

// MARK: - Onboarding Page Enum

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case about
    case location
    case bluetooth
    case notifications
    case callsign
    case team
    case connect
}

// MARK: - First Time Onboarding

struct FirstTimeOnboarding: View {
    @Environment(\.dismiss) private var dismiss
    @State private var step: OnboardingStep = .welcome
    @State private var showEnrollment = false
    @State private var showQRScanner = false
    @State private var showImporter = false
    @State private var showReady = false
    // Public demo server requires an explicit confirmation step — the
    // tile only opens this sheet; the actual connect happens after the
    // user confirms they understand it's a public server.
    @State private var showDemoServerConfirmation = false
    @StateObject private var permissions = PermissionsCoordinator()

    // Persistent user choices.
    @AppStorage("userCallsign") private var userCallsign: String = ""
    @AppStorage("userTeamColor") private var userTeamColor: String = "Cyan"
    @AppStorage("userRole") private var userRole: String = "Team Member"
    @AppStorage("userPosition") private var userPosition: String = "Team Member"
    @AppStorage("appLanguage") private var appLanguageRaw: String = ""

    var onComplete: () -> Void = {}

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                contentArea
                pageDots
                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, currentLocale())
        .fullScreenCover(isPresented: $showEnrollment) {
            SimpleEnrollView()
                .onDisappear { finish() }
        }
        .fullScreenCover(isPresented: $showReady) {
            ReadyToFlyView { finish() }
        }
        .alert(
            String(localized: "onboarding.connect.demo.confirm.title",
                   comment: "Demo server confirmation title"),
            isPresented: $showDemoServerConfirmation
        ) {
            Button(
                String(localized: "onboarding.connect.demo.confirm.cta",
                       comment: "Demo server confirm CTA"),
                role: .destructive
            ) {
                DemoServerConnector.connect()
                showReady = true
            }
            .accessibilityIdentifier("onboarding.connect.demo.confirm.cta")
            Button(
                String(localized: "onboarding.connect.demo.confirm.cancel",
                       comment: "Demo server confirm cancel"),
                role: .cancel
            ) {}
        } message: {
            Text(String(localized: "onboarding.connect.demo.confirm.body",
                        comment: "Demo server confirmation body"))
        }
        .onAppear {
            if userCallsign.isEmpty {
                userCallsign = Self.generateCallsign()
            }
        }
    }

    // MARK: - Top bar (Skip)

    private var topBar: some View {
        HStack {
            Spacer()
            Button {
                onComplete()
                dismiss()
            } label: {
                Text(String(localized: "common.skip", comment: "Skip onboarding"))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(Color(hex: "#CCCCCC"))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .accessibilityIdentifier("onboarding.skip")
        }
        .padding(.top, 8)
    }

    // MARK: - Page dots

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s == step ? Color(hex: "#FFFC00") : Color(hex: "#444444"))
                    .frame(width: s == step ? 24 : 8, height: 8)
                    .animation(.spring(response: 0.3), value: step)
            }
        }
        .padding(.vertical, 16)
    }

    // MARK: - Bottom bar (Back)

    private var bottomBar: some View {
        Group {
            if step != .welcome {
                Button {
                    if let prev = OnboardingStep(rawValue: step.rawValue - 1) {
                        withAnimation { step = prev }
                    }
                } label: {
                    Text(String(localized: "common.back", comment: "Onboarding back button"))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Color(hex: "#AAAAAA"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .accessibilityIdentifier("onboarding.back")
            } else {
                Spacer().frame(height: 48)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    // MARK: - Content router

    @ViewBuilder
    private var contentArea: some View {
        switch step {
        case .welcome: welcomePage
        case .about: aboutPage
        case .location: locationPage
        case .bluetooth: bluetoothPage
        case .notifications: notificationsPage
        case .callsign: callsignPage
        case .team: teamPage
        case .connect: connectPage
        }
    }

    private func advance(to next: OnboardingStep) {
        withAnimation { step = next }
    }

    private func finish() {
        onComplete()
        dismiss()
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 24) {
            languagePicker
                .padding(.top, 8)

            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                .font(.system(size: 96, weight: .light))
                .foregroundColor(Color(hex: "#FFFC00"))

            Text(String(localized: "onboarding.welcome.title", comment: "Welcome page title"))
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Text(String(localized: "onboarding.welcome.subtitle", comment: "Welcome page subtitle"))
                .font(.system(size: 18))
                .foregroundColor(Color(hex: "#CCCCCC"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            FatThumbPrimaryButton(
                title: String(localized: "onboarding.welcome.cta", comment: "Welcome page primary CTA"),
                accessibilityID: "onboarding.welcome.cta"
            ) {
                advance(to: .about)
            }
            .padding(.horizontal, 24)
        }
    }

    private var languagePicker: some View {
        HStack(spacing: 10) {
            languagePill(code: "en", flag: "🇺🇸", label: String(localized: "onboarding.language.english", comment: "English language pill"))
            languagePill(code: "pl", flag: "🇵🇱", label: String(localized: "onboarding.language.polish", comment: "Polish language pill"))
            languagePill(code: "de", flag: "🇩🇪", label: String(localized: "onboarding.language.german", comment: "German language pill"))
            languagePill(code: "fr", flag: "🇫🇷", label: String(localized: "onboarding.language.french", comment: "French language pill"))
        }
        .padding(.horizontal, 16)
    }

    private func languagePill(code: String, flag: String, label: String) -> some View {
        let selected = activeLanguage() == code
        return Button {
            appLanguageRaw = code
            // Tell SwiftUI to refresh the locale-bound text. The strings catalog
            // is selected via Bundle.main but our environment override below
            // ensures the picker preview itself updates immediately.
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } label: {
            VStack(spacing: 2) {
                Text(flag).font(.system(size: 24))
                Text(label.prefix(2).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(selected ? .black : .white)
            }
            .frame(width: 60, height: 60)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(selected ? Color(hex: "#FFFC00") : Color(white: 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(selected ? Color(hex: "#FFFC00") : Color(white: 0.3), lineWidth: 2)
            )
        }
        .accessibilityIdentifier("onboarding.lang.\(code)")
    }

    private func activeLanguage() -> String {
        if !appLanguageRaw.isEmpty { return appLanguageRaw }
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return ["en", "pl", "de", "fr"].contains(preferred) ? preferred : "en"
    }

    private func currentLocale() -> Locale {
        Locale(identifier: activeLanguage())
    }

    // MARK: - Page 2: About

    private var aboutPage: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 8)
            Text(String(localized: "onboarding.about.title", comment: "About page title"))
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text(String(localized: "onboarding.about.subtitle", comment: "About page subtitle"))
                .font(.system(size: 17))
                .foregroundColor(Color(hex: "#AAAAAA"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(spacing: 14) {
                FeaturePillar(
                    icon: "location.fill",
                    title: String(localized: "onboarding.about.feature.location.title", comment: "Real-time location feature"),
                    detail: String(localized: "onboarding.about.feature.location.body", comment: "Real-time location feature body"),
                    color: Color(hex: "#00FF66")
                )
                FeaturePillar(
                    icon: "lock.shield.fill",
                    title: String(localized: "onboarding.about.feature.comms.title", comment: "Secure comms feature"),
                    detail: String(localized: "onboarding.about.feature.comms.body", comment: "Secure comms feature body"),
                    color: Color(hex: "#00BFFF")
                )
                FeaturePillar(
                    icon: "map.fill",
                    title: String(localized: "onboarding.about.feature.map.title", comment: "Map awareness feature"),
                    detail: String(localized: "onboarding.about.feature.map.body", comment: "Map awareness feature body"),
                    color: Color(hex: "#FFFC00")
                )
                FeaturePillar(
                    icon: "iphone.gen3.radiowaves.left.and.right",
                    title: String(localized: "onboarding.about.feature.crossPlatform.title", comment: "Cross-platform feature"),
                    detail: String(localized: "onboarding.about.feature.crossPlatform.body", comment: "Cross-platform feature body"),
                    color: Color(hex: "#FF6B35")
                )
            }
            .padding(.horizontal, 20)

            Spacer()

            FatThumbPrimaryButton(
                title: String(localized: "common.continue", comment: "Generic continue button"),
                accessibilityID: "onboarding.about.continue"
            ) { advance(to: .location) }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Page 3: Location

    private var locationPage: some View {
        permissionPage(
            icon: "location.circle.fill",
            iconColor: Color(hex: "#00BFFF"),
            title: String(localized: "onboarding.location.title", comment: "Location permission title"),
            subtitle: String(localized: "onboarding.location.subtitle", comment: "Location permission subtitle"),
            bullets: [
                String(localized: "onboarding.location.bullet.share", comment: "Location bullet 1"),
                String(localized: "onboarding.location.bullet.see", comment: "Location bullet 2"),
                String(localized: "onboarding.location.bullet.background", comment: "Location bullet 3")
            ],
            grantedTitle: String(localized: "onboarding.location.granted", comment: "Location enabled label"),
            granted: permissions.locationGranted,
            primary: String(localized: "onboarding.location.allow", comment: "Allow location button"),
            primaryID: "onboarding.location.allow",
            onPrimary: { permissions.requestLocation { advance(to: .bluetooth) } },
            onSkip: { advance(to: .bluetooth) }
        )
    }

    // MARK: - Page 4: Bluetooth

    private var bluetoothPage: some View {
        permissionPage(
            icon: "dot.radiowaves.left.and.right",
            iconColor: Color(hex: "#00FF66"),
            title: String(localized: "onboarding.bluetooth.title", comment: "Bluetooth permission title"),
            subtitle: String(localized: "onboarding.bluetooth.subtitle", comment: "Bluetooth permission subtitle"),
            bullets: [
                String(localized: "onboarding.bluetooth.bullet.lora", comment: "Bluetooth bullet 1"),
                String(localized: "onboarding.bluetooth.bullet.range", comment: "Bluetooth bullet 2"),
                String(localized: "onboarding.bluetooth.bullet.optional", comment: "Bluetooth bullet 3")
            ],
            grantedTitle: String(localized: "onboarding.bluetooth.granted", comment: "Bluetooth enabled label"),
            granted: permissions.bluetoothGranted,
            primary: String(localized: "onboarding.bluetooth.allow", comment: "Allow bluetooth button"),
            primaryID: "onboarding.bluetooth.allow",
            onPrimary: { permissions.requestBluetooth { advance(to: .notifications) } },
            onSkip: { advance(to: .notifications) }
        )
    }

    // MARK: - Page 5: Notifications

    private var notificationsPage: some View {
        permissionPage(
            icon: "bell.badge.fill",
            iconColor: Color(hex: "#FFFC00"),
            title: String(localized: "onboarding.notifications.title", comment: "Notifications permission title"),
            subtitle: String(localized: "onboarding.notifications.subtitle", comment: "Notifications permission subtitle"),
            bullets: [
                String(localized: "onboarding.notifications.bullet.dm", comment: "Notifications bullet 1"),
                String(localized: "onboarding.notifications.bullet.geofence", comment: "Notifications bullet 2"),
                String(localized: "onboarding.notifications.bullet.server", comment: "Notifications bullet 3")
            ],
            grantedTitle: String(localized: "onboarding.notifications.granted", comment: "Notifications enabled label"),
            granted: permissions.notificationsGranted,
            primary: String(localized: "onboarding.notifications.allow", comment: "Allow notifications button"),
            primaryID: "onboarding.notifications.allow",
            onPrimary: { permissions.requestNotifications { advance(to: .callsign) } },
            onSkip: { advance(to: .callsign) }
        )
    }

    // MARK: - Page 6: Callsign

    @State private var showCustomCallsignSheet = false
    @State private var pendingCustomCallsign = ""

    private var callsignPage: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 4)

            Image(systemName: "person.text.rectangle.fill")
                .font(.system(size: 80, weight: .light))
                .foregroundColor(Color(hex: "#FFFC00"))

            Text(String(localized: "onboarding.callsign.title", comment: "Callsign page title"))
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)

            Text(String(localized: "onboarding.callsign.subtitle", comment: "Callsign page subtitle"))
                .font(.system(size: 18))
                .foregroundColor(Color(hex: "#AAAAAA"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text(userCallsign.isEmpty ? Self.generateCallsign() : userCallsign)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: "#FFFC00"))
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(hex: "#FFFC00"), lineWidth: 2)
                )
                .padding(.horizontal, 24)
                .accessibilityIdentifier("onboarding.callsign.value")

            Spacer()

            FatThumbPrimaryButton(
                title: String(localized: "onboarding.callsign.use", comment: "Use this callsign button"),
                accessibilityID: "onboarding.callsign.use"
            ) { advance(to: .team) }
            .padding(.horizontal, 24)

            Button {
                pendingCustomCallsign = userCallsign
                showCustomCallsignSheet = true
            } label: {
                Text(String(localized: "onboarding.callsign.choose", comment: "Choose your own callsign"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(hex: "#AAAAAA"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .accessibilityIdentifier("onboarding.callsign.choose")
        }
        .sheet(isPresented: $showCustomCallsignSheet) {
            CustomCallsignSheet(value: $pendingCustomCallsign) {
                if !pendingCustomCallsign.isEmpty {
                    userCallsign = pendingCustomCallsign
                }
                showCustomCallsignSheet = false
            }
        }
    }

    // MARK: - Page 7: Team / Role / Position

    private var teamPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(String(localized: "onboarding.team.title", comment: "Team page title"))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text(String(localized: "onboarding.team.subtitle", comment: "Team page subtitle"))
                    .font(.system(size: 17))
                    .foregroundColor(Color(hex: "#AAAAAA"))

                Text(String(localized: "onboarding.team.colorLabel", comment: "Team color label"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "#888888"))
                    .padding(.top, 8)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60, maximum: 60), spacing: 12)], spacing: 12) {
                    ForEach(OnboardingTeamColor.allCases, id: \.id) { color in
                        TeamColorSwatch(color: color, selected: userTeamColor == color.id) {
                            userTeamColor = color.id
                        }
                    }
                }

                Text(String(localized: "onboarding.team.roleLabel", comment: "Team role label"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "#888888"))
                    .padding(.top, 8)

                ChipGroup(
                    items: OnboardingTeamRole.allCases.map { ($0.id, $0.localizedName) },
                    selectedID: $userRole
                )

                Text(String(localized: "onboarding.team.positionLabel", comment: "Team position label"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "#888888"))
                    .padding(.top, 8)

                Menu {
                    ForEach(OnboardingTeamRole.allCases, id: \.id) { role in
                        Button(role.localizedName) { userPosition = role.id }
                    }
                } label: {
                    HStack {
                        Text(OnboardingTeamRole(id: userPosition)?.localizedName ?? userPosition)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .foregroundColor(Color(hex: "#FFFC00"))
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 56)
                    .background(Color(white: 0.10))
                    .cornerRadius(14)
                }

                FatThumbPrimaryButton(
                    title: String(localized: "common.continue", comment: "Continue"),
                    accessibilityID: "onboarding.team.continue"
                ) { advance(to: .connect) }
                .padding(.top, 16)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Page 8: Connect

    private var connectPage: some View {
        VStack(spacing: 16) {
            Text(String(localized: "onboarding.connect.title", comment: "Connect page title"))
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 8)

            Text(String(localized: "onboarding.connect.subtitle", comment: "Connect page subtitle"))
                .font(.system(size: 17))
                .foregroundColor(Color(hex: "#AAAAAA"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(spacing: 14) {
                ConnectTile(
                    icon: "checkmark.seal.fill",
                    iconColor: Color(hex: "#00FF66"),
                    title: String(localized: "onboarding.connect.demo.title", comment: "Demo server tile title"),
                    detail: String(localized: "onboarding.connect.demo.body", comment: "Demo server tile body"),
                    time: String(localized: "onboarding.connect.demo.time", comment: "Demo server time"),
                    accessibilityID: "onboarding.connect.demo"
                ) {
                    // Tile tap only opens the disclosure sheet — the
                    // actual connect requires explicit confirmation
                    // because tak.engindearing.soy is a PUBLIC server.
                    showDemoServerConfirmation = true
                }

                ConnectTile(
                    icon: "qrcode.viewfinder",
                    iconColor: Color(hex: "#00BFFF"),
                    title: String(localized: "onboarding.connect.qr.title", comment: "QR tile title"),
                    detail: String(localized: "onboarding.connect.qr.body", comment: "QR tile body"),
                    time: String(localized: "onboarding.connect.qr.time", comment: "QR tile time"),
                    accessibilityID: "onboarding.connect.qr"
                ) {
                    showEnrollment = true
                }

                ConnectTile(
                    icon: "tray.and.arrow.down.fill",
                    iconColor: Color(hex: "#FFFC00"),
                    title: String(localized: "onboarding.connect.import.title", comment: "Import tile title"),
                    detail: String(localized: "onboarding.connect.import.body", comment: "Import tile body"),
                    time: String(localized: "onboarding.connect.import.time", comment: "Import tile time"),
                    accessibilityID: "onboarding.connect.import"
                ) {
                    showEnrollment = true
                }
            }
            .padding(.horizontal, 20)

            Spacer()

            Button {
                finish()
            } label: {
                Text(String(localized: "onboarding.connect.skip", comment: "Skip server connect"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(hex: "#AAAAAA"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .accessibilityIdentifier("onboarding.connect.skip")
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Helpers

    private func permissionPage(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        bullets: [String],
        grantedTitle: String,
        granted: Bool,
        primary: String,
        primaryID: String,
        onPrimary: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 4)

            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.system(size: 84, weight: .light))
                .foregroundColor(granted ? Color(hex: "#00FF66") : iconColor)

            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Text(subtitle)
                .font(.system(size: 17))
                .foregroundColor(Color(hex: "#AAAAAA"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(bullets, id: \.self) { line in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(iconColor)
                            .padding(.top, 4)
                        Text(line)
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 4)

            Spacer()

            if granted {
                Text(grantedTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(hex: "#00FF66"))
            }

            FatThumbPrimaryButton(
                title: primary,
                accessibilityID: primaryID,
                disabled: granted
            ) { onPrimary() }
            .padding(.horizontal, 24)

            Button {
                onSkip()
            } label: {
                Text(String(localized: "common.maybeLater", comment: "Maybe later button"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(hex: "#888888"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
        }
    }

    static func generateCallsign() -> String {
        let suffix = (1000...9999).randomElement() ?? 1234
        return "OPERATOR-\(suffix)"
    }
}

// MARK: - Fat-thumb primary button

private struct FatThumbPrimaryButton: View {
    let title: String
    let accessibilityID: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(disabled ? Color(hex: "#888888") : Color(hex: "#FFFC00"))
                .cornerRadius(16)
        }
        .disabled(disabled)
        .accessibilityIdentifier(accessibilityID)
    }
}

// MARK: - Feature pillar row

private struct FeaturePillar: View {
    let icon: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(color)
                .frame(width: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: "#AAAAAA"))
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(14)
        .background(Color(white: 0.10))
        .cornerRadius(14)
    }
}

// MARK: - Connect tile

private struct ConnectTile: View {
    let icon: String
    let iconColor: Color
    let title: String
    let detail: String
    let time: String
    let accessibilityID: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#AAAAAA"))
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 11))
                        Text(time)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(iconColor)
                    .padding(.top, 2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(hex: "#666666"))
            }
            .padding(14)
            .frame(minHeight: 80)
            .background(Color(white: 0.10))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(iconColor.opacity(0.3), lineWidth: 1)
            )
        }
        .accessibilityIdentifier(accessibilityID)
    }
}

// MARK: - Custom callsign sheet

private struct CustomCallsignSheet: View {
    @Binding var value: String
    let onSave: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text(String(localized: "onboarding.callsign.custom.title", comment: "Custom callsign sheet title"))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.top, 24)

                TextField(
                    String(localized: "onboarding.callsign.custom.placeholder", comment: "Custom callsign placeholder"),
                    text: $value
                )
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "#FFFC00"))
                .padding(.horizontal, 18)
                .frame(height: 64)
                .background(Color(white: 0.12))
                .cornerRadius(14)
                .padding(.horizontal, 24)
                .focused($focused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .onChange(of: value) { newValue in
                    value = newValue.uppercased()
                }

                Spacer()

                Button {
                    onSave()
                } label: {
                    Text(String(localized: "onboarding.callsign.custom.save", comment: "Save callsign"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .background(Color(hex: "#FFFC00"))
                        .cornerRadius(16)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .onAppear { focused = true }
        }
    }
}

// MARK: - Ready to fly view

private struct ReadyToFlyView: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 120, weight: .light))
                    .foregroundColor(Color(hex: "#00FF66"))

                Text(String(localized: "onboarding.ready.title", comment: "Ready title"))
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)

                Text(String(localized: "onboarding.ready.subtitle", comment: "Ready subtitle"))
                    .font(.system(size: 18))
                    .foregroundColor(Color(hex: "#AAAAAA"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
    }
}

// MARK: - Team color swatch

private struct TeamColorSwatch: View {
    let color: OnboardingTeamColor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(color.paletteColor)
                    .frame(width: 60, height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(selected ? Color.white : Color(white: 0.2), lineWidth: selected ? 3 : 1)
                    )
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(color.contrastForeground)
                }
            }
        }
        .accessibilityLabel(color.localizedName)
        .accessibilityIdentifier("onboarding.team.color.\(color.id)")
    }
}

// MARK: - Flexible chip group (iOS 15-safe)
//
// Apple's `Layout` protocol only landed in iOS 16; we run on 15+. So we
// fall back to a simple LazyVGrid with adaptive columns. It's not as
// pretty as a true flow layout, but it stays compatible and the rows
// look fine at the chip widths we ship.

private struct ChipGroup: View {
    let items: [(String, String)]
    @Binding var selectedID: String

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: .infinity), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.0) { id, label in
                Button {
                    selectedID = id
                } label: {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(selectedID == id ? .black : .white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(selectedID == id ? Color(hex: "#FFFC00") : Color(white: 0.12))
                        .cornerRadius(22)
                }
                .accessibilityIdentifier("onboarding.team.role.\(id)")
            }
        }
    }
}

// MARK: - Team color enum (onboarding-local)
//
// We deliberately don't reuse the existing `TeamColor` in
// Features/Teams/Models/TeamModels.swift because that one only ships the
// 8 ATAK base colors. Onboarding presents the full 14-swatch ATAK palette
// (which matches what the Android client persists) and uses the
// localized name for display.

enum OnboardingTeamColor: String, CaseIterable, Identifiable {
    case white, yellow, orange, magenta, red, maroon, purple, darkBlue
    case blue, cyan, teal, green, darkGreen, brown

    var id: String {
        switch self {
        case .white: return "White"
        case .yellow: return "Yellow"
        case .orange: return "Orange"
        case .magenta: return "Magenta"
        case .red: return "Red"
        case .maroon: return "Maroon"
        case .purple: return "Purple"
        case .darkBlue: return "Dark Blue"
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .teal: return "Teal"
        case .green: return "Green"
        case .darkGreen: return "Dark Green"
        case .brown: return "Brown"
        }
    }

    var localizationKey: String {
        switch self {
        case .white: return "onboarding.team.color.white"
        case .yellow: return "onboarding.team.color.yellow"
        case .orange: return "onboarding.team.color.orange"
        case .magenta: return "onboarding.team.color.magenta"
        case .red: return "onboarding.team.color.red"
        case .maroon: return "onboarding.team.color.maroon"
        case .purple: return "onboarding.team.color.purple"
        case .darkBlue: return "onboarding.team.color.darkBlue"
        case .blue: return "onboarding.team.color.blue"
        case .cyan: return "onboarding.team.color.cyan"
        case .teal: return "onboarding.team.color.teal"
        case .green: return "onboarding.team.color.green"
        case .darkGreen: return "onboarding.team.color.darkGreen"
        case .brown: return "onboarding.team.color.brown"
        }
    }

    var localizedName: String {
        NSLocalizedString(localizationKey, comment: "Team color name")
    }

    var paletteColor: Color {
        switch self {
        case .white: return .white
        case .yellow: return Color(hex: "#FFFC00")
        case .orange: return Color(hex: "#FF8C00")
        case .magenta: return Color(hex: "#FF00FF")
        case .red: return Color(hex: "#FF3B30")
        case .maroon: return Color(hex: "#800000")
        case .purple: return Color(hex: "#9B30FF")
        case .darkBlue: return Color(hex: "#0033A0")
        case .blue: return Color(hex: "#0070FF")
        case .cyan: return Color(hex: "#00E5FF")
        case .teal: return Color(hex: "#008080")
        case .green: return Color(hex: "#00FF00")
        case .darkGreen: return Color(hex: "#006400")
        case .brown: return Color(hex: "#8B4513")
        }
    }

    var contrastForeground: Color {
        switch self {
        case .white, .yellow, .cyan, .green: return .black
        default: return .white
        }
    }
}

// MARK: - Team role enum (onboarding-local)
//
// The existing `TeamRole` in TeamModels.swift only has lead/member/observer.
// Onboarding offers the full 10-role ATAK list, so we keep this scoped
// to the onboarding flow and persist the canonical id string to
// @AppStorage("userRole") / userPosition.

enum OnboardingTeamRole: String, CaseIterable {
    case member, lead, hq, sniper, medic, fo, rto, k9, driver, gunner

    var id: String {
        switch self {
        case .member: return "Team Member"
        case .lead: return "Team Lead"
        case .hq: return "HQ"
        case .sniper: return "Sniper"
        case .medic: return "Medic"
        case .fo: return "Forward Observer"
        case .rto: return "RTO"
        case .k9: return "K9"
        case .driver: return "Driver"
        case .gunner: return "Gunner"
        }
    }

    init?(id: String) {
        guard let match = OnboardingTeamRole.allCases.first(where: { $0.id == id }) else { return nil }
        self = match
    }

    var localizationKey: String {
        switch self {
        case .member: return "onboarding.team.role.member"
        case .lead: return "onboarding.team.role.lead"
        case .hq: return "onboarding.team.role.hq"
        case .sniper: return "onboarding.team.role.sniper"
        case .medic: return "onboarding.team.role.medic"
        case .fo: return "onboarding.team.role.fo"
        case .rto: return "onboarding.team.role.rto"
        case .k9: return "onboarding.team.role.k9"
        case .driver: return "onboarding.team.role.driver"
        case .gunner: return "onboarding.team.role.gunner"
        }
    }

    var localizedName: String {
        NSLocalizedString(localizationKey, comment: "Team role name")
    }
}

// MARK: - Permissions coordinator

private final class PermissionsCoordinator: NSObject, ObservableObject, CLLocationManagerDelegate, CBCentralManagerDelegate {
    @Published var locationGranted = false
    @Published var bluetoothGranted = false
    @Published var notificationsGranted = false

    private var locationManager: CLLocationManager?
    private var bluetoothManager: CBCentralManager?
    private var locationCompletion: (() -> Void)?
    private var bluetoothCompletion: (() -> Void)?

    override init() {
        super.init()
        // Reflect already-granted state on appearance.
        if let lm = CLLocationManager() as CLLocationManager? {
            switch lm.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: locationGranted = true
            default: break
            }
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationsGranted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            }
        }
    }

    func requestLocation(completion: @escaping () -> Void) {
        if locationGranted { completion(); return }
        locationCompletion = completion
        let lm = CLLocationManager()
        lm.delegate = self
        locationManager = lm
        lm.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                self.locationGranted = true
            default:
                break
            }
            if manager.authorizationStatus != .notDetermined {
                self.locationCompletion?()
                self.locationCompletion = nil
            }
        }
    }

    func requestBluetooth(completion: @escaping () -> Void) {
        if bluetoothGranted { completion(); return }
        bluetoothCompletion = completion
        // Instantiating CBCentralManager triggers the BT permission prompt
        // on first run; subsequent runs surface the already-granted state.
        bluetoothManager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch central.state {
            case .poweredOn, .poweredOff, .resetting, .unsupported, .unknown:
                // Anything other than .unauthorized counts as user-acknowledged.
                if central.state != .unauthorized {
                    self.bluetoothGranted = true
                }
            case .unauthorized:
                self.bluetoothGranted = false
            @unknown default:
                break
            }
            self.bluetoothCompletion?()
            self.bluetoothCompletion = nil
        }
    }

    func requestNotifications(completion: @escaping () -> Void) {
        if notificationsGranted { completion(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.notificationsGranted = granted
                completion()
            }
        }
    }
}

// MARK: - Demo server connector

private enum DemoServerConnector {
    static func connect() {
        guard let url = Bundle.main.url(forResource: "demo-package", withExtension: "zip") else {
            print("⚠️ DemoServerConnector: demo-package.zip not bundled in Resources/. See BUILD_FROM_SOURCE.md.")
            UserDefaults.standard.set("tak.engindearing.soy", forKey: "lastDemoServerHost")
            UserDefaults.standard.set(8089, forKey: "lastDemoServerPort")
            return
        }
        Task { @MainActor in
            do {
                let manager = DataPackageManager()
                let result = try await manager.importPackage(from: url)
                print("✅ Demo package imported: \(result)")
                UserDefaults.standard.set("tak.engindearing.soy", forKey: "lastDemoServerHost")
                UserDefaults.standard.set(8089, forKey: "lastDemoServerPort")
            } catch {
                print("⚠️ Demo import failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Onboarding Manager

class OnboardingManager: ObservableObject {
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
        }
    }

    init() {
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    func resetOnboarding() {
        hasCompletedOnboarding = false
    }
}

// MARK: - Preview

#if DEBUG
struct FirstTimeOnboarding_Previews: PreviewProvider {
    static var previews: some View {
        FirstTimeOnboarding()
            .preferredColorScheme(.dark)
    }
}
#endif
