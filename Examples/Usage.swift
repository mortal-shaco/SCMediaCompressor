import UIKit
import AVFoundation
import SCMediaCompressor

/// 展示 Swift 直接调用公共 Objective-C 核心。
/// - Parameters:
///   - data: 原始图片数据。
///   - asset: 视频素材。
///   - imageURL: Live 原始图片文件。
///   - videoURL: Live 原始配对视频文件。
///   - parent: 输出父目录。
func sc_example(data: Data, asset: AVAsset, imageURL: URL, videoURL: URL, parent: URL) {
    // options：静态图和 Live 视频唯一的尺寸配置来源。
    let options = SCImageCompressionOptions()
    options.maximumSize = CGSize(width: 1920, height: 1920)
    // 按次设置质量，不依赖全局可写质量。
    options.quality = 0.8
    // 直接选择输出格式，HDR 默认转 SDR。
    options.format = .automatic
    options.preservesHDR = false
    // 诊断回调在处理队列；未评估时 score 为 nil，不代表评分失败。
    options.qualityAssessmentHandler = { status, requested, score in
        if status == .notMet { print("图片未达目标", requested, score as Any) }
    }
    // 同步接口设置此回调后收集统计；高层任务还可在完成后读 imagePerformance。
    options.performanceHandler = { performance in
        print("image encodes", performance.encodingPassCount, "bytes", performance.outputBytes, performance.stageDurations)
    }
    // quality 是实际一致度要求，有效目标为 0.95×quality；结构、细节、颜色取最低，所有档均尝试压缩。
    // 压缩候选严格小于合规基线才采用，否则成功返回基线；UIImage 字节未知。
    // 不为体积追加编码或降低请求质量；图片及视频按实际评分报告，视频仅作代表性抽样。
    // comparisonBytes 为实际比较基线；视频必要编码转换使用首次完成的实际结果，0 表示未知。
    // 合规视频未变小则返回原文件副本；普通创建时间不阻止回退，显式 metadata 编辑仍须执行。
    // 视频读取 videoQualityStatus / videoFidelityScore / videoQualitySampleCount；回退原内容与候选评分分开。
    // videoConversionBytes 保存首次实际视频转换字节；encodingPassCount 包含必要转换及系统瞬态重试。
    // imageComparisonBytes / imageUsesConvertedBaseline 仅描述图片，不使用 Live 整组统计推断图片转换。
    // imageTask：回调内读取 outcome，需在赋值前声明。
    var imageTask: SCCompressionTask?
    imageTask = SCMediaCompressor.sc_compressImageData(data, options: options, progress: nil) { result, error in
        if let error, (error as NSError).domain == SCMediaCompressorErrorDomain {
            print("library error", (error as NSError).code, "underlying", (error as NSError).userInfo[NSUnderlyingErrorKey] as Any)
        }
        // result：成功编码数据；优先读 outcome 看基线与节省。
        if let result {
            print(SCImageCompressor.sc_mimeType(for: result), imageTask?.outcome?.baselineBytes as Any, imageTask?.outcome?.savedRatio as Any)
        }
        imageTask = nil
    }
    _ = imageTask
    // output：未占用的视频路径。
    let output = parent.appendingPathComponent(UUID().uuidString + ".mp4")
    // videoTask：完成后读取最终保真诊断，回调结束释放示例持有。
    var videoTask: SCCompressionTask?
    videoTask = SCMediaCompressor.sc_compressVideoAsset(asset, outputURL: output, configure: { video in
        // video：必要转换复用真实结果为基线，允许比源文件大。
        // 显式码率、完整编码设置和自定义渲染/合成/混音不因体积择小而修改或重放。
        video.maximumSize = CGSize(width: 1280, height: 1280)
        video.videoQuality = 0.8
        video.preservesHDR = false
        video.outputFileType = .mp4
        // SDR 源始终 H264；HDR 源开启 preservesHDR 后自动使用 HEVC Main10。
        // MOV 使用 .mov 并匹配输出扩展名；Live 最终视频固定 MOV。
    }, progress: nil) { url, error in
        // url：成功文件，由调用方清理；error：失败原因。
        if url != nil, let videoTask {
            print("video outcome saved", videoTask.outcome?.savedRatio as Any,
                  "encodes", videoTask.outcome?.videoEncodingPassCount as Any,
                  "score", videoTask.outcome?.videoFidelityScore as Any)
        }
        videoTask = nil
    }
    SCMediaCompressor.sc_compressLivePhotoImageURL(imageURL, videoURL: videoURL, outputDirectory: parent, imageOptions: options, configureVideo: nil, progress: nil) { photo, movie, error in
        if let error {
            let failure = error as NSError
            print("Live error", failure.domain, failure.code, "underlying", failure.userInfo[NSUnderlyingErrorKey] as Any)
        }
        // Live 采用 options 的尺寸、quality、preservesHDR，configureVideo 不能覆盖。
        // photo、movie：配对 JPEG/MOV，保存完成后再清理。
    }
}
