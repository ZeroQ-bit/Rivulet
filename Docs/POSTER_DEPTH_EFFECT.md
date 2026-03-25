# Poster Depth Effect (Disabled)

This feature is currently disabled but the implementation files remain in the codebase for potential future use.

## What It Does

When a poster is focused on tvOS, the foreground subject (actor, character) lifts off the background with a drop shadow, creating a subtle 3D depth effect.

## How It Works

1. **DepthLayerProcessor** uses Vision framework (`VNGenerateForegroundInstanceMaskRequest`) to detect the foreground subject in poster artwork
2. Creates a foreground cutout (PNG with transparency) of just the subject
3. **ParallaxLayerStack** composites the original poster + foreground cutout in a ZStack
4. On focus, a shadow animates in behind the foreground layer (spring animation, 0.35s response)

### Quality Gating

- Mask coverage must be 5-90% of the image (rejects images with no clear subject or fully masked)
- Quality score based on how close coverage is to optimal 40% (portrait-style framing)
- Score >= 0.5 required to show the effect; unsuitable images are flagged to skip reprocessing

### Performance

- Max 2 concurrent Vision processing tasks
- 0.2s debounce to skip processing during fast scrolling
- Two-tier cache: NSCache (50 items) + disk (500MB LRU)
- Unsuitable images flagged in cache to avoid reprocessing

## Implementation Files

| File | Purpose |
|------|---------|
| `Services/ImageProcessing/DepthLayerProcessor.swift` | Vision-based foreground detection (actor, singleton) |
| `Services/ImageProcessing/DepthLayerCache.swift` | Memory + disk cache with LRU eviction |
| `Services/ImageProcessing/DepthLayerResult.swift` | Result model (UIImage + quality score) |
| `Views/Components/ParallaxPosterImage.swift` | Orchestrator view (load, process, cache) |
| `Views/Components/ParallaxLayerStack.swift` | Rendering view (ZStack with animated shadow) |

## Re-enabling

In `MediaPosterCard.swift`, the `posterImage` computed property currently always returns `standardPosterImage`. To re-enable:

1. Add `@AppStorage("posterDepthEffect") private var posterDepthEffect = true`
2. Conditionally return `ParallaxPosterImage(...)` when enabled
3. Use `ConditionalClipShape` to avoid double-clipping (ParallaxLayerStack clips internally)
4. Add the setting toggle back in `SettingsView.swift` and descriptor in `SettingsDescriptors.swift`

### Shadow Parameters (for reference)

```swift
// Focused state
shadow color: .black, opacity: 0.7, radius: 6, y: 4
// Unfocused
shadow opacity: 0, radius: 0, y: 0
// Animation
.spring(response: 0.35, dampingFraction: 0.8)
```

### Settings Descriptor (for reference)

```swift
"posterDepthEffect": SettingDescriptor(
    icon: "square.3.layers.3d",
    iconColor: .blue,
    description: "Adds a subtle parallax depth effect to poster artwork when focused, lifting the subject from the background."
)
```
