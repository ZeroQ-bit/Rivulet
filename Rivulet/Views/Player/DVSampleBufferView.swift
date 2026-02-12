//
//  DVSampleBufferView.swift
//  Rivulet
//
//  SwiftUI wrapper for AVSampleBufferDisplayLayer-based DV playback.
//  Hosts the display layer from DVSampleBufferPlayer.
//

import SwiftUI
import AVFoundation

/// A SwiftUI view that displays video content using AVSampleBufferDisplayLayer
struct DVSampleBufferView: UIViewRepresentable {
    @ObservedObject var player: DVSampleBufferPlayer

    func makeUIView(context: Context) -> DVSampleBufferUIView {
        let view = DVSampleBufferUIView()
        view.attachDisplayLayer(player.displayLayer)
        return view
    }

    func updateUIView(_ uiView: DVSampleBufferUIView, context: Context) {
        // Display layer is attached once on creation; no dynamic updates needed
    }
}

/// UIView subclass that hosts an AVSampleBufferDisplayLayer for DV video rendering
final class DVSampleBufferUIView: UIView {

    private var sampleBufferLayer: AVSampleBufferDisplayLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }

    func attachDisplayLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        // Remove existing layer if any
        sampleBufferLayer?.removeFromSuperlayer()

        displayLayer.frame = bounds
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(displayLayer)
        sampleBufferLayer = displayLayer

    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sampleBufferLayer?.frame = bounds
    }
}
