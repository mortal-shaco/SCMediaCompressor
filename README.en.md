# SCMediaCompressor

[中文](README.md) · iOS 15+ · Objective-C / Swift · MIT

SCMediaCompressor compresses images, videos and Live Photos on iOS using Apple frameworks. It provides asynchronous tasks, progress, cancellation and Live Photo pairing, with no third-party runtime dependencies.

## Features

- Images: fit within pixel bounds, normalize orientation, handle transparency, and produce JPEG, PNG or optional HEIC.
- Videos: H.264 / MP4 / SDR by default, with configurable dimensions, frame rate, bitrate, trimming, audio mixing and custom rendering.
- Live Photos: compress both resources and return paired JPEG / MOV files.
- Tasks: process media in the background and deliver high-level progress and completion on the main queue.
- Size protection: compare actual output bytes with a file baseline and retain the smaller result when it meets the requested output configuration.

The host app handles media selection, iCloud downloads, permissions, uploads and UI.

## Installation

Install with CocoaPods:

```ruby
platform :ios, '15.0'
pod 'SCMediaCompressor', '~> 1.0', :modular_headers => true
```

If your local or CDN index does not yet list the version, install the fixed Git tag directly:

```ruby
platform :ios, '15.0'
pod 'SCMediaCompressor', :git => 'https://github.com/mortal-shaco/SCMediaCompressor.git', :tag => '1.0.0', :modular_headers => true
```

To follow the latest public code, replace `:tag => '1.0.0'` with `:branch => 'main'`. Run `pod install`, then open your project's `.xcworkspace`.

```objc
#import <SCMediaCompressor/SCMediaCompressor.h>
```

```swift
import SCMediaCompressor
```

Basic features require iOS 15 or later. HDR image preservation also depends on system codec support; cross-format HDR conversion and HDR UIImage resizing require iOS 18 or later.

## Compress an image

Prefer the original encoded data when available so input byte statistics remain meaningful.

```objc
SCImageCompressionOptions *options = [SCImageCompressionOptions new];
options.maximumSize = CGSizeMake(1920, 1920);
options.quality = 0.8;

SCCompressionTask *task = [SCMediaCompressor sc_compressImageData:inputData
    options:options progress:^(double progress) {
        // Update your progress UI.
    } completion:^(NSData *data, NSError *error) {
        if (error) {
            NSLog(@"%@", error.localizedDescription);
            return;
        }
        NSString *mimeType = [SCImageCompressor sc_mimeTypeForData:data];
        // Use the actual output format for the file extension and MIME type.
        NSLog(@"%@, %lu bytes", mimeType, (unsigned long)data.length);
    }];
```

```swift
let options = SCImageCompressionOptions()
options.maximumSize = CGSize(width: 1920, height: 1920)
options.quality = 0.8

let task = SCMediaCompressor.sc_compressImageData(inputData, options: options, progress: { progress in
    // Update your progress UI.
}) { data, error in
    guard let data else {
        print(error?.localizedDescription ?? "Image processing failed")
        return
    }
    print(SCImageCompressor.sc_mimeType(for: data), data.count)
}
```

For a UIImage, use `sc_compressImage:options:progress:completion:`. `SCImageCompressor` also exposes synchronous APIs; run large-image operations on a background queue.

### Image options

- `maximumSize`: defaults to a `1920 × 1920` pixel box. Preserves aspect ratio and never enlarges small inputs. A zero axis in the options API leaves that axis unconstrained.
- `quality`: defaults to `0.8`, in `0…1`. Controls the tradeoff between image quality and bytes, without implying a fixed perceptual quality percentage or file-size ratio.
- `format`: Automatic, JPEG, PNG or HEIC. Automatic chooses JPEG/PNG for SDR input based on content and actual bytes. When HDR is preserved, Automatic uses HEIC; explicit JPEG and Live stills use gain-map JPEG.
- `backgroundColor`: the background used to flatten transparency for explicit JPEG; nil uses white. Automatic preserves transparent PNG.
- `preservesHDR`: NO by default, converting HDR to SDR and removing gain maps. YES retains source HDR without promoting SDR. JPEG uses a gain map. Automatic selects HEIC for HDR; explicit JPEG and Live use gain-map JPEG. The format option directly selects the encoding, including SDR HEIC when HDR preservation is off. Unsupported HDR PNG or unavailable encoders fail explicitly.
- `preservesAnimation`: YES by default. Compliant GIF is returned unchanged with Automatic output. Animated re-encoding is unsupported. Set to NO to explicitly allow a single frame.

Apps with upload limits should check the actual output size and handle it explicitly.

### Image quality diagnostics

JPEG retains best-effort output when its fidelity target is missed. A compliant original participates in size selection and wins on equality; no source-size trials are added. Read `imageQualityStatus`, `imageRequestedQuality`, `imageEffectiveQualityTarget`, and `imageFidelityScore` after completion. HEIC/HDR uses actual source-relative spatial samples. Original passthrough, unscored PNG and other unscored results are not evaluated, with a nil score. Failure/cancellation does not report fidelity success. JPEG uses at most five encodes: its first search probe shifts toward the high-quality range for stricter fidelity requests, followed by measured interval refinement, without adding size-only encodes. Successful delivery does not imply that the fidelity target was met.

Synchronous callers can also receive diagnostics through options without changing the NSData result:

```swift
options.qualityAssessmentHandler = { status, requested, score in
    if status == .notMet { print("JPEG target missed", requested, score as Any) }
}
```

The callback runs on the image processing queue, which is not necessarily the main queue. Dispatch UI updates yourself. Scores measure the selected image against reference pixels at the target dimensions, not the original full resolution or a percentage of perceived quality. Live Photo still diagnostics describe the selected resource after its last required JPEG write; they do not describe video quality. If final size selection substitutes another still baseline, task diagnostics use its existing assessment, or not evaluated when unavailable. The options callback describes the successful image stage; later Live failures must be checked on the final task. Diagnostics reuse existing scores without additional encoding or pixel scans.

### Image performance statistics

High-level completion exposes an immutable `task.imagePerformance` snapshot. It is nil for video-only tasks or when cancellation prevented the image core from starting. Synchronous callers opt in with `options.performanceHandler`; synchronous calls without that handler do not collect snapshots.

```swift
options.performanceHandler = { performance in
    print(performance.encodingPassCount, performance.outputBytes, performance.stageDurations)
}
```

- `inputBytes` / `outputBytes`: actual input and delivered-image bytes. UIImage input bytes are unknown (0). Failure or cancellation sets delivered bytes to 0 and `succeeded` to false while retaining actual encoding attempts.
- `encodingPassCount` / `encodingCountsByFormat`: ImageIO encoding/write attempts and their actual UTI groups, including discarded candidates and failed attempts. Multiple JPEG candidates are real work, not a single encode.
- `pairingEncodingPassCount`: Live JPEG pairing rewrites, including candidate and baseline resources. Copying an existing matching identifier does not count as encoding. MOV remuxing is not image encoding.
- `stageDurations`: seconds for prepare (identification, decoding, resizing, reference pixels and remaining overhead), encode, evaluate (candidate decoding and existing quality checks), finish (byte selection), pair (JPEG pairing), and total. Stages do not overlap. Live image time excludes video encoding, MOV remuxing, source acquisition, and quality/performance completion callbacks.

Keep the options callback lightweight: its own time is excluded from the snapshot but delays return. It runs on the image processing queue, not necessarily the main queue, for both success and failure once processing has started. For Live Photos the callback already includes JPEG pairing performed for final size selection. The final task snapshot adds only subsequent baseline pairing and updates final bytes and overall success/failure, without double counting. Fidelity scores describe the selected final still assessment. Snapshots retain no pixels, media data or file URLs. Collection adds no encoding, decoding or pixel scans and does not control quality, geometry, formats or size selection. The existing `task.encodingPassCount` still counts video encoding only.

## Compress a video

The output must be a local file URL that does not already exist. These examples assume an AVAsset named `asset`:

```objc
NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
    stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".mp4"]]];

SCCompressionTask *task = [SCMediaCompressor sc_compressVideoAsset:asset outputURL:outputURL
    configure:^(SCVideoCompressor *video) {
        video.maximumSize = CGSizeMake(1280, 1280);
        video.videoQuality = 0.8;
    } progress:nil completion:^(NSURL *url, NSError *error) {
        if (url) {
            // Preview, upload or save; remove successful files when no longer needed.
        }
    }];
```

```swift
let outputURL = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")

let task = SCMediaCompressor.sc_compressVideoAsset(asset, outputURL: outputURL, configure: { video in
    video.maximumSize = CGSize(width: 1280, height: 1280)
    video.videoQuality = 0.8
}, progress: nil) { url, error in
    if let url {
        // Preview, upload or save; remove successful files when no longer needed.
        print(url)
    }
}
```

Defaults are H.264 / MP4 / SDR BT.709, a `1280 × 1280` box, and up to 30fps. Small inputs are not enlarged and lower source frame rates are not increased. Compatible AAC samples are retained; other audio converts to AAC using source channel count and sample rate.

Use the configure block for `timeRange`, `videoBitRate`, `maximumFrameRate`, `videoComposition`, `audioMix` or a rendering delegate. `videoOutputSettings` may configure dimensions and bitrate; provide complete, valid settings. Its codec must match the source-range policy below or fail explicitly. Do not mutate configuration after export starts.

Video `outputFileType` defaults to `AVFileTypeMPEG4`; choose `AVFileTypeQuickTimeMovie` for MOV and match the extension. `preservesHDR` defaults to NO. SDR sources always output H.264/SDR. HDR sources become H.264/SDR when preservation is off, or HEVC Main10/10-bit HLG or PQ when on, in MP4/MOV. There is no separate format-permission or codec selector. HDR preservation rejects 8-bit custom inputs, conflicting explicit codec/color/profile settings, BGRA render delegates and custom compositors; built-in composition, resizing and trimming remain supported.

## Compress a Live Photo

Provide local still/video URLs and an output parent directory. Successful files are created in a unique task-owned child directory:

```swift
let options = SCImageCompressionOptions()
options.maximumSize = CGSize(width: 1920, height: 1920)

let task = SCMediaCompressor.sc_compressLivePhotoImageURL(
    imageURL, videoURL: videoURL,
    outputDirectory: FileManager.default.temporaryDirectory,
    imageOptions: options, configureVideo: nil, progress: nil
) { photoURL, movieURL, error in
    guard let photoURL, let movieURL else {
        print(error?.localizedDescription ?? "Live Photo processing failed")
        return
    }
    // photoURL is JPEG; movieURL is a paired MOV.
    print(photoURL, movieURL)
}
```

Both resources share the image options' `maximumSize`, `quality` and `preservesHDR`, which `configureVideo` cannot override. Both resources share the requested fidelity and effective target, with media-specific encoding and sampling. Each resource preserves aspect ratio and source bounds, so dimensions may differ. Video-specific bitrate, frame rate and audio remain configurable. Final resources are JPEG/MOV, with gain-map JPEG available for HDR stills.

To save to Photos, first obtain the permissions required by your app. Add both files to **one** `PHAssetCreationRequest` and keep them until saving completes:

```swift
import Photos

PHPhotoLibrary.shared().performChanges({
    let request = PHAssetCreationRequest.forAsset()
    request.addResource(with: .photo, fileURL: photoURL, options: nil)
    request.addResource(with: .pairedVideo, fileURL: movieURL, options: nil)
}) { saved, error in
    // Apply your file-cleanup policy after this callback.
}
```

The app supplies photo-library usage descriptions and requests permissions. The library never saves automatically.

## Tasks, files and errors

- Retain the returned `SCCompressionTask`. Call `[task sc_cancel]` in Objective-C or `task.sc_cancel()` in Swift when needed. Cancellation is accepted until the terminal state is locked; later requests have no effect. Failure/cancellation sets `outcome.succeeded` to false, output bytes to 0, savings to nil, fidelity to not evaluated and scores to nil, retaining actual encode counts.
- High-level progress/completion run on the main queue, with one completion callback. Cancellation is cooperative: an in-flight system image encode may finish before it can respond. Video uses Reader/Writer cancellation APIs, which can also take time to cancel and clean up. A request does not mean processing has stopped; wait for completion.
- Inputs remain unchanged. Existing output paths are rejected. The caller owns successful files; failure/cancellation removes only task-owned output and intermediate files.
- The host bounds concurrency. Start with one video task at a time for batch processing.
- Disable logging with `SCMediaCompressor.sc_setLogHandler(nil)`. Custom log handlers run on the producing worker queue.

Errors may come from this library, AVFoundation or the file system. Cancellation uses `NSCocoaErrorDomain / NSUserCancelledError`. In the `SCMediaCompressor` domain, code 1 indicates image input/encoding failure, code 2 indicates task/pairing failure, and code 3 indicates unsupported format/HDR configuration. A lack of size savings returns the compliant baseline successfully. Inspect the error domain, code and description.

## Output behavior and limits

Only completed, actual files participate in size selection. A compressed candidate is used only when strictly smaller than a baseline that satisfies the requested output constraints; otherwise the baseline is returned successfully, including zero savings. The original may be the baseline when its format, geometry, orientation, HDR, transparency, animation and edits already comply. Otherwise a completed required conversion is used. A HEIC-to-JPEG conversion may exceed the HEIC source size; a smaller-than-source result is not guaranteed.

Transparent PNG remains lossless and keeps alpha, selecting the smaller compliant original or encoded file. Preserved GIF is returned unchanged when its dimensions and Automatic output comply; unsupported animation re-encoding still fails. All quality levels use bounded fidelity selection; HEIC/HDR candidates are assessed against actual source content. Required video encoding uses its first completed result as the actual baseline. No extra image encodes or video bitrate retries are added to beat source bytes, and no quality-1 statistics file is generated. Live Photos select each final JPEG/MOV resource under matching pairing conditions.

Ordinary top-level metadata such as creation time does not prevent reuse of a compliant video source. If the candidate is not strictly smaller, a copy of the original is delivered. Explicit `metadata` settings (including an empty array to remove metadata) still require editing and prevent fallback to the unedited source. Original-file passthrough may retain source metadata.

Quality is a source-relative fidelity requirement, in 0…1 with a default of 0.8. Images, videos and Live Photos share `effectiveQualityTarget = 0.95 * quality`, allowing relative tolerance at every level: 1 maps to 0.95 and 0.8 to 0.76. Every encodable level attempts compression, including 1. Encoder settings and measured fidelity are separate: select the smallest completed candidate that meets the output constraints and effective fidelity target within a bounded search. The score is the minimum of mean structural similarity, the lowest local-detail similarity, and color agreement (`1 - mean absolute RGB error / 255`). Thus quality=1 requires all three to reach at least 0.95. It is not a perceptual quality percentage. SDR images compare reference and candidate in the fixed source RGB color space (sRGB for non-RGB sources), avoiding wide-gamut clipping before assessment; candidates do not use their own ICC coordinates for comparison. Ordinary JPEG uses target-size pixels; HEIC/HDR and paired Live JPEG use bounded spatial samples. Live pairing reuses an existing score when final bytes are unchanged; rewritten or unassessed JPEGs are evaluated after pairing. Video uses 3–5 representative temporal/spatial samples, matches the nearest genuine output timestamp, and checks the worst score, without an all-frame guarantee. If no smaller qualifying candidate exists, return a compliant baseline. Required conversions may deliver best effort with an explicit quality miss; unknown or unassessed results never claim a pass. PNG remains lossless, GIF keeps its frames, and compatible AAC samples are preserved. Dimensions, HDR, edits and explicit video bitrate/settings keep their priorities.

After video completion, inspect `videoRequestedQuality`, `videoEffectiveQualityTarget`, `videoQualityStatus`, `videoFidelityScore`, `videoCandidateFidelityScore` and `videoQualitySampleCount`. Returning unchanged baseline content gives a final score of 1 with 0 sampled frames; the discarded candidate score is retained separately, without claiming that candidate passed. `videoQualityEvaluationDuration` is already included in `stageDurations`. The low-level equivalents are `requestedQuality`, `effectiveQualityTarget`, `qualityStatus`, `fidelityScore`, `candidateFidelityScore`, `qualitySampleCount` and `qualityEvaluationDuration`.

Set quality per call through `SCImageCompressionOptions.quality` or an explicit quality parameter. The fixed default is 0.8; no mutable global quality is exposed.

Prefer `task.outcome` for baseline/output bytes, whether the baseline was delivered, savings ratio, fidelity status, and separate image/video encode counts. UIImage and compositions without a local source file have no comparable original bytes; `outcome.baselineBytes` / `task.comparisonBytes == 0` means unknown. `usesConvertedBaseline` identifies a processed, deliverable baseline and does not independently prove a format change. Live comparison baselines are the combined final paired resources; `imageComparisonBytes` / `imageUsesConvertedBaseline` describe the image separately. `videoConversionBytes` records the first completed video conversion. `encodingPassCount` / `videoEncodingPassCount` count video only; image attempts are on `imagePerformance` or `outcome.imageEncodingPassCount`. Library errors use `SCMediaCompressorErrorDomain` and `SCMediaCompressorErrorCode`. Standalone pairing completion receives `(BOOL success, NSError *error)`; the movie header receives only writer and reader. Live pairing failures retain an actual system error in `error.userInfo[NSUnderlyingErrorKey]` when available. Cancellation keeps its existing error. ImageIO failures without an NSError report the pairing stage without inventing an underlying cause.

Image quality controls SDR candidate selection. HDR/explicit HEIC starts at encoder quality `0.6 * effectiveQualityTarget`, then measures actual spatial samples. Automatic video bitrate uses `0.85 * quality` as its initial budget factor, leaving compression headroom even at the highest level; measured output samples determine fidelity. Size selection does not add bitrate reductions to beat source bytes or change the requested quality. Compression ratios vary with content. Videos default to SDR, with opt-in preservation of 10-bit HLG/PQ pixels and colors; preservation of per-frame Dolby Vision dynamic metadata is not guaranteed. HDR image/video preservation depends on the format, OS and actual encoder; unsupported requests return an error. HDR PNG is unsupported.

Validate representative inputs for formats, dimensions, bytes and playback. Check camera image quality, Dolby Vision and saved Live Photo playback on a real device; simulator codecs can differ.

## Examples and Demo

See [Examples](Examples) for Objective-C and Swift usage. Run the standalone Demo:

```sh
cd Demo
pod install
open SCMediaCompressorDemo.xcworkspace
```

The compact Demo exposes separate image/Live and ordinary-video HDR switches, image formats and ordinary-video format selection (MP4/MOV). Encoding follows the actual source range automatically, retaining H.264/MP4/SDR defaults. Live shares image dimensions, quality and HDR and still outputs MOV. It supports image, video and Live Photo selection, configuration and cancellation. It shows progress followed by source files, any actual required conversion, and compression/pairing results with real bytes, dimensions, encoding counts and timings. The conversion section is omitted when no conversion occurs. Save results to Photos or open a separate image, video or Live Photo preview using the buttons below; previews load only on request.

## License

[MIT License](LICENSE). See [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md) for third-party attribution and licenses.


## Minimal issue reproduction

1. Run `pod install --no-repo-update` inside `Demo`, open `SCMediaCompressorDemo.xcworkspace` in Xcode, and run on an iOS 15+ device or simulator. Verify the resolved dependency for the same Git installation method before comparing results.
2. Use shareable synthetic or sanitized files. Record media kind, actual codec, bytes, dimensions, duration, HDR, animation and audio. Keep both matching resources for Live Photos. Do not submit private albums or credentials.
3. Record size, quality, format, HDR, animation and advanced video settings. Select the input in the Demo, compress, and capture the actual report. For cancellation, record when it was requested. Describe save/preview actions separately; compression completion does not mean saving succeeded.
4. For API reproduction, read `task.outcome` in completion. Use separate image/video diagnostics for conversions and `imagePerformance` / `stageDurations` for detailed work. Record error domain, code, description and available `NSUnderlyingErrorKey` chain; remove private paths and content before sharing logs.

Include the dependency declaration and resolved version/commit, Xcode/iOS version, device or simulator, input details and settings, minimal steps, expected/actual results, and shareable files or generation steps. Verify actual HDR encoder capability and captured Live Photo save/playback on supported hardware; label simulator results separately.
