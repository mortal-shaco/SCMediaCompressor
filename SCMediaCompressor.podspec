Pod::Spec.new do |s|
  s.name = 'SCMediaCompressor'
  s.version = '1.0.0'
  s.summary = 'Configurable image, video and Live Photo compression for iOS.'
  s.description = 'One Objective-C core for image fidelity and HDR, automatic H264 SDR or HEVC HDR video with MP4/MOV and size protection, and Live Photo pairing. Swift callable, configurable pixel bounds, asynchronous progress and cancellation.'
  s.homepage = 'https://github.com/mortal-shaco/SCMediaCompressor'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = { 'Shaco' => 'https://github.com/mortal-shaco' }
  s.source = { :git => 'https://github.com/mortal-shaco/SCMediaCompressor.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.requires_arc = true
  s.source_files = 'Sources/SCMediaCompressor/*.{h,m}'
  s.private_header_files = 'Sources/SCMediaCompressor/SCFidelity.h', 'Sources/SCMediaCompressor/SCInternal.h', 'Sources/SCMediaCompressor/SCLogger.h', 'Sources/SCMediaCompressor/SCImageHDR.h', 'Sources/SCMediaCompressor/SCSizePolicy.h', 'Sources/SCMediaCompressor/SCImageCodec.h', 'Sources/SCMediaCompressor/SCImageSelection.h', 'Sources/SCMediaCompressor/SCVideoContainer.h', 'Sources/SCMediaCompressor/SCVideoMedia.h', 'Sources/SCMediaCompressor/SCVideoCompressorInternal.h'
  s.frameworks = 'Foundation', 'UIKit', 'AVFoundation', 'CoreMedia', 'CoreVideo', 'CoreGraphics', 'CoreImage', 'ImageIO', 'UniformTypeIdentifiers'
  s.module_name = 'SCMediaCompressor'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'GCC_OPTIMIZATION_LEVEL' => '2', 'CLANG_ENABLE_MODULES' => 'YES' }
  s.preserve_paths = 'THIRD_PARTY_NOTICES.md', 'Examples/**/*', 'README.md', 'README.en.md'
end
