# Looma Beauty Camera for iOS

AppLooma RTC's free real-time beauty camera, as a Swift package. Skin
smoothing, whitening, rosy tone, sharpening, contrast, low light, make-up
looks, colour filters, face masks and virtual backgrounds, drawn with Metal
on the camera before it is encoded, so viewers see exactly what the host
sees in the preview.

- iOS 14 or later (virtual backgrounds need iOS 15).
- Works with the AppLooma RTC iOS SDK (`AppLoomaRTC`) 0.6.0 or later.
- Free to use with AppLooma RTC; see LICENSE.

## Install (Swift Package Manager)

In Xcode: File > Add Package Dependencies, enter
`https://github.com/AppLooma-RTC/LoomaBeautyCamera-iOS.git` and add the
`LoomaBeautyCamera` library. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/AppLooma-RTC/LoomaBeautyCamera-iOS.git", from: "0.2.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "LoomaBeautyCamera", package: "LoomaBeautyCamera-iOS"),
    ]),
]
```

It brings in `AppLoomaRTC` itself.

## Two products, and the pod

Since 0.2.0 the package has two libraries:

| Product | What it is | Depends on |
| --- | --- | --- |
| `LoomaBeautyCore` | Every effect, the panels, the catalogue and the assets. `AppBeauty.process(_:rotation:timestamp:)` takes and returns a `CVPixelBuffer`, so it works with any camera pipeline (your own `AVCaptureSession`, another media SDK, a Flutter or React Native bridge). | nothing |
| `LoomaBeautyCamera` | `LoomaBeautyCore` plus the AppLooma RTC glue: `AppBeauty` conforms to `AppVideoFrameProcessor`, so `engine.setVideoProcessor(beauty)` (or `engine.setBeauty(beauty)`) works. It re-exports `LoomaBeautyCore`, so `import LoomaBeautyCamera` is all you need, and 0.1.0 code compiles unchanged. | `LoomaBeautyCore`, `AppLoomaRTC` |

Without AppLooma RTC, depend on the core only:

```swift
.product(name: "LoomaBeautyCore", package: "LoomaBeautyCamera-iOS"),
```

```swift
import LoomaBeautyCore

let beauty = AppBeauty.create()
// On the capture thread, for every frame (32BGRA or 420f/420v NV12):
let out = beauty.process(pixelBuffer, rotation: 90, timestamp: ptsNanos)
```

### CocoaPods

The core is also a pod, `LoomaBeautyCore` (`LoomaBeautyCamera.podspec` at the
root of the repository):

```ruby
pod 'LoomaBeautyCore', :git => 'https://github.com/AppLooma-RTC/LoomaBeautyCamera-iOS.git', :tag => '0.2.0'
```

then `import LoomaBeautyCore`. The RTC glue is a one-line extension
(`extension AppBeauty: AppVideoFrameProcessor {}`) if you use the RTC SDK
from CocoaPods as well.

## Use

```swift
import AppLoomaRTC
import LoomaBeautyCamera

let beauty = AppBeauty.create()        // Smart Beauty is on from the start
engine.setVideoProcessor(beauty)        // before or after enableCamera

// The panels (bottom sheets over your camera screen):
AppBeautyPanel.show(in: self, beauty: beauty)       // Presets, Beauty, Make up, Filter
AppBeautyPanel.showMagic(in: self, beauty: beauty)  // Mask, Background

// Or in code:
beauty.setPreset(AppBeautyPreset.named("NATURAL")!)
beauty.options = beauty.options.with(.smooth, 0.7)
beauty.options.filter = AppBeautyFilter.named("GLOW") ?? .none
beauty.setMask(id: "kitty")                          // nil removes it
beauty.background = AppBeautyBackground.named("BLUR") ?? .none
beauty.customBackground = myImage; beauty.background = .custom

engine.setVideoProcessor(nil)                        // off
```

`beauty.options = AppBeauty.off` turns every effect off while keeping the
processor attached.

## What it does

| Area | Items |
| --- | --- |
| Skin | Skin (smoothing), Complexion (4 tones), Contour, 3D Light, Brighten, Rosy, Contrast, Sharpen, Low Light |
| Touch up | Lipstick, Eyebrow, Eyeshadow, Eyelash, Beauty Lenses, Blemish |
| Eyes, nose, mouth | Clarity, Circle (dark circles), Wrinkles (smile lines), Tooth |
| Make up | 78 looks in 7 categories, each with its own filter |
| Filter | 52 colour filters in 9 categories |
| Magic | 170 face masks; blur, frosted glass, scene and custom backgrounds |

Face-shape items (Face: Slim, Shape, Cheek, Chin, Temple, Hairline, Face
Shrink, Chin Shape, Shorten Face, Jaw; Eyes: Enlarge, Pupils, Eyelid,
Eyebrow Height, Eye Height, Eye Shape, Eyebrow Shape, Brow trim, Eye
Distance; Nose: Nose tip, Philtrum, Nose, Narrow, Bridge, Nasal Bridge,
Wings; Mouth: Mouth, Full lip, Mouth Size, Mouth Height, Smile) are kept in
the options and drawn as local warps of the picture around the face
landmarks, before every other effect (`AppBeautyItem.isReshape`). They ease
off while the head moves fast, so a warp never lags visibly behind the face.
0.1.0 kept these items but did not draw them.

Pictures for backgrounds, masks and the panel cards are downloaded the
first time they are needed and kept in the app's Caches folder.

## How the camera hook works

With `LoomaBeautyCamera`, `AppBeauty` implements the SDK's `AppVideoFrameProcessor`. Each camera frame
(`CVPixelBuffer`, NV12 or BGRA) is mapped into Metal with no copy, processed
and returned as a new BGRA buffer of the same size. Face landmarks come from
Vision every second frame off the capture thread, smoothed over time;
person segmentation for backgrounds uses Vision's person segmentation.
