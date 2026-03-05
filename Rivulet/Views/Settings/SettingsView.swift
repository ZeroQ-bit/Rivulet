//
//  SettingsView.swift
//  Rivulet
//
//  Main settings screen for tvOS — Apple TV-style split layout
//

import SwiftUI

// MARK: - Settings Page

enum SettingsPage: Hashable, CaseIterable {
    case root
    case appearance, playback, liveTV, servers, about
    case plex, iptv, libraries, cache, userProfiles

    var title: String {
        switch self {
        case .root: return "Settings"
        case .appearance: return "Appearance"
        case .playback: return "Playback"
        case .liveTV: return "Live TV"
        case .servers: return "Servers"
        case .about: return "About"
        case .plex: return "Plex Server"
        case .iptv: return "Live TV Sources"
        case .libraries: return "Sidebar Libraries"
        case .cache: return "Cache & Storage"
        case .userProfiles: return "User Profiles"
        }
    }
}

// MARK: - Autoplay Countdown

enum AutoplayCountdown: Int, CaseIterable, CustomStringConvertible {
    case off = 0
    case fiveSeconds = 5
    case tenSeconds = 10
    case twentySeconds = 20

    var description: String {
        switch self {
        case .off: return "Off"
        case .fiveSeconds: return "5 seconds"
        case .tenSeconds: return "10 seconds"
        case .twentySeconds: return "20 seconds"
        }
    }
}

// Note: DisplaySize enum is now in Services/UIScale.swift for global access

// MARK: - Language Option

enum LanguageOption: String, CaseIterable, CustomStringConvertible {
    case arabic = "ara"
    case chinese = "zho"
    case czech = "ces"
    case danish = "dan"
    case dutch = "nld"
    case english = "eng"
    case finnish = "fin"
    case french = "fra"
    case german = "deu"
    case greek = "ell"
    case hebrew = "heb"
    case hindi = "hin"
    case hungarian = "hun"
    case indonesian = "ind"
    case italian = "ita"
    case japanese = "jpn"
    case korean = "kor"
    case norwegian = "nor"
    case polish = "pol"
    case portuguese = "por"
    case romanian = "ron"
    case russian = "rus"
    case spanish = "spa"
    case swedish = "swe"
    case thai = "tha"
    case turkish = "tur"
    case ukrainian = "ukr"
    case vietnamese = "vie"

    var description: String {
        switch self {
        case .arabic: return "Arabic"
        case .chinese: return "Chinese"
        case .czech: return "Czech"
        case .danish: return "Danish"
        case .dutch: return "Dutch"
        case .english: return "English"
        case .finnish: return "Finnish"
        case .french: return "French"
        case .german: return "German"
        case .greek: return "Greek"
        case .hebrew: return "Hebrew"
        case .hindi: return "Hindi"
        case .hungarian: return "Hungarian"
        case .indonesian: return "Indonesian"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .norwegian: return "Norwegian"
        case .polish: return "Polish"
        case .portuguese: return "Portuguese"
        case .romanian: return "Romanian"
        case .russian: return "Russian"
        case .spanish: return "Spanish"
        case .swedish: return "Swedish"
        case .thai: return "Thai"
        case .turkish: return "Turkish"
        case .ukrainian: return "Ukrainian"
        case .vietnamese: return "Vietnamese"
        }
    }

    /// Initialize from a language code (handles various formats)
    init(languageCode: String?) {
        guard let code = languageCode?.lowercased() else {
            self = .english
            return
        }
        switch code {
        case "ara", "ar", "arabic": self = .arabic
        case "zho", "zh", "chi", "chinese": self = .chinese
        case "ces", "cs", "cze", "czech": self = .czech
        case "dan", "da", "danish": self = .danish
        case "nld", "nl", "dut", "dutch": self = .dutch
        case "eng", "en", "english": self = .english
        case "fin", "fi", "finnish": self = .finnish
        case "fra", "fr", "fre", "french": self = .french
        case "deu", "de", "ger", "german": self = .german
        case "ell", "el", "gre", "greek": self = .greek
        case "heb", "he", "hebrew": self = .hebrew
        case "hin", "hi", "hindi": self = .hindi
        case "hun", "hu", "hungarian": self = .hungarian
        case "ind", "id", "indonesian": self = .indonesian
        case "ita", "it", "italian": self = .italian
        case "jpn", "ja", "japanese": self = .japanese
        case "kor", "ko", "korean": self = .korean
        case "nor", "no", "nb", "nn", "norwegian": self = .norwegian
        case "pol", "pl", "polish": self = .polish
        case "por", "pt", "portuguese": self = .portuguese
        case "ron", "ro", "rum", "romanian": self = .romanian
        case "rus", "ru", "russian": self = .russian
        case "spa", "es", "spanish": self = .spanish
        case "swe", "sv", "swedish": self = .swedish
        case "tha", "th", "thai": self = .thai
        case "tur", "tr", "turkish": self = .turkish
        case "ukr", "uk", "ukrainian": self = .ukrainian
        case "vie", "vi", "vietnamese": self = .vietnamese
        default: self = .english
        }
    }
}

// MARK: - Subtitle Option (includes Off)

enum SubtitleOption: Hashable, CaseIterable, CustomStringConvertible {
    case off
    case language(LanguageOption)

    static var allCases: [SubtitleOption] {
        [.off] + LanguageOption.allCases.map { .language($0) }
    }

    var description: String {
        switch self {
        case .off: return "Off"
        case .language(let lang): return lang.description
        }
    }

    var isEnabled: Bool {
        if case .off = self { return false }
        return true
    }

    var languageCode: String? {
        if case .language(let lang) = self { return lang.rawValue }
        return nil
    }

    /// Initialize from subtitle preference
    init(enabled: Bool, languageCode: String?) {
        if !enabled {
            self = .off
        } else {
            self = .language(LanguageOption(languageCode: languageCode))
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    // Navigation
    @State private var navigationStack: [SettingsPage] = [.root]
    @State private var isForward = true

    private var currentPage: SettingsPage {
        navigationStack.last ?? .root
    }
    @State private var focusedSettingId: String?
    @State private var focusTrigger = 0
    @State private var showChangelog = false

    // AppStorage
    @AppStorage("showHomeHero") private var showHomeHero = false
    @AppStorage("showLibraryHero") private var showLibraryHero = false
    @AppStorage("showLibraryRecommendations") private var showLibraryRecommendations = true
    @AppStorage("showLibraryRecentRows") private var showLibraryRecentRows = true
    @AppStorage("enablePersonalizedRecommendations") private var enablePersonalizedRecommendations = false
    @AppStorage("liveTVLayout") private var liveTVLayoutRaw = LiveTVLayout.guide.rawValue
    @AppStorage("confirmExitMultiview") private var confirmExitMultiview = true
    @AppStorage("allowFourStreams") private var allowFourStreams = false
    @AppStorage("combineLiveTVSources") private var combineLiveTVSources = true
    @AppStorage("liveTVAboveLibraries") private var liveTVAboveLibraries = false
    @AppStorage("classicTVMode") private var classicTVMode = false
    @AppStorage("showSkipButton") private var showSkipButton = true
    @AppStorage("autoSkipIntro") private var autoSkipIntro = false
    @AppStorage("autoSkipCredits") private var autoSkipCredits = false
    @AppStorage("autoSkipAds") private var autoSkipAds = false
    @AppStorage("highQualityScaling") private var highQualityScaling = true
    @AppStorage("autoplayCountdown") private var autoplayCountdownRaw = AutoplayCountdown.fiveSeconds.rawValue
    @AppStorage("showMarkersOnScrubber") private var showMarkersOnScrubber = true
    @AppStorage("useAVPlayerForDolbyVision") private var useAVPlayerForDolbyVision = true
    @AppStorage("useAVPlayerForAllVideos") private var useAVPlayerForAllVideos = false
    @AppStorage("useRivuletPlayer") private var useRivuletPlayer = true
    @AppStorage("displaySize") private var displaySizeRaw = DisplaySize.normal.rawValue


    // Environment
    @Environment(\.focusScopeManager) private var focusScopeManager
    @Environment(\.nestedNavigationState) private var nestedNavState

    // Audio/Subtitle preference state
    @State private var audioLanguage: LanguageOption = LanguageOption(languageCode: AudioPreferenceManager.current.languageCode)
    @State private var subtitleOption: SubtitleOption = SubtitleOption(
        enabled: SubtitlePreferenceManager.current.enabled,
        languageCode: SubtitlePreferenceManager.current.languageCode
    )

    // MARK: - Bindings

    private var audioLanguageBinding: Binding<LanguageOption> {
        Binding(
            get: { audioLanguage },
            set: { newValue in
                audioLanguage = newValue
                AudioPreferenceManager.current = AudioPreference(languageCode: newValue.rawValue)
            }
        )
    }

    private var subtitleOptionBinding: Binding<SubtitleOption> {
        Binding(
            get: { subtitleOption },
            set: { newValue in
                subtitleOption = newValue
                var pref = SubtitlePreferenceManager.current
                pref.enabled = newValue.isEnabled
                if let code = newValue.languageCode {
                    pref.languageCode = code
                }
                SubtitlePreferenceManager.current = pref
            }
        )
    }

    private var liveTVLayout: Binding<LiveTVLayout> {
        Binding(
            get: { LiveTVLayout(rawValue: liveTVLayoutRaw) ?? .channels },
            set: { liveTVLayoutRaw = $0.rawValue }
        )
    }

    private var autoplayCountdown: Binding<AutoplayCountdown> {
        Binding(
            get: { AutoplayCountdown(rawValue: autoplayCountdownRaw) ?? .fiveSeconds },
            set: { autoplayCountdownRaw = $0.rawValue }
        )
    }

    private var displaySize: Binding<DisplaySize> {
        Binding(
            get: { DisplaySize(rawValue: displaySizeRaw) ?? .normal },
            set: { displaySizeRaw = $0.rawValue }
        )
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Page title
                Text(currentPage.title)
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 50)
                    .padding(.bottom, 24)
                    .animation(.easeInOut(duration: 0.2), value: currentPage)

                // Split layout
                HStack(alignment: .top, spacing: 0) {
                    // Left info panel
                    leftPanel
                        .frame(width: geo.size.width * 0.55)

                    // Right settings list
                    ZStack {
                        ScrollView(.vertical, showsIndicators: false) {
                            pageContent(for: currentPage)
                                .padding(.horizontal, 40)
                                .padding(.bottom, 80)
                                .padding(.top, 8)
                        }
                        .id(currentPage)
                        .transition(.asymmetric(
                            insertion: .move(edge: isForward ? .trailing : .leading),
                            removal: .move(edge: isForward ? .leading : .trailing)
                        ))
                    }
                    .clipped()
                    .frame(width: geo.size.width * 0.45)
                    .animation(.easeInOut(duration: 0.3), value: currentPage)
                }
            }
        }
        .background(.clear)
        .fullScreenCover(isPresented: $showChangelog) {
            WhatsNewView(isPresented: $showChangelog, version: appVersion)
        }
        .onAppear {
            DispatchQueue.main.async {
                focusTrigger += 1
            }
        }
        .onChange(of: focusScopeManager.restoreTrigger) { _, _ in
            focusTrigger += 1
        }
        .onChange(of: navigationStack) { _, newStack in
            let isNested = newStack.count > 1
            nestedNavState.isNested = isNested
            if isNested {
                nestedNavState.goBackAction = { [weak nestedNavState] in
                    goBack()
                    if navigationStack.count <= 1 {
                        nestedNavState?.isNested = false
                    }
                }
            } else {
                nestedNavState.goBackAction = nil
            }
        }
        #if os(tvOS)
        .onExitCommand {
            if currentPage != .root {
                goBack()
            }
        }
        #endif
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(spacing: 28) {
            Spacer()

            // Decorative icon
            let descriptor = focusedSettingId.flatMap { SettingsDescriptorStore.descriptor(for: $0) }
            let pageInfo = SettingsDescriptorStore.pageInfo(for: currentPage)
            let iconName = descriptor?.icon ?? pageInfo.icon
            let iconColor = descriptor?.iconColor ?? pageInfo.color

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 140, height: 140)

                Image(systemName: iconName)
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            .animation(.easeInOut(duration: 0.25), value: focusedSettingId)

            // Description text
            if let desc = descriptor?.description {
                Text(desc)
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 420)
                    .transition(.opacity)
                    .id(focusedSettingId)
            }

            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: focusedSettingId)
    }

    // MARK: - Page Content

    @ViewBuilder
    private func pageContent(for page: SettingsPage) -> some View {
        switch page {
        case .root:
            rootSettingsList
        case .appearance:
            appearanceSettings
        case .playback:
            playbackSettings
        case .liveTV:
            liveTVSettings
        case .servers:
            serversSettings
        case .about:
            aboutSettings
        case .plex:
            PlexSettingsView(focusedSettingId: $focusedSettingId)
        case .iptv:
            IPTVSettingsView(focusedSettingId: $focusedSettingId)
        case .libraries:
            LibrarySettingsView(focusedSettingId: $focusedSettingId)
        case .cache:
            CacheSettingsView(focusedSettingId: $focusedSettingId)
        case .userProfiles:
            UserProfileSettingsView(focusedSettingId: $focusedSettingId)
        }
    }

    // MARK: - Root Settings List

    private var rootSettingsList: some View {
        VStack(spacing: 8) {
            SettingsRow(
                title: "Appearance",
                subtitle: "",
                action: { navigate(to: .appearance) },
                focusTrigger: focusTrigger,
                onFocusChange: { if $0 { focusedSettingId = "cat_appearance" } }
            )

            SettingsRow(
                title: "Playback",
                subtitle: "",
                action: { navigate(to: .playback) },
                onFocusChange: { if $0 { focusedSettingId = "cat_playback" } }
            )

            SettingsRow(
                title: "Live TV",
                subtitle: "",
                action: { navigate(to: .liveTV) },
                onFocusChange: { if $0 { focusedSettingId = "cat_liveTV" } }
            )

            SettingsRow(
                title: "Servers",
                subtitle: "",
                action: { navigate(to: .servers) },
                onFocusChange: { if $0 { focusedSettingId = "cat_servers" } }
            )

            SettingsRow(
                title: "Cache & Storage",
                subtitle: "",
                action: { navigate(to: .cache) },
                onFocusChange: { if $0 { focusedSettingId = "cache" } }
            )

            SettingsRow(
                title: "About",
                subtitle: "",
                action: { navigate(to: .about) },
                onFocusChange: { if $0 { focusedSettingId = "cat_about" } }
            )
        }
    }

    // MARK: - Appearance Settings

    private var appearanceSettings: some View {
        VStack(spacing: 8) {
            SettingsRow(
                title: "Sidebar Libraries",
                subtitle: "",
                action: { navigate(to: .libraries) },
                focusTrigger: focusTrigger,
                onFocusChange: { if $0 { focusedSettingId = "libraries" } }
            )

            SettingsListPickerRow(
                title: "Display Size",
                subtitle: "",
                selection: displaySize,
                options: DisplaySize.allCases,
                onFocusChange: { if $0 { focusedSettingId = "displaySize" } }
            )

            SettingsToggleRow(
                title: "Home Hero",
                subtitle: "",
                isOn: $showHomeHero,
                onFocusChange: { if $0 { focusedSettingId = "homeHero" } }
            )

            SettingsToggleRow(
                title: "Library Hero",
                subtitle: "",
                isOn: $showLibraryHero,
                onFocusChange: { if $0 { focusedSettingId = "libraryHero" } }
            )

            SettingsToggleRow(
                title: "Discovery Rows",
                subtitle: "",
                isOn: $showLibraryRecommendations,
                onFocusChange: { if $0 { focusedSettingId = "discoveryRows" } }
            )

            SettingsToggleRow(
                title: "Recent Rows",
                subtitle: "",
                isOn: $showLibraryRecentRows,
                onFocusChange: { if $0 { focusedSettingId = "recentRows" } }
            )

            SettingsToggleRow(
                title: "Personalized Recommendations",
                subtitle: "",
                isOn: $enablePersonalizedRecommendations,
                onFocusChange: { if $0 { focusedSettingId = "personalizedRecs" } }
            )
        }
    }

    // MARK: - Playback Settings

    private var playbackSettings: some View {
        VStack(spacing: 8) {
            SettingsListPickerRow(
                title: "Audio Language",
                subtitle: "",
                selection: audioLanguageBinding,
                options: LanguageOption.allCases,
                onFocusChange: { if $0 { focusedSettingId = "audioLanguage" } }
            )

            SettingsListPickerRow(
                title: "Subtitles",
                subtitle: "",
                selection: subtitleOptionBinding,
                options: SubtitleOption.allCases,
                onFocusChange: { if $0 { focusedSettingId = "subtitles" } }
            )

            SettingsToggleRow(
                title: "Show Skip Button",
                subtitle: "",
                isOn: $showSkipButton,
                onFocusChange: { if $0 { focusedSettingId = "showSkipButton" } }
            )

            SettingsToggleRow(
                title: "Show Markers on Scrubber",
                subtitle: "",
                isOn: $showMarkersOnScrubber,
                onFocusChange: { if $0 { focusedSettingId = "showMarkers" } }
            )

            SettingsToggleRow(
                title: "Auto-Skip Intro",
                subtitle: "",
                isOn: $autoSkipIntro,
                onFocusChange: { if $0 { focusedSettingId = "autoSkipIntro" } }
            )

            SettingsToggleRow(
                title: "Auto-Skip Credits",
                subtitle: "",
                isOn: $autoSkipCredits,
                onFocusChange: { if $0 { focusedSettingId = "autoSkipCredits" } }
            )

            SettingsToggleRow(
                title: "Auto-Skip Ads",
                subtitle: "",
                isOn: $autoSkipAds,
                onFocusChange: { if $0 { focusedSettingId = "autoSkipAds" } }
            )

            SettingsPickerRow(
                title: "Autoplay Countdown",
                subtitle: "",
                selection: autoplayCountdown,
                options: AutoplayCountdown.allCases,
                onFocusChange: { if $0 { focusedSettingId = "autoplayCountdown" } }
            )

            SettingsToggleRow(
                title: "High Quality Scaling",
                subtitle: "",
                isOn: $highQualityScaling,
                helpTitle: "High Quality Scaling",
                onFocusChange: { if $0 { focusedSettingId = "highQualityScaling" } }
            ) {
                highQualityScalingHelpContent
            }

            SettingsToggleRow(
                title: "AVPlayer for Dolby Vision",
                subtitle: "",
                isOn: $useAVPlayerForDolbyVision,
                helpTitle: "AVPlayer for Dolby Vision",
                onFocusChange: { if $0 { focusedSettingId = "avPlayerDV" } }
            ) {
                avPlayerDVHelpContent
            }

            SettingsToggleRow(
                title: "AVPlayer for All Videos",
                subtitle: "",
                isOn: $useAVPlayerForAllVideos,
                helpTitle: "AVPlayer for All Videos",
                onFocusChange: { if $0 { focusedSettingId = "avPlayerAll" } }
            ) {
                avPlayerAllHelpContent
            }

            SettingsToggleRow(
                title: "Rivulet Player",
                subtitle: "",
                isOn: $useRivuletPlayer,
                helpTitle: "Rivulet Player",
                onFocusChange: { if $0 { focusedSettingId = "rivuletPlayer" } }
            ) {
                rivuletPlayerHelpContent
            }
        }
    }

    // MARK: - Live TV Settings

    private var liveTVSettings: some View {
        VStack(spacing: 8) {
            SettingsRow(
                title: "Live TV Sources",
                subtitle: "",
                action: { navigate(to: .iptv) },
                focusTrigger: focusTrigger,
                onFocusChange: { if $0 { focusedSettingId = "liveTVSources" } }
            )

            SettingsToggleRow(
                title: "Live TV Above Libraries",
                subtitle: "",
                isOn: $liveTVAboveLibraries,
                onFocusChange: { if $0 { focusedSettingId = "liveTVAboveLibraries" } }
            )

            SettingsToggleRow(
                title: "Classic TV Mode",
                subtitle: "",
                isOn: $classicTVMode,
                onFocusChange: { if $0 { focusedSettingId = "classicTVMode" } }
            )

            SettingsToggleRow(
                title: "Combine Sources",
                subtitle: "",
                isOn: $combineLiveTVSources,
                onFocusChange: { if $0 { focusedSettingId = "combineSources" } }
            )

            SettingsPickerRow(
                title: "Default Layout",
                subtitle: "",
                selection: liveTVLayout,
                options: LiveTVLayout.allCases,
                onFocusChange: { if $0 { focusedSettingId = "defaultLayout" } }
            )

            SettingsToggleRow(
                title: "Confirm Exit Multiview",
                subtitle: "",
                isOn: $confirmExitMultiview,
                onFocusChange: { if $0 { focusedSettingId = "confirmExitMultiview" } }
            )

            SettingsToggleRow(
                title: "Allow 3 or 4 Streams",
                subtitle: "",
                isOn: $allowFourStreams,
                onFocusChange: { if $0 { focusedSettingId = "allowFourStreams" } }
            )
        }
    }

    // MARK: - Servers Settings

    private var serversSettings: some View {
        VStack(spacing: 8) {
            SettingsRow(
                title: "Plex Server",
                subtitle: "",
                action: { navigate(to: .plex) },
                focusTrigger: focusTrigger,
                onFocusChange: { if $0 { focusedSettingId = "plexServer" } }
            )

            SettingsRow(
                title: "User Profiles",
                subtitle: "",
                action: { navigate(to: .userProfiles) },
                onFocusChange: { if $0 { focusedSettingId = "userProfiles" } }
            )
        }
    }

    // MARK: - About Settings

    private var aboutSettings: some View {
        VStack(spacing: 8) {
            SettingsInfoRow(title: "App", value: "Rivulet")
            SettingsInfoRow(title: "Version", value: appVersion)

            SettingsRow(
                title: "Changelog",
                subtitle: "",
                action: { showChangelog = true },
                onFocusChange: { if $0 { focusedSettingId = "changelog" } }
            )
        }
    }

    // MARK: - Navigation

    private func navigate(to page: SettingsPage) {
        focusedSettingId = nil
        isForward = true
        navigationStack.append(page)
    }

    private func goBack() {
        guard navigationStack.count > 1 else { return }
        focusedSettingId = nil
        isForward = false
        navigationStack.removeLast()
    }

    // MARK: - Help Content

    @ViewBuilder
    private var highQualityScalingHelpContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            HelpSection(
                title: "What This Does",
                content: "Enables advanced upscaling algorithms in MPV to make lower resolution content (720p, 1080p) look sharper on your 4K display."
            )

            HelpSection(
                title: "How It Works",
                content: "Uses the EWA Lanczos (jinc) scaling algorithm with anti-ringing. This produces sharper edges and finer detail than the default bilinear scaling, especially noticeable on text and fine patterns."
            )

            HelpSection(
                title: "When to Use",
                content: "Enable this if you watch a lot of 1080p or 720p content and want the best possible picture quality. Most beneficial on larger TVs where upscaling artifacts are more visible."
            )

            HelpSection(
                title: "Performance",
                content: "Uses slightly more GPU power on your Apple TV. On Apple TV 4K this is negligible, but if you experience stuttering on complex scenes, try disabling this option."
            )
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var avPlayerDVHelpContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            HelpSection(
                title: "What This Does",
                content: "Uses Apple's native video player (AVPlayer) for Dolby Vision content instead of MPV. This enables true Dolby Vision playback with proper TV mode switching."
            )

            HelpFormatTable(
                title: "Supported Formats (MP4)",
                rows: [
                    ("HLG", true),
                    ("HDR10", true),
                    ("HDR10+", true),
                    ("Dolby Vision Profile 5", true),
                    ("Dolby Vision Profile 8.1", true),
                    ("Dolby Vision Profile 8.4", true),
                    ("Dolby Vision Profile 7", false),
                    ("Dolby Vision Profile 8 (other)", false)
                ]
            )

            HelpFormatTable(
                title: "Supported Formats (MKV)",
                rows: [
                    ("HLG", true),
                    ("HDR10", true),
                    ("HDR10+", true),
                    ("Dolby Vision Profile 5", true),
                    ("Dolby Vision Profile 7/8", false)
                ]
            )

            HelpSection(
                title: "Why Use This?",
                content: "AVPlayer provides native Dolby Vision and HDR10+ support that MPV cannot. Your TV will properly switch to DV/HDR mode for these formats."
            )

            HelpSection(
                title: "Limitations",
                content: "Profile 7 and most Profile 8 variants require MPV (they'll fall back automatically). MKV files with DV Profile 7/8 cannot be remuxed by Plex server yet. DTS and TrueHD audio will be transcoded to AAC."
            )
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var avPlayerAllHelpContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            HelpSection(
                title: "What This Does",
                content: "Uses Apple's native video player (AVPlayer) for ALL content, not just HDR/Dolby Vision. Your Plex server will remux incompatible containers (like MKV) to MP4."
            )

            HelpSection(
                title: "Benefits",
                content: "Native Apple TV video decoding with proper display mode switching for HDR content. Lower power consumption than software decoding."
            )

            HelpSection(
                title: "Trade-offs",
                content: "MKV files will be remuxed (repackaged) on the server. This uses minimal CPU but requires the server to process the stream. Some advanced subtitle formats may not work. DTS/TrueHD audio will be transcoded."
            )

            HelpSection(
                title: "When to Use",
                content: "Enable this if you prefer the native Apple experience and don't mind your server doing light remuxing. Most MP4 files will still direct play without any server processing."
            )
        }
        .padding(.vertical, 8)
    }

    private var rivuletPlayerHelpContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            HelpSection(
                title: "What This Does",
                content: "Uses a new native player built on AVSampleBufferDisplayLayer and VideoToolbox. Plays files directly from your server using FFmpeg for container demuxing — no remuxing needed for MKV or other formats."
            )

            HelpSection(
                title: "Benefits",
                content: "True direct play for all containers (MKV, MP4, AVI). Full Dolby Vision and HDR support. No server processing for compatible audio. Smaller app size (no MPV/Vulkan)."
            )

            HelpSection(
                title: "Trade-offs",
                content: "Experimental — may have playback issues with some content. DTS and TrueHD audio still require server-side transcode (same as all official Plex clients)."
            )

            HelpSection(
                title: "When to Use",
                content: "Try this if you want true direct play without server remuxing. Report any issues so we can improve it. Disable this setting to go back to the standard player."
            )
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    SettingsView()
}
