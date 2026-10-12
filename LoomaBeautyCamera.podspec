# Looma Beauty Camera core for CocoaPods: every effect, the panels, the
# catalogue and the assets, without the AppLooma RTC glue (that part is in the
# Swift package's LoomaBeautyCamera product). Paths are relative to the root of
# https://github.com/AppLooma-RTC/LoomaBeautyCamera-iOS. © AppLooma LLC
Pod::Spec.new do |s|
  s.name             = 'LoomaBeautyCore'
  s.module_name      = 'LoomaBeautyCore'
  s.version          = '0.2.0'
  s.summary          = 'Looma Beauty Camera: free real-time beauty, make-up, filters, masks and backgrounds for iOS.'
  s.description      = <<-DESC
    GPU (Metal) skin smoothing, whitening, face reshape, make-up, colour filters,
    face masks and virtual backgrounds for camera frames, with ready-made panels.
    Works on any CVPixelBuffer pipeline through AppBeauty.process(_:rotation:timestamp:).
  DESC
  s.homepage         = 'https://applooma.dev'
  s.license          = { :type => 'Looma Beauty Camera Free License', :file => 'LICENSE' }
  s.author           = { 'AppLooma LLC' => 'support@applooma.dev' }
  s.source           = { :git => 'https://github.com/AppLooma-RTC/LoomaBeautyCamera-iOS.git', :tag => "#{s.version}" }
  s.platform         = :ios, '14.0'
  s.swift_version    = '5.9'
  s.source_files     = 'Sources/LoomaBeautyCore/**/*.swift'
  s.resource_bundles = { 'LoomaBeautyCore' => ['Sources/LoomaBeautyCore/Resources/beauty-catalog.json'] }
  s.frameworks       = 'CoreImage', 'CoreVideo', 'Metal', 'QuartzCore', 'UIKit', 'Vision', 'PhotosUI'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
