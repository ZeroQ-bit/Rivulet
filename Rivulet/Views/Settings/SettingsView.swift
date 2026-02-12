//
//  SettingsView.swift
//  Rivulet
//
//  Main settings screen for tvOS
//

import SwiftUI

// MARK: - Settings Destination

enum SettingsDestination: Hashable {
    case plex
    case iptv
    case libraries
    case cache
    case userProfiles
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
    @State private var navigationPath = NavigationPath()
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
    @AppStorage("displaySize") private var displaySizeRaw = DisplaySize.normal.rawValue
    @AppStorage("posterDepthEffect") private var posterDepthEffect = true
    @Environment(\.focusScopeManager) private var focusScopeManager
    @Environment(\.nestedNavigationState) private var nestedNavState
    #if os(tvOS)
    @Environment(\.openSidebar) private var openSidebar
    @Environment(\.isSidebarVisible) private var isSidebarVisible
    #endif
    @State private var focusTrigger = 0  // Increment to trigger first row focus
    @State private var showChangelog = false

    // Audio/Subtitle preference state (synced with preference managers)
    @State private var audioLanguage: LanguageOption = LanguageOption(languageCode: AudioPreferenceManager.current.languageCode)
    @State private var subtitleOption: SubtitleOption = SubtitleOption(
        enabled: SubtitlePreferenceManager.current.enabled,
        languageCode: SubtitlePreferenceManager.current.languageCode
    )

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

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 32) {
                    // Header
                    Text("Settings")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 80)
                        .padding(.top, 60)

                    // Settings categories
                    VStack(spacing: 24) {
                        // Appearance section
                        SettingsSection(title: "Appearance") {
                            SettingsRow(
                                icon: "sidebar.squares.left",
                                iconColor: .purple,
                                title: "Sidebar Libraries",
                                subtitle: "Show, hide, and reorder libraries",
                                action: {
                                    navigationPath.append(SettingsDestination.libraries)
                                },
                                focusTrigger: focusTrigger  // First row gets focus
                            )

                            SettingsListPickerRow(
                                icon: "textformat.size",
                                iconColor: .orange,
                                title: "Display Size",
                                subtitle: "Scale all interface elements",
                                selection: displaySize,
                                options: DisplaySize.allCases
                            )

                            SettingsToggleRow(
                                icon: "square.3.layers.3d",
                                iconColor: .blue,
                                title: "Poster Depth Effect",
                                subtitle: "Lifts subject from background when focused",
                                isOn: $posterDepthEffect
                            )

                            SettingsToggleRow(
                                icon: "sparkles.rectangle.stack",
                                iconColor: .indigo,
                                title: "Home Hero",
                                subtitle: "Featured content banner on Home",
                                isOn: $showHomeHero
                            )

                            SettingsToggleRow(
                                icon: "rectangle.stack",
                                iconColor: .teal,
                                title: "Library Hero",
                                subtitle: "Featured content banner in libraries",
                                isOn: $showLibraryHero
                            )

                            SettingsToggleRow(
                                icon: "square.stack.3d.up",
                                iconColor: .cyan,
                                title: "Discovery Rows",
                                subtitle: "Top Rated, Rediscover, and similar",
                                isOn: $showLibraryRecommendations
                            )

                            SettingsToggleRow(
                                icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                                iconColor: .blue,
                                title: "Recent Rows",
                                subtitle: "Recently Added and Recently Released in libraries",
                                isOn: $showLibraryRecentRows
                            )

                            SettingsToggleRow(
                                icon: "person.3",
                                iconColor: .mint,
                                title: "Personalized Recommendations",
                                subtitle: "Use TMDB + watch history to surface unwatched picks",
                                isOn: $enablePersonalizedRecommendations
                            )
                        }

                        // Playback section
                        SettingsSection(title: "Playback") {
                            SettingsListPickerRow(
                                icon: "waveform",
                                iconColor: .cyan,
                                title: "Audio Language",
                                subtitle: "Preferred language for audio tracks",
                                selection: audioLanguageBinding,
                                options: LanguageOption.allCases
                            )

                            SettingsListPickerRow(
                                icon: "captions.bubble",
                                iconColor: .yellow,
                                title: "Subtitles",
                                subtitle: "Preferred language for subtitles",
                                selection: subtitleOptionBinding,
                                options: SubtitleOption.allCases
                            )

                            SettingsToggleRow(
                                icon: "forward.fill",
                                iconColor: .blue,
                                title: "Show Skip Button",
                                subtitle: "Display button to skip intro and credits",
                                isOn: $showSkipButton
                            )

                            SettingsToggleRow(
                                icon: "timeline.selection",
                                iconColor: .yellow,
                                title: "Show Markers on Scrubber",
                                subtitle: "Highlight intro, credits, and ads on the progress bar",
                                isOn: $showMarkersOnScrubber
                            )

                            SettingsToggleRow(
                                icon: "play.circle",
                                iconColor: .green,
                                title: "Auto-Skip Intro",
                                subtitle: "Automatically skip TV show intros",
                                isOn: $autoSkipIntro
                            )

                            SettingsToggleRow(
                                icon: "stop.circle",
                                iconColor: .orange,
                                title: "Auto-Skip Credits",
                                subtitle: "Automatically skip end credits",
                                isOn: $autoSkipCredits
                            )

                            SettingsToggleRow(
                                icon: "forward.frame",
                                iconColor: .red,
                                title: "Auto-Skip Ads",
                                subtitle: "Automatically skip advertisements",
                                isOn: $autoSkipAds
                            )

                            SettingsPickerRow(
                                icon: "forward.end.alt",
                                iconColor: .purple,
                                title: "Autoplay Countdown",
                                subtitle: "Time before next episode plays",
                                selection: autoplayCountdown,
                                options: AutoplayCountdown.allCases
                            )

                            SettingsToggleRow(
                                icon: "sparkles.tv",
                                iconColor: .pink,
                                title: "High Quality Scaling",
                                subtitle: "Sharper upscaling for 720p/1080p content",
                                isOn: $highQualityScaling,
                                helpTitle: "High Quality Scaling"
                            ) {
                                highQualityScalingHelpContent
                            }

                            SettingsToggleRow(
                                icon: "sparkles.tv",
                                iconColor: .purple,
                                title: "Use AVPlayer for Dolby Vision",
                                subtitle: "If Plex can send it, we can play it",
                                isOn: $useAVPlayerForDolbyVision,
                                helpTitle: "AVPlayer for Dolby Vision"
                            ) {
                                avPlayerDVHelpContent
                            }

                            SettingsToggleRow(
                                icon: "play.rectangle",
                                iconColor: .blue,
                                title: "Use AVPlayer for All Videos",
                                subtitle: "If you like remuxing and Direct Stream, here's to you",
                                isOn: $useAVPlayerForAllVideos,
                                helpTitle: "AVPlayer for All Videos"
                            ) {
                                avPlayerAllHelpContent
                            }
                        }

                        // Live TV section
                        SettingsSection(title: "Live TV") {
                            SettingsToggleRow(
                                icon: "arrow.up.arrow.down",
                                iconColor: .cyan,
                                title: "Live TV Above Libraries",
                                subtitle: "Show Live TV section above Media libraries in sidebar",
                                isOn: $liveTVAboveLibraries
                            )

                            SettingsToggleRow(
                                icon: "tv.fill",
                                iconColor: .indigo,
                                title: "Classic TV Mode",
                                subtitle: "Hide player controls for a traditional TV experience",
                                isOn: $classicTVMode
                            )

                            SettingsToggleRow(
                                icon: "square.stack.3d.down.right",
                                iconColor: .purple,
                                title: "Combine Sources",
                                subtitle: "Show all sources in one Channels view, or separate sidebar entries",
                                isOn: $combineLiveTVSources
                            )

                            SettingsPickerRow(
                                icon: "tv",
                                iconColor: .green,
                                title: "Default Layout",
                                subtitle: "Choose channel grid or TV guide view",
                                selection: liveTVLayout,
                                options: LiveTVLayout.allCases
                            )

                            SettingsToggleRow(
                                icon: "rectangle.split.2x2",
                                iconColor: .blue,
                                title: "Confirm Exit Multiview",
                                subtitle: "Ask before closing multiple streams",
                                isOn: $confirmExitMultiview
                            )

                            SettingsToggleRow(
                                icon: "rectangle.split.2x2.fill",
                                iconColor: .orange,
                                title: "Allow 3 or 4 Streams",
                                subtitle: "4 streams may crash the app, but I won't stop you",
                                isOn: $allowFourStreams
                            )
                        }

                        // Storage section
                        SettingsSection(title: "Storage") {
                            SettingsRow(
                                icon: "internaldrive",
                                iconColor: .gray,
                                title: "Cache & Storage",
                                subtitle: "Manage cached images and data"
                            ) {
                                navigationPath.append(SettingsDestination.cache)
                            }
                        }

                        // Servers section
                        SettingsSection(title: "Servers") {
                            SettingsRow(
                                icon: "server.rack",
                                iconColor: .orange,
                                title: "Plex Server",
                                subtitle: "Media library connection"
                            ) {
                                navigationPath.append(SettingsDestination.plex)
                            }

                            SettingsRow(
                                icon: "person.crop.circle",
                                iconColor: .cyan,
                                title: "User Profiles",
                                subtitle: PlexUserProfileManager.shared.selectedUser?.displayName ?? "Default"
                            ) {
                                navigationPath.append(SettingsDestination.userProfiles)
                            }

                            SettingsRow(
                                icon: "tv.and.mediabox",
                                iconColor: .blue,
                                title: "Live TV Sources",
                                subtitle: "Manage channel sources"
                            ) {
                                navigationPath.append(SettingsDestination.iptv)
                            }
                        }

                        // About section
                        SettingsSection(title: "About") {
                            SettingsInfoRow(title: "App", value: "Rivulet")
                            SettingsInfoRow(title: "Version", value: appVersion)

                            SettingsRow(
                                icon: "list.bullet.rectangle",
                                iconColor: .blue,
                                title: "Changelog",
                                subtitle: "See what's new in this version"
                            ) {
                                showChangelog = true
                            }
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.bottom, 80)
                }
            }
            .background(Color.black)
            .fullScreenCover(isPresented: $showChangelog) {
                WhatsNewView(isPresented: $showChangelog, version: appVersion)
            }
            #if os(tvOS)
            .onMoveCommand { direction in
                // Open sidebar when pressing left at the edge
                guard !isSidebarVisible else { return }
                if direction == .left {
                    openSidebar()
                }
            }
            #endif
            .onAppear {
                // Set initial focus when view first appears
                DispatchQueue.main.async {
                    focusTrigger += 1
                }
            }
            .onChange(of: focusScopeManager.restoreTrigger) { _, _ in
                // Trigger first row to claim focus when sidebar closes
                focusTrigger += 1
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .plex:
                    PlexSettingsView()
                case .iptv:
                    IPTVSettingsView()
                case .libraries:
                    LibrarySettingsView()
                case .cache:
                    CacheSettingsView()
                case .userProfiles:
                    UserProfileSettingsView()
                }
            }
        }
        // Tell parent we're in nested navigation when path is not empty
        .onChange(of: navigationPath.count) { _, newCount in
            let isNested = newCount > 0
            nestedNavState.isNested = isNested
            if isNested {
                nestedNavState.goBackAction = { [weak nestedNavState] in
                    if !navigationPath.isEmpty {
                        navigationPath.removeLast()
                    }
                    if navigationPath.isEmpty {
                        nestedNavState?.isNested = false
                    }
                }
            } else {
                nestedNavState.goBackAction = nil
            }
        }
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
}

#Preview {
    SettingsView()
}
