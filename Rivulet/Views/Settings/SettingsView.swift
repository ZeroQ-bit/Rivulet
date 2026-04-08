//
//  SettingsView.swift
//  Rivulet
//
//  Main settings screen for tvOS — Apple TV-style split layout
//

import SwiftUI

// MARK: - Crossfade Option

enum CrossfadeOption: String, CaseIterable, Hashable, CustomStringConvertible {
    case off = "off"
    case threeSeconds = "3s"
    case fiveSeconds = "5s"
    case eightSeconds = "8s"
    case twelveSeconds = "12s"

    var description: String {
        switch self {
        case .off: return "Off"
        case .threeSeconds: return "3s"
        case .fiveSeconds: return "5s"
        case .eightSeconds: return "8s"
        case .twelveSeconds: return "12s"
        }
    }

    var seconds: Int {
        switch self {
        case .off: return 0
        case .threeSeconds: return 3
        case .fiveSeconds: return 5
        case .eightSeconds: return 8
        case .twelveSeconds: return 12
        }
    }
}

// MARK: - Settings Page

enum SettingsPage: Hashable, CaseIterable {
    case root
    case appearance, playback, music, liveTV, servers, about
    case plex, iptv, libraries, cache, userProfiles
    case liveTVSourceDetail
    case addLiveTVSource, addPlexLiveTV, addDispatcharrSource, addM3USource
    case displaySizePicker, audioLanguagePicker, subtitlesPicker, autoplayCountdownPicker

    var title: String {
        switch self {
        case .root: return "Settings"
        case .appearance: return "Appearance"
        case .playback: return "Playback"
        case .music: return "Music"
        case .liveTV: return "Live TV"
        case .servers: return "Servers"
        case .about: return "About"
        case .plex: return "Plex Server"
        case .iptv: return "Live TV Sources"
        case .liveTVSourceDetail: return "Source Details"
        case .addLiveTVSource: return "Add Live TV Source"
        case .addPlexLiveTV: return "Add Plex Live TV"
        case .addDispatcharrSource: return "Add M3U Server"
        case .addM3USource: return "Add M3U Playlist"
        case .libraries: return "Sidebar Libraries"
        case .cache: return "Cache & Storage"
        case .userProfiles: return "User Profiles"
        case .displaySizePicker: return "Display Size"
        case .audioLanguagePicker: return "Audio Language"
        case .subtitlesPicker: return "Subtitles"
        case .autoplayCountdownPicker: return "Autoplay Countdown"
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

// MARK: - Focus State (uses Combine to avoid triggering SwiftUI re-renders on the button list)

import Combine

final class SettingsFocusState {
    var focusedSettingId: String? {
        didSet { publisher.send(focusedSettingId) }
    }
    var focusedSubtext: String? {
        didSet { subtextPublisher.send(focusedSubtext) }
    }
    let publisher = PassthroughSubject<String?, Never>()
    let subtextPublisher = PassthroughSubject<String?, Never>()
}

// MARK: - Settings View

struct SettingsView: View {
    // Navigation
    @State private var navigationStack: [SettingsPage] = [.root]

    // Page transition animation state (driven outside FocusContainedView's
    // UIHostingController because .transition() / .id() don't fire on rootView
    // swaps — see navigate(to:)/goBack() for the two-phase slide).
    @State private var pageOffsetX: CGFloat = 0
    @State private var pageOpacity: Double = 1

    private var currentPage: SettingsPage {
        navigationStack.last ?? .root
    }
    @State private var focusState = SettingsFocusState()
    @State private var focusTrigger = 0
    @State private var showChangelog = false
    @State private var selectedLiveTVSource: LiveTVDataStore.LiveTVSourceInfo?

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
    @AppStorage("autoSkipIntro") private var autoSkipIntro = false
    @AppStorage("autoSkipCredits") private var autoSkipCredits = false
    @AppStorage("autoSkipAds") private var autoSkipAds = false
    @AppStorage("useApplePlayer") private var useApplePlayer = true
    @AppStorage("autoplayCountdown") private var autoplayCountdownRaw = AutoplayCountdown.fiveSeconds.rawValue
    @AppStorage("displaySize") private var displaySizeRaw = DisplaySize.normal.rawValue
    @AppStorage("musicLoudnessNormalization") private var musicLoudnessNormalization = false
    @AppStorage("musicCrossfadeDuration") private var musicCrossfadeDurationRaw = CrossfadeOption.off.rawValue
    @AppStorage("musicShowQualityBadges") private var musicShowQualityBadges = true

    private var crossfadeSelection: Binding<CrossfadeOption> {
        Binding(
            get: { CrossfadeOption(rawValue: musicCrossfadeDurationRaw) ?? .off },
            set: { musicCrossfadeDurationRaw = $0.rawValue }
        )
    }


    // Environment
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

    private var focusedSettingIdBinding: Binding<String?> {
        Binding(
            get: { focusState.focusedSettingId },
            set: { focusState.focusedSettingId = $0 }
        )
    }

    private var focusedSubtextBinding: Binding<String?> {
        Binding(
            get: { focusState.focusedSubtext },
            set: { focusState.focusedSubtext = $0 }
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
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                    .padding(.bottom, 24)
                    .animation(.easeInOut(duration: 0.2), value: currentPage)

                // Split layout
                HStack(alignment: .top, spacing: 0) {
                    // Left info panel (own struct to avoid re-rendering buttons)
                    SettingsLeftPanel(
                        focusState: focusState,
                        currentPage: currentPage
                    )
                    .frame(width: geo.size.width * 0.55)

                    // Right settings list (focus-contained to block left escape to sidebar)
                    //
                    // NOTE: .transition()/.id() do not work *inside* the
                    // FocusContainedView because UIHostingController rebuilds
                    // its rootView tree on each update rather than diffing —
                    // so identity changes never register as insert/remove and
                    // no transition fires. Instead, we animate .offset/.opacity
                    // on the representable from the outside via @State, and do
                    // the content swap mid-animation in navigate()/goBack().
                    FocusContainedView(
                        blockLeftEscape: currentPage != .root,
                        onLeftBlocked: { goBack() }
                    ) {
                        List {
                            pageContent(for: currentPage)
                        }
                        .listStyle(.grouped)
                        .scrollClipDisabled()
                    }
                    .offset(x: pageOffsetX)
                    .opacity(pageOpacity)
                    .frame(width: geo.size.width * 0.45)
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
        .onExitCommand(perform: currentPage != .root ? { goBack() } : nil)
    }

    // MARK: - Left Panel (extracted to isolate re-renders from right panel)

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
        case .music:
            musicSettings
        case .liveTV:
            liveTVSettings
        case .servers:
            serversSettings
        case .about:
            aboutSettings
        case .plex:
            PlexSettingsView(focusedSettingId: focusedSettingIdBinding)
        case .iptv:
            IPTVSettingsView(
                focusedSettingId: focusedSettingIdBinding,
                onNavigateToSource: { source in
                    selectedLiveTVSource = source
                    navigate(to: .liveTVSourceDetail)
                },
                onNavigateToAddSource: {
                    navigate(to: .addLiveTVSource)
                }
            )
        case .liveTVSourceDetail:
            if let source = selectedLiveTVSource {
                LiveTVSourceDetailView(source: source, focusedSettingId: focusedSettingIdBinding) {
                    goBack()
                }
            }
        case .addLiveTVSource:
            AddLiveTVSourcePickerView(
                focusedSettingId: focusedSettingIdBinding,
                onNavigate: { navigate(to: $0) }
            )
        case .addPlexLiveTV:
            AddPlexLiveTVSettingsView(focusedSettingId: focusedSettingIdBinding) {
                navigateBackTo(.iptv)
            }
        case .addDispatcharrSource:
            AddDispatcharrSettingsView(focusedSettingId: focusedSettingIdBinding) {
                navigateBackTo(.iptv)
            }
        case .addM3USource:
            AddM3USettingsView(focusedSettingId: focusedSettingIdBinding) {
                navigateBackTo(.iptv)
            }
        case .libraries:
            LibrarySettingsView(focusedSettingId: focusedSettingIdBinding)
        case .cache:
            CacheSettingsView(focusedSettingId: focusedSettingIdBinding, focusedSubtext: focusedSubtextBinding)
        case .userProfiles:
            UserProfileSettingsView(focusedSettingId: focusedSettingIdBinding)
        case .displaySizePicker:
            displaySizePickerPage
        case .audioLanguagePicker:
            audioLanguagePickerPage
        case .subtitlesPicker:
            subtitlesPickerPage
        case .autoplayCountdownPicker:
            autoplayCountdownPickerPage
        }
    }

    // MARK: - Root Settings List

    private var rootSettingsList: some View {
        Group {
            SettingsRow(
                title: "Appearance",
                subtitle: "",
                action: { navigate(to: .appearance) },
                focusTrigger: focusTrigger,
                onFocusChange: { if $0 { focusState.focusedSettingId = "cat_appearance" } }
            )

            SettingsRow(
                title: "Playback",
                subtitle: "",
                action: { navigate(to: .playback) },
                onFocusChange: { if $0 { focusState.focusedSettingId = "cat_playback" } }
            )

            SettingsRow(
                title: "Music",
                subtitle: "",
                action: { navigate(to: .music) },
                onFocusChange: { if $0 { focusState.focusedSettingId = "cat_music" } }
            )

            SettingsRow(
                title: "Live TV",
                subtitle: "",
                action: { navigate(to: .liveTV) },
                onFocusChange: { if $0 { focusState.focusedSettingId = "cat_liveTV" } }
            )

            SettingsRow(
                title: "Servers",
                subtitle: "",
                action: { navigate(to: .servers) },
                onFocusChange: { if $0 { focusState.focusedSettingId = "cat_servers" } }
            )

            SettingsRow(
                title: "User Profiles",
                subtitle: "",
                action: { navigate(to: .userProfiles) },
                onFocusChange: { if $0 { focusState.focusedSettingId = "userProfiles" } }
            )

            SettingsRow(
                title: "Cache & Storage",
                subtitle: "",
                action: { navigate(to: .cache) },
                onFocusChange: { if $0 { focusState.focusedSettingId = "cache" } }
            )

            SettingsRow(
                title: "About",
                subtitle: "",
                action: { navigate(to: .about) },
                onFocusChange: { if $0 { focusState.focusedSettingId = "cat_about" } }
            )
        }
    }

    // MARK: - Appearance Settings

    private var appearanceSettings: some View {
        Group {
            SettingsRow(
                title: "Sidebar Libraries",
                subtitle: "",
                action: { navigate(to: .libraries) },
                focusTrigger: focusTrigger,
                onFocusChange: { if $0 { focusState.focusedSettingId = "libraries" } }
            )

            SettingsRow(
                title: "Display Size",
                subtitle: displaySize.wrappedValue.description,
                action: { navigate(to: .displaySizePicker) },
                onFocusChange: { if $0 { focusState.focusedSettingId = "displaySize" } }
            )

            SettingsToggleRow(
                title: "Home Hero",
                subtitle: "",
                isOn: $showHomeHero,
                onFocusChange: { if $0 { focusState.focusedSettingId = "homeHero" } }
            )

            SettingsToggleRow(
                title: "Library Hero",
                subtitle: "",
                isOn: $showLibraryHero,
                onFocusChange: { if $0 { focusState.focusedSettingId = "libraryHero" } }
            )

            SettingsToggleRow(
                title: "Discovery Rows",
                subtitle: "",
                isOn: $showLibraryRecommendations,
                onFocusChange: { if $0 { focusState.focusedSettingId = "discoveryRows" } }
            )

            SettingsToggleRow(
                title: "Recent Rows",
                subtitle: "",
                isOn: $showLibraryRecentRows,
                onFocusChange: { if $0 { focusState.focusedSettingId = "recentRows" } }
            )

            SettingsToggleRow(
                title: "Personalized Recommendations",
                subtitle: "",
                isOn: $enablePersonalizedRecommendations,
                onFocusChange: { if $0 { focusState.focusedSettingId = "personalizedRecs" } }
            )
        }
    }

    // MARK: - Playback Settings

    private var playbackSettings: some View {
        Group {
            SettingsToggleRow(
                title: "Use Apple's Player",
                subtitle: "",
                isOn: $useApplePlayer,
                onFocusChange: { if $0 { focusState.focusedSettingId = "useApplePlayer" } }
            )

            SettingsRow(
                title: "Audio Language",
                subtitle: audioLanguage.description,
                action: { navigate(to: .audioLanguagePicker) },
                focusTrigger: focusTrigger,
                onFocusChange: { if $0 { focusState.focusedSettingId = "audioLanguage" } }
            )

            SettingsRow(
                title: "Subtitles",
                subtitle: subtitleOption.description,
                action: { navigate(to: .subtitlesPicker) },
                onFocusChange: { if $0 { focusState.focusedSettingId = "subtitles" } }
            )

            SettingsToggleRow(
                title: "Auto-Skip Intro",
                subtitle: "",
                isOn: $autoSkipIntro,
                onFocusChange: { if $0 { focusState.focusedSettingId = "autoSkipIntro" } }
            )

            SettingsToggleRow(
                title: "Auto-Skip Credits",
                subtitle: "",
                isOn: $autoSkipCredits,
                onFocusChange: { if $0 { focusState.focusedSettingId = "autoSkipCredits" } }
            )

            SettingsToggleRow(
                title: "Auto-Skip Ads",
                subtitle: "",
                isOn: $autoSkipAds,
                onFocusChange: { if $0 { focusState.focusedSettingId = "autoSkipAds" } }
            )

            SettingsRow(
                title: "Autoplay Countdown",
                subtitle: autoplayCountdown.wrappedValue.description,
                action: { navigate(to: .autoplayCountdownPicker) },
                onFocusChange: { if $0 { focusState.focusedSettingId = "autoplayCountdown" } }
            )


        }
    }

    // MARK: - Live TV Settings

    private var liveTVSettings: some View {
        Group {
            SettingsRow(
                title: "Live TV Sources",
                subtitle: "",
                action: { navigate(to: .iptv) },
                focusTrigger: focusTrigger,
                onFocusChange: { if $0 { focusState.focusedSettingId = "liveTVSources" } }
            )

            SettingsToggleRow(
                title: "Live TV Above Libraries",
                subtitle: "",
                isOn: $liveTVAboveLibraries,
                onFocusChange: { if $0 { focusState.focusedSettingId = "liveTVAboveLibraries" } }
            )

            SettingsToggleRow(
                title: "Classic TV Mode",
                subtitle: "",
                isOn: $classicTVMode,
                onFocusChange: { if $0 { focusState.focusedSettingId = "classicTVMode" } }
            )

            SettingsToggleRow(
                title: "Combine Sources",
                subtitle: "",
                isOn: $combineLiveTVSources,
                onFocusChange: { if $0 { focusState.focusedSettingId = "combineSources" } }
            )

            SettingsPickerRow(
                title: "Default Layout",
                subtitle: "",
                selection: liveTVLayout,
                options: LiveTVLayout.allCases,
                onFocusChange: { if $0 { focusState.focusedSettingId = "defaultLayout" } }
            )

            SettingsToggleRow(
                title: "Confirm Exit Multiview",
                subtitle: "",
                isOn: $confirmExitMultiview,
                onFocusChange: { if $0 { focusState.focusedSettingId = "confirmExitMultiview" } }
            )

            SettingsToggleRow(
                title: "Allow 3 or 4 Streams",
                subtitle: "",
                isOn: $allowFourStreams,
                onFocusChange: { if $0 { focusState.focusedSettingId = "allowFourStreams" } }
            )
        }
    }

    // MARK: - Music Settings

    private var musicSettings: some View {
        Group {
            SettingsToggleRow(
                title: "Loudness Normalization",
                subtitle: "Even out volume differences between tracks using ReplayGain",
                isOn: $musicLoudnessNormalization,
                onFocusChange: { if $0 { focusState.focusedSettingId = "musicLoudness" } }
            )

            SettingsPickerRow(
                title: "Crossfade",
                subtitle: "",
                selection: crossfadeSelection,
                options: CrossfadeOption.allCases,
                onFocusChange: { if $0 { focusState.focusedSettingId = "musicCrossfade" } }
            )

            SettingsToggleRow(
                title: "Audio Quality Badges",
                subtitle: "Show codec and quality indicators on tracks and albums",
                isOn: $musicShowQualityBadges,
                onFocusChange: { if $0 { focusState.focusedSettingId = "musicQualityBadges" } }
            )
        }
    }

    // MARK: - Servers Settings

    private var serversSettings: some View {
        Group {
            SettingsRow(
                title: "Plex Server",
                subtitle: "",
                action: { navigate(to: .plex) },
                focusTrigger: focusTrigger,
                onFocusChange: { if $0 { focusState.focusedSettingId = "plexServer" } }
            )
        }
    }

    // MARK: - About Settings

    private var aboutSettings: some View {
        Group {
            SettingsInfoRow(title: "App", value: "Rivulet")
            SettingsInfoRow(title: "Version", value: appVersion)

            SettingsRow(
                title: "Changelog",
                subtitle: "",
                action: { showChangelog = true },
                onFocusChange: { if $0 { focusState.focusedSettingId = "changelog" } }
            )
        }
    }

    // MARK: - Picker Pages

    private var displaySizePickerPage: some View {
        Group {
            ForEach(DisplaySize.allCases, id: \.self) { option in
                Button {
                    displaySizeRaw = option.rawValue
                    goBack()
                } label: {
                    HStack {
                        Text(option.description)
                            .font(.system(size: 32))
                        Spacer()
                        if displaySize.wrappedValue == option {
                            Image(systemName: "checkmark")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
    }

    private var audioLanguagePickerPage: some View {
        Group {
            ForEach(LanguageOption.allCases, id: \.self) { option in
                Button {
                    audioLanguageBinding.wrappedValue = option
                    goBack()
                } label: {
                    HStack {
                        Text(option.description)
                            .font(.system(size: 32))
                        Spacer()
                        if audioLanguage == option {
                            Image(systemName: "checkmark")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
    }

    private var subtitlesPickerPage: some View {
        Group {
            ForEach(SubtitleOption.allCases, id: \.self) { option in
                Button {
                    subtitleOptionBinding.wrappedValue = option
                    goBack()
                } label: {
                    HStack {
                        Text(option.description)
                            .font(.system(size: 32))
                        Spacer()
                        if subtitleOption == option {
                            Image(systemName: "checkmark")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
    }

    private var autoplayCountdownPickerPage: some View {
        Group {
            ForEach(AutoplayCountdown.allCases, id: \.self) { option in
                Button {
                    autoplayCountdownRaw = option.rawValue
                    goBack()
                } label: {
                    HStack {
                        Text(option.description)
                            .font(.system(size: 32))
                        Spacer()
                        if autoplayCountdown.wrappedValue == option {
                            Image(systemName: "checkmark")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Navigation

    private func navigate(to page: SettingsPage) {
        focusState.focusedSettingId = nil
        focusState.focusedSubtext = nil
        animatePageSwap(forward: true) {
            navigationStack.append(page)
        }
    }

    private func goBack() {
        guard navigationStack.count > 1 else { return }
        focusState.focusedSettingId = nil
        focusState.focusedSubtext = nil
        animatePageSwap(forward: false) {
            navigationStack.removeLast()
        }
    }

    private func navigateBackTo(_ page: SettingsPage) {
        focusState.focusedSettingId = nil
        focusState.focusedSubtext = nil
        animatePageSwap(forward: false) {
            if let index = navigationStack.lastIndex(of: page) {
                navigationStack.removeSubrange((index + 1)...)
            }
        }
    }

    /// Crossfade + subtle slide between settings pages. The content swaps
    /// while invisible, with a small (~18pt) directional drift so the
    /// motion reads as a gentle slide rather than a hard jump. Driven by
    /// SwiftUI animatable modifiers on the FocusContainedView wrapper
    /// because UIHostingController swallows .transition()/.id() inside.
    private func animatePageSwap(forward: Bool, swap: @escaping () -> Void) {
        let fadeOutDuration: Double = 0.12
        let fadeInDuration: Double = 0.20
        let slideDistance: CGFloat = 18
        let outOffset: CGFloat = forward ? -slideDistance : slideDistance
        let inFromOffset: CGFloat = forward ? slideDistance : -slideDistance

        // Phase 1: fade current page out with a small drift.
        withAnimation(.easeOut(duration: fadeOutDuration)) {
            pageOffsetX = outOffset
            pageOpacity = 0
        }

        // Phase 2: swap content while invisible, start slightly offset on
        // the incoming side, then fade/drift into place.
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutDuration) {
            swap()
            pageOffsetX = inFromOffset
            pageOpacity = 0
            withAnimation(.easeOut(duration: fadeInDuration)) {
                pageOffsetX = 0
                pageOpacity = 1
            }
        }
    }

}

// MARK: - Settings Left Panel (Isolated View)

/// Extracted into its own struct so `focusedSettingId` changes only re-render
/// this panel, not the entire right-side button list (which caused flickering).
private struct SettingsLeftPanel: View {
    var focusState: SettingsFocusState
    let currentPage: SettingsPage

    @State private var focusedSettingId: String?
    @State private var focusedSubtext: String?

    var body: some View {
        let descriptor = focusedSettingId.flatMap { SettingsDescriptorStore.descriptor(for: $0) }
        let pageInfo = SettingsDescriptorStore.pageInfo(for: currentPage)
        let iconName = pageInfo.icon
        let iconColor = pageInfo.color

        VStack(spacing: 0) {
            Spacer()

            // Fixed-height icon area — position never shifts
            ZStack {
                RoundedRectangle(cornerRadius: 60, style: .continuous)
                    .fill(iconColor.opacity(0.18))
                    .frame(width: 320, height: 320)

                Image(systemName: iconName)
                    .font(.system(size: 120, weight: .medium))
                    .foregroundStyle(iconColor)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            .frame(height: 320)

            // Fixed-height description area — always takes same space
            VStack(spacing: 12) {
                Text(descriptor?.description ?? " ")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(descriptor != nil ? 0.55 : 0))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .lineLimit(4)
                    .frame(maxWidth: 700)

                if let subtext = focusedSubtext {
                    Text(subtext)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .multilineTextAlignment(.center)
                }
            }
            .frame(height: 190, alignment: .top)
            .padding(.top, 28)

            Spacer()
        }
        .onReceive(focusState.publisher) { id in
            focusedSettingId = id
        }
        .onReceive(focusState.subtextPublisher) { subtext in
            focusedSubtext = subtext
        }
        .animation(.easeInOut(duration: 0.25), value: focusedSettingId)
        .animation(.easeInOut(duration: 0.25), value: focusedSubtext)
        .animation(.easeInOut(duration: 0.3), value: currentPage)
    }
}

// MARK: - Focus Containment (blocks leftward focus escape to sidebar)

/// Wraps SwiftUI content in a UIHostingController that can block leftward focus escape.
/// Used by SettingsView to prevent left-press from opening the sidebar when in sub-pages.
private struct FocusContainedView<Content: View>: UIViewControllerRepresentable {
    let blockLeftEscape: Bool
    let onLeftBlocked: () -> Void
    let content: Content

    init(blockLeftEscape: Bool, onLeftBlocked: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.blockLeftEscape = blockLeftEscape
        self.onLeftBlocked = onLeftBlocked
        self.content = content()
    }

    func makeUIViewController(context: Context) -> FocusContainedHostingController<Content> {
        let vc = FocusContainedHostingController(rootView: content)
        vc.view.backgroundColor = .clear
        vc.blockLeftEscape = blockLeftEscape
        vc.onLeftBlocked = onLeftBlocked
        return vc
    }

    func updateUIViewController(_ vc: FocusContainedHostingController<Content>, context: Context) {
        vc.blockLeftEscape = blockLeftEscape
        vc.onLeftBlocked = onLeftBlocked
        vc.rootView = content
    }
}

/// Hosting controller that overrides shouldUpdateFocus to block leftward focus escape.
private final class FocusContainedHostingController<Content: View>: UIHostingController<Content> {
    var blockLeftEscape = false
    var onLeftBlocked: (() -> Void)?

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if blockLeftEscape,
           context.focusHeading == .left,
           let nextView = context.nextFocusedView,
           !nextView.isDescendant(of: view) {
            DispatchQueue.main.async { [weak self] in
                self?.onLeftBlocked?()
            }
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }
}

#Preview {
    SettingsView()
}
