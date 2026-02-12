//
//  VideoPlayerView.swift
//  Rivulet
//
//  Full-screen video player using AVPlayerViewController
//

import SwiftUI
import AVKit
import Combine

struct VideoPlayerView: View {
    let item: PlexMetadata
    var startOffset: Int? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var authManager = PlexAuthManager.shared
    @StateObject private var playbackManager = PlaybackManager.shared

    @State private var isLoading = true
    @State private var hasError = false
    @State private var errorMessage = ""
    @State private var showVideoInfo = false
    @State private var detailedMetadata: PlexMetadata?
    @State private var isLoadingMetadata = false

    private let networkManager = PlexNetworkManager.shared

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if isLoading {
                loadingView
            } else if hasError {
                errorView
            } else if let player = playbackManager.player {
                VideoPlayerRepresentable(
                    player: player,
                    metadata: detailedMetadata ?? item,
                    showVideoInfo: $showVideoInfo
                )
                .ignoresSafeArea()
            }
            
            // Video Info Overlay
            if showVideoInfo {
                VideoInfoOverlay(metadata: detailedMetadata ?? item, isPresented: $showVideoInfo)
            }
        }
        .task {
            await startPlayback()
            // Pre-load detailed metadata for the info panel
            await loadDetailedMetadata(showOverlay: false)
        }
        .onDisappear {
            playbackManager.stop()
        }
        .onReceive(playbackManager.$error) { error in
            if let error = error {
                // Only show error if we don't have a player or if all strategies failed
                if playbackManager.player == nil {
                    hasError = true
                    if let playerError = error as? PlayerError {
                        errorMessage = playerError.userFacingDescription
                    } else {
                        errorMessage = error.localizedDescription
                    }
                } else {
                    // Player exists - log error but don't show error screen
                    // This handles cases where audio works but video has issues
                    if let playerError = error as? PlayerError {
                        print("⚠️ Playback error (player still active): \(playerError.technicalDescription)")
                    } else {
                        print("⚠️ Playback error (player still active): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(2)

            Text("Loading...")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(item.title ?? "")
                .font(.headline)
        }
    }

    // MARK: - Error View

    private var errorView: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.yellow)

            Text("Playback Error")
                .font(.title)

            Text(errorMessage)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Dismiss") {
                dismiss()
            }
            .buttonStyle(AppStoreButtonStyle())
            .padding(.top, 20)
        }
    }

    // MARK: - Playback

    private func startPlayback() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else {
            hasError = true
            errorMessage = "Not authenticated"
            isLoading = false
            return
        }

        await playbackManager.play(
            item: item,
            serverURL: serverURL,
            authToken: token,
            startOffset: startOffset
        )

        isLoading = false
    }
    
    // MARK: - Metadata Loading
    
    private func loadDetailedMetadata(showOverlay: Bool = true) async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              let ratingKey = item.ratingKey else {
            detailedMetadata = item
            if showOverlay { showVideoInfo = true }
            return
        }
        
        isLoadingMetadata = true
        
        do {
            let metadata = try await networkManager.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: ratingKey
            )
            detailedMetadata = metadata
            if showOverlay { showVideoInfo = true }
        } catch {
            print("VideoPlayerView: Failed to load detailed metadata: \(error)")
            detailedMetadata = item
            if showOverlay { showVideoInfo = true }
        }
        
        isLoadingMetadata = false
    }
}

// MARK: - AVPlayerViewController Wrapper

#if os(tvOS)
struct VideoPlayerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    let metadata: PlexMetadata
    @Binding var showVideoInfo: Bool
    
    func makeCoordinator() -> Coordinator {
        Coordinator(showVideoInfo: $showVideoInfo, player: player)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        
        // Don't set player immediately - wait for proper layout
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = false
        
        // Create custom info view controller for swipe-down info panel
        let infoVC = VideoInfoViewController(metadata: metadata, coordinator: context.coordinator)
        controller.customInfoViewControllers = [infoVC]
        
        // Store reference for delayed player assignment
        context.coordinator.playerViewController = controller
        
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Only update player if view has proper size to avoid constraint conflicts
        if uiViewController.view.bounds.width > 0 && uiViewController.view.bounds.height > 0 {
            if uiViewController.player !== player {
                uiViewController.player = player
            }
        } else {
            // Schedule player assignment after layout
            DispatchQueue.main.async {
                if uiViewController.player !== player {
                    uiViewController.player = player
                }
            }
        }
        
        // Update the info view controller with new metadata
        if let infoVC = uiViewController.customInfoViewControllers.first as? VideoInfoViewController {
            infoVC.updateMetadata(metadata)
        }
    }
    
    class Coordinator {
        @Binding var showVideoInfo: Bool
        weak var playerViewController: AVPlayerViewController?
        let player: AVPlayer
        
        init(showVideoInfo: Binding<Bool>, player: AVPlayer) {
            _showVideoInfo = showVideoInfo
            self.player = player
        }
        
        func showInfo() {
            showVideoInfo = true
        }
    }
}

// MARK: - Custom Info View Controller for tvOS Player
class VideoInfoViewController: UIViewController {
    private var metadata: PlexMetadata
    private weak var coordinator: VideoPlayerRepresentable.Coordinator?
    
    init(metadata: PlexMetadata, coordinator: VideoPlayerRepresentable.Coordinator) {
        self.metadata = metadata
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
        self.title = "Video Info"
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateMetadata(_ metadata: PlexMetadata) {
        self.metadata = metadata
        if isViewLoaded {
            setupUI()
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    private func setupUI() {
        // Clear existing subviews
        view.subviews.forEach { $0.removeFromSuperview() }
        
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        
        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 40),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 40),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -40),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -40),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -80)
        ])
        
        // Title
        if let title = metadata.title {
            let titleLabel = createLabel(text: title, fontSize: 32, weight: .bold)
            contentStack.addArrangedSubview(titleLabel)
        }
        
        // Media Info Section
        if let media = metadata.Media?.first {
            contentStack.addArrangedSubview(createSectionHeader("Media Details"))
            
            if let videoCodec = media.videoCodec {
                contentStack.addArrangedSubview(createInfoRow(label: "Video Codec", value: videoCodec))
            }
            if let resolution = media.videoResolution {
                contentStack.addArrangedSubview(createInfoRow(label: "Resolution", value: resolution))
            }
            if let width = media.width, let height = media.height {
                contentStack.addArrangedSubview(createInfoRow(label: "Dimensions", value: "\(width) × \(height)"))
            }
            if let bitrate = media.bitrate {
                let bitrateStr = bitrate >= 1000000 ? String(format: "%.1f Mbps", Double(bitrate) / 1000000.0) : "\(bitrate / 1000) kbps"
                contentStack.addArrangedSubview(createInfoRow(label: "Bitrate", value: bitrateStr))
            }
            if let container = media.container {
                contentStack.addArrangedSubview(createInfoRow(label: "Container", value: container))
            }
            if let audioCodec = media.audioCodec {
                contentStack.addArrangedSubview(createInfoRow(label: "Audio Codec", value: audioCodec))
            }
            if let audioChannels = media.audioChannels {
                contentStack.addArrangedSubview(createInfoRow(label: "Audio Channels", value: "\(audioChannels)"))
            }
            
            // File info
            if let parts = media.Part, let part = parts.first {
                contentStack.addArrangedSubview(createSectionHeader("File"))
                
                if let file = part.file {
                    let fileName = (file as NSString).lastPathComponent
                    contentStack.addArrangedSubview(createInfoRow(label: "File", value: fileName))
                }
                if let size = part.size {
                    let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                    contentStack.addArrangedSubview(createInfoRow(label: "Size", value: sizeStr))
                }
            }
        }
        
        // Metadata Section
        contentStack.addArrangedSubview(createSectionHeader("Metadata"))
        
        if let year = metadata.year {
            contentStack.addArrangedSubview(createInfoRow(label: "Year", value: "\(year)"))
        }
        if let contentRating = metadata.contentRating {
            contentStack.addArrangedSubview(createInfoRow(label: "Rating", value: contentRating))
        }
        if let studio = metadata.studio {
            contentStack.addArrangedSubview(createInfoRow(label: "Studio", value: studio))
        }
        
        // "More Info" button to show full overlay
        let moreButton = UIButton(type: .system)
        moreButton.setTitle("Show Full Details", for: .normal)
        moreButton.titleLabel?.font = UIFont.systemFont(ofSize: 24, weight: .medium)
        moreButton.addTarget(self, action: #selector(showFullDetails), for: .primaryActionTriggered)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(moreButton)
    }
    
    @objc private func showFullDetails() {
        coordinator?.showInfo()
    }
    
    private func createLabel(text: String, fontSize: CGFloat, weight: UIFont.Weight) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: fontSize, weight: weight)
        label.textColor = .white
        label.numberOfLines = 0
        return label
    }
    
    private func createSectionHeader(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: 26, weight: .semibold)
        label.textColor = .white
        return label
    }
    
    private func createInfoRow(label: String, value: String) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 16
        
        let labelView = UILabel()
        labelView.text = label
        labelView.font = UIFont.systemFont(ofSize: 22, weight: .medium)
        labelView.textColor = .lightGray
        labelView.widthAnchor.constraint(equalToConstant: 160).isActive = true
        
        let valueView = UILabel()
        valueView.text = value
        valueView.font = UIFont.systemFont(ofSize: 22, weight: .regular)
        valueView.textColor = .white
        valueView.numberOfLines = 2
        
        stack.addArrangedSubview(labelView)
        stack.addArrangedSubview(valueView)
        
        return stack
    }
}
#else
// macOS/iOS preview support
struct VideoPlayerRepresentable: View {
    let player: AVPlayer
    let metadata: PlexMetadata
    @Binding var showVideoInfo: Bool

    var body: some View {
        VideoPlayer(player: player)
    }
}
#endif

// MARK: - Episode Player Wrapper

/// Convenience view for playing episodes with show context
struct EpisodePlayerView: View {
    let episode: PlexMetadata
    let showTitle: String?

    var body: some View {
        VideoPlayerView(item: episode)
    }
}

#Preview {
    let sampleMovie = PlexMetadata(
        ratingKey: "123",
        key: "/library/metadata/123",
        type: "movie",
        title: "Sample Movie",
        year: 2024,
        duration: 7200000
    )

    VideoPlayerView(item: sampleMovie)
}
