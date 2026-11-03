# SCMediaCompressor

[English](README.en.md) · iOS 15+ · Objective-C / Swift · MIT

SCMediaCompressor 是一个 iOS 图片、视频和 Live Photo 压缩库。它使用 Apple 系统框架，提供统一的异步接口、进度回调、取消操作和 Live Photo 配对，WebP 编码依赖 libwebp。

## 功能

- 图片：按像素边界等比缩小，支持 JPEG、PNG、HEIC 和 WebP 输出，处理方向与透明背景。
- 视频：默认输出 H.264 / MP4 / SDR，支持尺寸、帧率、码率、裁剪、混音及自定义渲染。
- Live Photo：压缩静态图与视频，返回配对的 JPEG / MOV 文件。
- 任务：后台处理，主队列交付高层进度与完成回调，可请求取消。
- 体积保护：对有实际文件基准的输入比较最终字节数，在输出配置允许时保留较小结果。

库负责媒体处理。相册选择、iCloud 下载、权限、上传和界面由接入应用管理。

## 安装

通过 CocoaPods 安装：

若较新 Xcode 提示 libwebp 的 iOS 9 部署目标不受支持，将 Pods 的最低部署版本统一到 iOS 15；参见 [Demo 的 post_install 配置](Demo/Podfile)。

WebP 使用软件编码。Debug 集成时请为 `libwebp` 开启编译优化（例如 `GCC_OPTIMIZATION_LEVEL = 2`）；`-O0` 会显著增加编码耗时。可将 [Demo 的 post_install 配置](Demo/Podfile) 中仅针对 libwebp Debug 的优化分支合并到应用既有 post_install 中，再执行 `pod install` 并重新构建；该设置只针对 libwebp 依赖，podspec 中压缩核心的优化设置不会传递给依赖。

使用固定 Git 标签安装 1.1.0：

```ruby
platform :ios, '15.0'
pod 'SCMediaCompressor', :git => 'https://github.com/mortal-shaco/SCMediaCompressor.git', :tag => '1.1.0', :modular_headers => true
```

如需跟随最新公开代码，可将 `:tag => '1.1.0'` 替换为 `:branch => 'main'`。执行 `pod install` 后打开项目的 `.xcworkspace`。

```objc
#import <SCMediaCompressor/SCMediaCompressor.h>
```

```swift
import SCMediaCompressor
```

基本功能要求 iOS 15 或以上。开启 HDR 后能否保留还取决于系统编码器；保留 HDR 的跨格式转换和 HDR UIImage 缩放要求 iOS 18 或以上，普通图片显式格式可在能力不足时输出同格式 SDR。

## 压缩图片

优先使用原始图片数据入口，便于保留准确的输入字节信息。

```objc
SCImageCompressionOptions *options = [SCImageCompressionOptions new];
options.maximumSize = CGSizeMake(1920, 1920);
options.quality = 0.8;

SCCompressionTask *task = [SCMediaCompressor sc_compressImageData:inputData
    options:options progress:^(double progress) {
        // 更新界面进度。
    } completion:^(NSData *data, NSError *error) {
        if (error) {
            NSLog(@"%@", error.localizedDescription);
            return;
        }
        NSString *mimeType = [SCImageCompressor sc_mimeTypeForData:data];
        // 文件扩展名也应依据实际输出编码。
        NSLog(@"%@, %lu bytes", mimeType, (unsigned long)data.length);
    }];
```

```swift
let options = SCImageCompressionOptions()
options.maximumSize = CGSize(width: 1920, height: 1920)
options.quality = 0.8

let task = SCMediaCompressor.sc_compressImageData(inputData, options: options, progress: { progress in
    // 更新界面进度。
}) { data, error in
    guard let data else {
        print(error?.localizedDescription ?? "图片处理失败")
        return
    }
    print(SCImageCompressor.sc_mimeType(for: data), data.count)
}
```

已有 UIImage 时可使用 `sc_compressImage:options:progress:completion:`。同步接口由 `SCImageCompressor` 提供，大图处理应放到后台队列。

### 图片配置

- `maximumSize`：默认 `1920 × 1920` 像素边界。按宽高比缩小，小图不放大；配置接口中单轴为 0 表示该轴不限制。
- `quality`：默认 `0.8`，范围 `0…1`。控制图片质量与体积的取舍，不能换算为固定的主观清晰度百分比或文件大小比例。
- `format`：默认 Automatic；可选 JPEG、PNG、HEIC、WebP。Automatic 的 SDR 路径根据内容与实际编码结果选择 JPEG/PNG；HDR 路径见 preservesHDR。
- `backgroundColor`：显式 JPEG 输出时的透明内容背景色，nil 使用白色。Automatic 保留透明 PNG。
- `preservesHDR`：默认 NO，输出 SDR，不保留输入 HDR 或增益图。开启后才尽力保留 HDR，不把 SDR 提升为 HDR。普通图片显式格式优先：PNG/WebP 始终输出 SDR；JPEG/HEIC 先尝试保留 HDR，系统 HDR 能力不足时输出同格式 SDR，已有合规 HDR 原文件可直接参与择小。Automatic 在实际支持 HDR 保留的 HEIC、增益图 JPEG 候选中先判硬约束和保真资格，再按真实体积择小；全部不可用且无合规原文件时明确失败。Live 继续遵守共享 HDR 配对要求。无效输入、取消、真实编码或文件错误仍明确失败。
- `WebP`：通过 libwebp 输出静态 SDR WebP（CocoaPods 自动安装依赖），保留透明度与 ICC 色域描述；最多五次有界编码，按实际保真评分及字节择小。WebP 单轴上限为 16383 像素，超限明确失败；开启 HDR 时也按指定格式输出 SDR，不支持动画重编码。Live Photo 仍固定 JPEG/MOV。
- `preservesAnimation`：默认 YES，不丢动画帧。保帧 GIF 符合尺寸与 Automatic 输出时原样返回；需要动画重编码时不支持。设为 NO 可显式允许单帧压缩。

需要上传大小限制的应用，应检查实际输出字节数并自行决定后续操作。

指定 WebP 输出：

```objc
SCImageCompressionOptions *options = [SCImageCompressionOptions new];
options.format = SCImageFormatWebP;
options.preservesHDR = YES; // 开启后才尽力保留；WebP 按指定格式输出 SDR。
NSData *webp = [SCImageCompressor sc_compressData:data options:options error:&error];
```

```swift
let options = SCImageCompressionOptions()
options.format = .webP
options.preservesHDR = true // WebP 按指定格式输出 SDR；false 同样输出 SDR。
let webp = try SCImageCompressor.sc_compressData(data, options: options)
```

自动保留 HDR 并择优选择实际可用格式：

```swift
let options = SCImageCompressionOptions()
options.format = .automatic
options.preservesHDR = true
let result = try SCImageCompressor.sc_compressData(data, options: options)
```

每种 HDR 格式执行既有有界编码，不为小于源文件追加尝试；编码器不可用或无法实际保留 HDR 的格式不参与择优。全部不可用且没有合规原文件时明确失败。透明度等硬约束始终优先；没有达标候选且必须转换时仍可能交付已评分的尽力结果。UIImage 的原文件基准仍为未知，SDR 默认行为不变。

### 图片质量诊断

JPEG 达不到请求的质量目标时仍允许尽力输出；合规原文件参与择小，等大返回原文件，不为源体积目标追加编码。高层任务的 `imageQualityStatus`、`imageRequestedQuality`、`imageEffectiveQualityTarget` 与 `imageFidelityScore` 区分已达标、未达标、未评估。HEIC/HDR 使用实际源内容空间采样；原文件透传、未评分 PNG 等结果为未评估且分数 nil，失败或取消不报告达标。成功不等于质量目标达成。

同步接口也可通过配置接收诊断，不改变原有 NSData 返回值：

```objc
CGFloat effectiveTarget = options.effectiveQualityTarget;
options.qualityAssessmentHandler = ^(SCImageQualityStatus status, CGFloat requested, NSNumber *score) {
    if (status == SCImageQualityStatusNotMet) {
        NSLog(@"JPEG score %@ is below %.2f; a usable image was returned", score, effectiveTarget);
    }
};
```

该回调在图片实际处理队列调用，不保证主线程；更新 UI 请自行切换队列。评分描述目标参考下所选图片的实际误差，不是原始全分辨率或主观画质百分比。Live Photo 的图片诊断描述最后一次必要 JPEG 写入后选中的资源，不代表视频质量；最终择小改选其他图片基准时，任务诊断更新为该基准已有评分，没有评分则为未评估。配置回调描述图片阶段成功结果，Live 后续整体失败时以最终任务状态为准。诊断复用已有评分，不额外编码或扫描。

### 图片性能统计

高层任务在完成回调前提供不可变的 `task.imagePerformance` 快照；视频任务或取消前尚未进入图片内核时为 nil。同步入口可通过 `options.performanceHandler` 接收统计；未设置该回调的同步调用不收集性能快照。

```objc
options.performanceHandler = ^(SCImagePerformance *performance) {
    NSLog(@"encodes=%lu bytes=%llu stages=%@", (unsigned long)performance.encodingPassCount,
          performance.outputBytes, performance.stageDurations);
};
```

- `inputBytes` / `outputBytes`：实际输入和交付图片字节；UIImage 的输入字节未知为 0。失败或取消的交付字节为 0，`succeeded` 为 NO，已发生的编码尝试仍保留。
- `encodingPassCount` / `encodingCountsByFormat`：实际开始的 ImageIO/libwebp 编码/写入次数及其 UTI 分组，包含未选中的候选和失败尝试；例如 JPEG 多候选搜索不能误读为只编码一次。
- `pairingEncodingPassCount`：Live 的 JPEG 配对重写次数，包含候选和基准；相同配对 ID 的原字节复制不计编码，MOV 重封装不计图片编码。
- `stageDurations`：秒，包含 prepare（识别/解码/缩放/参考像素及其余开销）、encode、evaluate（候选解码与已有质量评分）、finish（字节择小）、pair（JPEG 配对）和 total。各阶段不重叠；Live 的图片累计时间不包含视频编码、MOV 封装、取源及质量/性能完成回调。

配置回调在图片处理队列执行，不保证主线程，应保持轻量；回调本身虽不计入性能快照，但耗时会延迟调用返回。成功和失败均会返回已启动处理的统计。Live 的配置回调已包含为最终字节择小执行的 JPEG 配对；最终任务快照只追加后续基线配对，并更新最终字节和整组成功/失败状态，不重复累计。保真评分描述最终选中静态资源的实际评估。快照不保存像素、媒体数据或文件 URL，不额外编码、解码或扫描，不改变质量/尺寸/格式/体积择小。原有 `task.encodingPassCount` 仍只统计视频。

## 压缩视频

输出地址必须是未被占用的本地文件路径。以下示例假设 `asset` 为待处理的 AVAsset：

```objc
NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
    stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".mp4"]]];

SCCompressionTask *task = [SCMediaCompressor sc_compressVideoAsset:asset outputURL:outputURL
    configure:^(SCVideoCompressor *video) {
        video.maximumSize = CGSizeMake(1280, 1280);
        video.videoQuality = 0.8;
    } progress:nil completion:^(NSURL *url, NSError *error) {
        if (url) {
            // 预览、上传或保存；使用结束后清理成功输出。
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
        // 预览、上传或保存；使用结束后清理成功输出。
        print(url)
    }
}
```

默认输出为 H.264 / MP4 / SDR BT.709，尺寸边界 `1280 × 1280`，最高 30fps。不放大小源，也不主动提高源帧率。默认保留兼容 AAC；其他音频按源声道和采样率转换为 AAC。

在 configure 中可以设置 `timeRange`、`videoBitRate`、`maximumFrameRate`、`videoComposition`、`audioMix` 和渲染代理。`videoOutputSettings` 可配置尺寸与码率，调用方应提供完整、有效的参数；编码必须符合下面的源动态范围策略，冲突明确失败。导出开始后不要再修改配置。

视频 `outputFileType` 默认 `AVFileTypeMPEG4`，可选 `AVFileTypeQuickTimeMovie`（MOV），扩展名应与容器一致。`preservesHDR` 默认 NO：SDR 源始终输出 H.264/SDR；HDR 源关闭保留时转 H.264/SDR，开启时输出 HEVC Main10/10-bit HLG 或 PQ，支持 MP4/MOV。没有额外的格式许可或编码选择开关。8-bit 自定义输入、冲突的显式编码/颜色/profile、BGRA 渲染代理或自定义合成器不支持 HDR 保留，会明确失败；内置合成、尺寸和裁剪仍适用。

## 压缩 Live Photo

传入本地静态图与配对视频 URL，以及一个输出父目录。成功结果位于本次任务创建的独立子目录中：

```swift
let options = SCImageCompressionOptions()
options.maximumSize = CGSize(width: 1920, height: 1920)

let task = SCMediaCompressor.sc_compressLivePhotoImageURL(
    imageURL, videoURL: videoURL,
    outputDirectory: FileManager.default.temporaryDirectory,
    imageOptions: options, configureVideo: nil, progress: nil
) { photoURL, movieURL, error in
    guard let photoURL, let movieURL else {
        print(error?.localizedDescription ?? "Live Photo 处理失败")
        return
    }
    // photoURL 为 JPEG，movieURL 为已配对的 MOV。
    print(photoURL, movieURL)
}
```

静态图与视频共用图片配置的 `maximumSize`、`quality` 和 `preservesHDR`，`configureVideo` 不能覆盖这三项；两者共用保真请求及有效门槛，编码和采样方式按媒体类型执行。两者各自保持比例、受源尺寸限制，不要求相同像素数。视频专属码率、帧率、音频等可独立配置，最终配对固定为 JPEG/MOV，JPEG 可通过增益图保留 HDR。

如需保存到相册，在获得应用所需权限后，把两个文件加入**同一个** `PHAssetCreationRequest`，并在保存完成前保留它们：

```swift
import Photos

PHPhotoLibrary.shared().performChanges({
    let request = PHAssetCreationRequest.forAsset()
    request.addResource(with: .photo, fileURL: photoURL, options: nil)
    request.addResource(with: .pairedVideo, fileURL: movieURL, options: nil)
}) { saved, error in
    // 此时再按应用的文件管理策略清理 photoURL 与 movieURL。
}
```

应用负责配置相册用途说明并申请权限；库不会自动保存媒体。

## 任务、文件与错误

- 保存返回的 `SCCompressionTask`，需要时调用 Objective-C 的 `[task sc_cancel]` 或 Swift 的 `task.sc_cancel()`。
- 高层进度和完成回调位于主队列，完成回调只交付一次。取消采用协作方式：单次系统图片编码可能需要结束后才响应；视频使用 Reader/Writer 取消接口，取消和清理也可能需要等待。取消请求不代表处理已经停止，以完成回调为准。终态锁定前接受取消；锁定后取消不再生效。失败或取消的 `outcome` 报告 `succeeded=NO`、交付字节 0、节省比例 nil、保真未评估且评分 nil，保留实际编码次数。
- 原始文件保持不变；已有输出路径会被拒绝。成功文件由调用方管理，失败或取消只清理本次任务拥有的输出和中间文件。
- 同时处理的任务数量由应用控制。批量视频建议先从单任务串行处理开始。
- 可通过 `SCMediaCompressor.sc_setLogHandler(nil)` 关闭日志；自定义接收器在产生消息的工作队列调用。

错误可能来自本库、AVFoundation 或文件系统。取消使用 `NSCocoaErrorDomain / NSUserCancelledError`；`SCMediaCompressor` 错误码 1 表示图片输入或编码失败，2 表示高层任务/配对失败，3 表示不支持的格式/HDR 配置。没有体积收益时正常返回合规基线。请以 error 的 domain、code 和说明处理具体失败。

## 输出与适用边界

图片与视频只比较已经完成写入的真实文件：压缩候选严格小于合规比较基线时采用，否则成功返回基线，允许零体积收益。原文件符合本次格式、尺寸、方向、HDR、透明度、动画及编辑要求时可以直接作为基线；不符合时使用实际必要转换结果，不能返回格式错误或未完成编辑的原文件。HEIC 转 JPEG 等必要转换允许比源文件大，不承诺最终文件一定小于源文件。

透明 PNG 保持无损及透明度，在原文件与合规编码结果中择小；保帧 GIF 符合尺寸与 Automatic 输出时直接返回原始动画，不因无法缩小报错。需要动画重编码仍明确失败。图片所有质量档均执行有界保真选择，HEIC/HDR 候选按实际源内容评估；视频必要编码转换复用首次实际结果作为比较基线。不为小于源文件追加图片编码或视频降码率重试，不生成统计专用的质量 1 文件。Live 使用相同配对条件下的最终 JPEG/MOV 实际字节逐资源择小。

普通视频已满足输出约束时，创建时间等普通顶层元数据不会阻止复用原文件；候选没有严格变小就交付原文件的副本。显式设置 `metadata`（包括空数组清除）仍会执行编辑，不能回退到未编辑源文件。原文件透传可能保留原有元数据。

quality 是相对源内容的保真要求，范围 0…1、默认 0.8。图片、视频和 Live Photo 统一使用 `effectiveQualityTarget = 0.95 × quality`，每档都有相对容差：1→0.95、0.8→0.76。所有可编码档位都尝试压缩，包括 1；编码参数与实测保真分数分开，在有界候选中选择满足硬约束、保真目标且实际更小的结果。分数取平均结构相似度、局部细节最低相似度、颜色一致度三项中的最小值；颜色一致度为 `1 − 平均 RGB 绝对误差 / 255`。因此 quality=1 要求这三项均至少为 0.95；该分数不是主观画质百分比。SDR 图片在固定源 RGB 色域中比较参考与候选（非 RGB 源回退 sRGB），避免评分前裁剪宽色域；候选不会改用自己的 ICC 坐标自比较。普通 JPEG 评估目标尺寸像素，HEIC/HDR/Live JPEG 进行有界空间采样；Live 配对后字节未变且已有评分时复用原评分，实际重写或未评分时才评估最终 JPEG。视频进行 3–5 帧代表性时空采样，按真实输出时间戳匹配最近帧并检查最差样本，不承诺全帧保证。SDR JPEG 搜索最多五次编码，HDR 开启时因能力不足产生的失败尝试另计；首个搜索点随保真目标向高质量区间偏移，再按实际评分细分，不为体积追加编码。没有更小且达标的候选时返回合规基线；必要转换无法达标时成功交付尽力结果并明确未达标，未知与未评估不伪装为达标。PNG 保持无损、GIF 保帧，兼容 AAC 保留原采样；尺寸、HDR、编辑、显式码率/编码设置保持原优先级。

视频完成后可读取 `videoRequestedQuality`、`videoEffectiveQualityTarget`、`videoQualityStatus`、`videoFidelityScore`、`videoCandidateFidelityScore` 和 `videoQualitySampleCount`。候选未达标后回退原内容时，最终分数为 1、样本数为 0，落选候选分数单独保留；这不是声称候选抽样达标。`videoQualityEvaluationDuration` 已包含在 `stageDurations`，不要重复相加。低层视频对应 `requestedQuality`、`effectiveQualityTarget`、`qualityStatus`、`fidelityScore`、`candidateFidelityScore`、`qualitySampleCount`、`qualityEvaluationDuration`。

质量通过按次 `SCImageCompressionOptions.quality` 或显式 quality 参数设置，默认固定为 0.8；不提供全局可写质量。

优先读取 `task.outcome`：一次给出基线/交付字节、是否回退基线、节省比例、图片与视频保真状态及各自编码次数。UIImage 和没有本地原文件的组合素材缺少可比较的原始字节数，`outcome.baselineBytes` / `task.comparisonBytes` 为 0 表示基准未知。`usesConvertedBaseline` 表示使用了已处理的可交付基准，可包含格式、HDR、几何或编辑处理，不能单独据此认定格式改变。Live 的比较基线是最终配对资源的合计；图片自身统计另见 `imageComparisonBytes` / `imageUsesConvertedBaseline`。`videoConversionBytes` 保存首次必要视频转换的实际字节。`encodingPassCount` / `videoEncodingPassCount` 只统计视频；图片次数见 `imagePerformance` 或 `outcome.imageEncodingPassCount`。本库错误域为 `SCMediaCompressorErrorDomain`，码见 `SCMediaCompressorErrorCode`。独立配对工具的完成回调为 `(BOOL success, NSError *error)`，MOV 的 header 仅提供 writer 和 reader。Live 配对失败在系统提供错误时通过 `error.userInfo[NSUnderlyingErrorKey]` 保留原始原因；取消仍使用原有取消错误，ImageIO 未提供 NSError 时只报告配对阶段失败，不伪造底层错误。

图片质量配置作用于 SDR 候选筛选，HDR/显式 HEIC 以 `0.6 × effectiveQualityTarget` 为单次编码初值，再评估实际空间采样；视频自动候选码率以 `0.85 × quality` 为预算系数，最高档也预留压缩空间，保真由输出抽样评分判断；不因源文件体积追加降码率编码，quality 属性值保持不变。不同素材的压缩幅度会不同。视频默认 SDR，可显式保留 HLG/PQ 的 10-bit 像素与色彩，不承诺保留 Dolby Vision 逐帧动态元数据；只有开启 HDR 时才尝试保留，能否保留取决于格式、系统和实际编码器；普通图片显式格式可同格式转 SDR，Automatic、Live 和视频仍按各自 HDR 约束明确报告不支持。PNG/WebP 不保留 HDR，普通图片显式指定这两种格式时输出 SDR。

实际集成时请使用有代表性的素材验证格式、尺寸、体积和播放效果。实拍观感、Dolby Vision 与 Live Photo 保存播放应在真机核对，模拟器的编码能力可能不同。

## 示例与 Demo

完整 Objective-C / Swift 示例见 [Examples](Examples)。运行独立 Demo：

```sh
cd Demo
pod install
open SCMediaCompressorDemo.xcworkspace
```

Demo 提供图片/Live 与普通视频两个 HDR 开关、图片格式及普通视频格式（MP4/MOV）选择；编码按实际源动态范围自动决定，默认仍为 H.264/MP4/SDR。Live 的质量、尺寸和 HDR 均跟随图片，最终视频固定 MOV。支持选择图片、视频和 Live Photo、调整配置和取消任务。紧凑主页面依次显示进度、原始文件、实际发生的必要转换、压缩及配对结果（真实字节、尺寸、编码与耗时）；没有转换时省略转换阶段。下方可手动保存相册，或打开独立页面预览压缩图片、视频及 Live Photo，不自动加载预览。

## 许可证

采用 [MIT License](LICENSE)。第三方来源与许可见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md)。


## 最短问题复现

1. 在 `Demo` 目录执行 `pod install --no-repo-update`，用 Xcode 打开 `SCMediaCompressorDemo.xcworkspace`，选择 iOS 15 或更高版本设备/模拟器运行；使用 README 同一种 Git 安装方式确认依赖解析后再比较结果。
2. 用可公开的合成或脱敏文件复现，记录图片/视频/Live 类型、实际编码、字节、尺寸、时长与 HDR/动画/音轨情况。Live 需保留同一组静态图和视频，勿提交私人相册或凭据。
3. 记录尺寸、quality、格式、HDR、动画及视频高级配置；从 Demo 手动选择输入，点击压缩，抄录实际结果。取消问题注明点击时机；保存/预览问题另记相应操作和错误，不把压缩完成等同保存成功。
4. 使用示例 API 复现时，在完成回调读取 `task.outcome`；转换原因使用图片/视频独立诊断，性能细节使用 `imagePerformance` 和 `stageDurations`。记录错误的 domain、code、说明及可用的 `NSUnderlyingErrorKey` 错误链；不要上传含私人路径或内容的完整日志。

反馈请包含：依赖安装写法及实际解析版本/提交、Xcode/iOS 版本、设备或模拟器、上述输入和配置、最短操作步骤、预期与实际结果，以及可共享的复现文件或生成方式。真实 HDR 编码能力、实拍 Live 保存播放应在支持的真机复核，模拟器结果单独标明。
