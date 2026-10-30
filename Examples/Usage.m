#import <SCMediaCompressor/SCMediaCompressor.h>
/// 展示图片、视频及 Live Photo 的统一异步入口。
/// 从主线程调用，确保任务赋值先于主队列完成回调。
/// @param data 原始图片数据。
/// @param asset 普通视频素材。
/// @param imageURL Live 原始图片文件。
/// @param videoURL Live 原始配对视频文件。
/// @param parent 调用方拥有的输出父目录。
void sc_example(NSData *data, AVAsset *asset, NSURL *imageURL, NSURL *videoURL, NSURL *parent) {
    // options：图片和 Live 视频共用的按次配置，不依赖全局可写质量。
    SCImageCompressionOptions *options=[SCImageCompressionOptions new];
    options.maximumSize=CGSizeMake(1920,1920);options.quality=0.8;
    // 直接选择输出格式；HDR 默认转 SDR，JPEG 也可通过增益图保留 HDR。
    options.format=SCImageFormatAutomatic;options.preservesHDR=NO;
    // 质量诊断复用已有评分；回调在处理队列，更新界面需自行转到主队列。
    options.qualityAssessmentHandler=^(SCImageQualityStatus status,CGFloat requested,NSNumber *score){
        if(status==SCImageQualityStatusNotMet)NSLog(@"图片未达保真目标：quality 请求 %.2f，评分 %@，仍交付可用图片",requested,score);
    };
    // 性能回调与质量回调相同，在处理队列执行；失败时仍保留真实编码尝试。
    options.performanceHandler=^(SCImagePerformance *performance){
        NSLog(@"image encodes=%lu output=%llu stages=%@",(unsigned long)performance.encodingPassCount,performance.outputBytes,performance.stageDurations);
    };
    // quality 是实际一致度要求，有效目标为 0.95×quality；结构、细节、颜色取最低，所有档均尝试压缩。
    // 压缩候选严格小于合规基线才采用，否则成功返回基线；UIImage 字节未知。
    // 不为体积追加编码或降低请求质量；图片及视频按实际评分报告，视频仅作代表性抽样。
    // comparisonBytes 为实际比较基线；视频必要编码转换使用首次完成的实际结果，0 表示未知。
    // 合规视频未变小则返回原文件副本；普通创建时间不阻止回退，显式 metadata 编辑仍须执行。
    // 视频读取 videoQualityStatus / videoFidelityScore / videoQualitySampleCount；回退原内容与候选评分分开。
    // videoConversionBytes 保存首次实际视频转换字节；encodingPassCount 包含必要转换及系统瞬态重试。
    // imageComparisonBytes / imageUsesConvertedBaseline 仅描述图片，不使用 Live 整组统计推断图片转换。
    // task：按需保存以支持页面关闭时取消。
    __block SCCompressionTask *task=nil;
    task=[SCMediaCompressor sc_compressImageData:data options:options progress:nil completion:^(NSData *result,NSError *error){
        // result：真实编码图片；error：失败或取消原因；优先读 outcome 摘要。
        if(error && [error.domain isEqualToString:SCMediaCompressorErrorDomain]) NSLog(@"library error %ld underlying=%@", (long)error.code,error.userInfo[NSUnderlyingErrorKey]);
        if(result) NSLog(@"%@ baseline=%llu saved=%@",[SCImageCompressor sc_mimeTypeForData:result],task.outcome.baselineBytes,task.outcome.savedRatio);
        task=nil;
    }];
    (void)task;
    // output：必须未占用，成功后由调用方清理。
    NSURL *output=[parent URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".mp4"]];
    // videoTask：完成后读取最终评分与有效门槛，回调结束释放示例持有。
    __block SCCompressionTask *videoTask=nil;
    videoTask=[SCMediaCompressor sc_compressVideoAsset:asset outputURL:output configure:^(SCVideoCompressor *video){
        // video：编码前配置；必要转换复用真实结果为基线，允许比源文件大。
        // 显式码率、完整编码设置和自定义渲染/合成/混音不因体积择小而修改或重放。
        video.maximumSize=CGSizeMake(1280,1280);video.videoQuality=0.8;
        video.preservesHDR=NO;video.outputFileType=AVFileTypeMPEG4;
        // SDR 源始终 H264；HDR 源开启 preservesHDR 后自动使用 HEVC Main10。
        // MOV 使用 AVFileTypeQuickTimeMovie，并把 output 扩展名改为 .mov；Live 最终固定 MOV。
    } progress:nil completion:^(NSURL *url,NSError *error){
        // url：成功输出；error：失败原因；抽样数为 0 且评分为 1 表示原内容回退。
        if(url)NSLog(@"video outcome saved=%@ encodes=%lu score=%@",videoTask.outcome.savedRatio,(unsigned long)videoTask.outcome.videoEncodingPassCount,videoTask.outcome.videoFidelityScore);
        videoTask=nil;
    }];
    [SCMediaCompressor sc_compressLivePhotoImageURL:imageURL videoURL:videoURL outputDirectory:parent imageOptions:options configureVideo:nil progress:nil completion:^(NSURL *photo,NSURL *movie,NSError *error){
        if(error)NSLog(@"Live error %@/%ld underlying=%@",error.domain,(long)error.code,error.userInfo[NSUnderlyingErrorKey]);
        // Live 共用 options 的尺寸、quality 与 preservesHDR；视频专属参数单独配置。
        // photo、movie：同一配对 ID 的 JPEG/MOV，保存结束后再删除。
    }];
}
