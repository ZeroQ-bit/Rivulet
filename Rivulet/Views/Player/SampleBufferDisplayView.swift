//
//  SampleBufferDisplayView.swift
//  Rivulet
//
//  SwiftUI wrapper for AVSampleBufferDisplayLayer used by RivuletPlayer.
//  Hosts the display layer in the view hierarchy for video rendering.
//

import SwiftUI
import AVFoundation

/// SwiftUI view that displays video from a RivuletPlayer's AVSampleBufferDisplayLayer.
struct SampleBufferDisplayView: UIViewRepresentable {
    @ObservedObject var player: RivuletPlayer

    func makeUIView(context: Context) -> SampleBufferUIView {
        let view = SampleBufferUIView()
        view.attachDisplayLayer(player.displayLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferUIView, context: Context) {
        // Display layer is attached once at creation; no dynamic updates needed
    }
}

/// UIView that hosts an AVSampleBufferDisplayLayer for video rendering.
final class SampleBufferUIView: UIView {
    private var sampleBufferLayer: AVSampleBufferDisplayLayer?

    func attachDisplayLayer(_ displayLayer: AVSampleBufferDisplayLayer) {
        guard sampleBufferLayer == nil else { return }
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
