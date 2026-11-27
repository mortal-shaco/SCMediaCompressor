#import "SCMediaCompressor.h"
#import "SCInternal.h"
#import "SCImageCodec.h"
#import "SCSizePolicy.h"
#import "SCLogger.h"
#import "SCMediaCompressorError.h"

/// 将系统取消错误与可读的失败原因统一为本库错误。
/// @param message 面向调用方的失败说明。
/// @param cancelled 是否由取消请求导致。
static NSError *sc_taskError(NSString *message, BOOL cancelled) {
    return [NSError errorWithDomain:cancelled ? NSCocoaErrorDomain : SCMediaCompressorErrorDomain
                              code:cancelled ? NSUserCancelledError : SCMediaCompressorErrorCoordinationFailed
                          userInfo:@{NSLocalizedDescriptionKey:message}];
}

/// 保留 Live 配对的系统原因，不改变本库一般失败码或公开取消语义。
/// @param message 配对失败阶段。
/// @param cancelled 高层任务是否已接受取消。
/// @param underlying 实际底层错误；无系统错误时为 nil。
static NSError *sc_taskErrorWithUnderlying(NSString *message,BOOL cancelled,NSError *underlying) {
    if(cancelled || !underlying)return sc_taskError(message,cancelled);
    if([underlying.domain isEqualToString:SCMediaCompressorErrorDomain])return underlying;
    return [NSError errorWithDomain:SCMediaCompressorErrorDomain code:SCMediaCompressorErrorCoordinationFailed userInfo:@{NSLocalizedDescriptionKey:message,NSUnderlyingErrorKey:underlying}];
}

/// 绑定图片入口共用的任务钩子，配置副本仅弱持有任务。
static SCImageCompressionOptions *sc_imageOptionsForTask(SCImageCompressionOptions *options, SCCompressionTask *task) {
    // copy：本轮配置副本，后续绑定与归一化不会影响调用方。
    SCImageCompressionOptions *copy = [options copy] ?: [SCImageCompressionOptions new];
    // weakTask：配置和任务各自拥有生命周期。
    __weak SCCompressionTask *weakTask = task;
    copy.sc_cancellationCheck = ^{ return weakTask.cancelled; };
    // bytes、converted：图片独立实际基准，Live 稍后会替换整组基准。
    copy.sc_comparisonHandler = ^(unsigned long long bytes, BOOL converted) {
        [weakTask sc_recordImageComparisonBytes:bytes converted:converted];
        [weakTask sc_recordComparisonBytes:bytes converted:converted];
    };
    // status、quality、score：已有保真计算的最终诊断。
    copy.sc_qualityHandler = ^(SCImageQualityStatus status, CGFloat quality, NSNumber *score) {
        [weakTask sc_recordImageQuality:status requested:quality score:score];
    };
    // performance：实际图片阶段的不可变快照。
    copy.sc_performanceHandler = ^(SCImagePerformance *performance) { [weakTask sc_recordImagePerformance:performance]; };
    return copy;
}

/// 运行普通图片的异步任务，统一在终态锁定后发布摘要及错误。
static SCCompressionTask *sc_startImageTask(SCImageCompressionOptions *options,
                                           void (^progress)(double),
                                           void (^completion)(NSData *, NSError *),
                                           NSData *(^encode)(SCImageCompressionOptions *, NSError **)) {
    // task：本轮独立进度、取消及统计。
    SCCompressionTask *task = [SCCompressionTask sc_taskWithProgress:progress];
    // copy：编码开始前在调用线程固定的配置。
    SCImageCompressionOptions *copy = sc_imageOptionsForTask(options, task);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ @autoreleasepool {
        [task sc_reportProgress:0.05];
        // error：实际编码的失败原因。
        NSError *error = nil;
        // result：本轮图片编码的实际结果。
        NSData *result = task.cancelled ? nil : encode(copy, &error);
        if (result) [task sc_reportProgress:1];
        [task sc_finish:^{
            // cancelled：终态锁定后固定的取消状态。
            BOOL cancelled = task.cancelled;
            if (cancelled) {
                [task sc_recordImageQuality:SCImageQualityStatusNotEvaluated requested:copy.quality score:nil];
                [task sc_recordImagePerformance:sc_ImagePerformanceWithPairing(task.imagePerformance,nil,0,NO)];
            }
            // delivered：与最终统计使用同一份交付结果。
            NSData *delivered = cancelled ? nil : result;
            [task sc_publishOutcomeWithKind:SCCompressionMediaKindImage outputBytes:delivered.length succeeded:delivered != nil];
            completion(delivered, cancelled ? sc_taskError(@"Cancelled",YES) : error);
        }];
    }});
    return task;
}

@implementation SCMediaCompressor
/// 配置唯一的内部日志分发器。
/// @param handler 可选统计回调；nil 关闭日志。
+ (void)sc_setLogHandler:(void (^)(NSString *))handler { [SCLogger sc_setLogHandler:handler]; }
/// 转交一条统计消息。
/// @param message 只包含编码统计的文本。
+ (void)sc_logMessage:(NSString *)message { [SCLogger sc_logMessage:message]; }
/// 创建数据图片异步任务，将 CPU 密集操作移到工作队列。
/// @param data 原始图片数据。
/// @param options 本次图片配置。
/// @param progress 主队列进度回调。
/// @param completion 主队列唯一完成回调。
+ (SCCompressionTask *)sc_compressImageData:(NSData *)data options:(SCImageCompressionOptions *)options progress:(void (^)(double))progress completion:(void (^)(NSData *, NSError *))completion {
    // input：调用方可在返回后修改原 NSMutableData。
    NSData *input = [data copy];
    // copy、error：本轮配置及实际编码错误。
    return sc_startImageTask(options, progress, completion, ^NSData *(SCImageCompressionOptions *copy, NSError **error) {
        return [SCImageCompressor sc_compressData:input options:copy error:error];
    });
}
/// UIImage 的异步包装；编码算法与同步入口完全一致。
/// @param image 原始图片。
/// @param options 本次配置快照来源。
/// @param progress 主队列阶段进度。
/// @param completion 唯一终态回调。
+ (SCCompressionTask *)sc_compressImage:(UIImage *)image options:(SCImageCompressionOptions *)options progress:(void (^)(double))progress completion:(void (^)(NSData *,NSError *))completion {
    // copy、error：本轮配置及实际编码错误。
    return sc_startImageTask(options, progress, completion, ^NSData *(SCImageCompressionOptions *copy, NSError **error) {
        return [SCImageCompressor sc_compressImage:image options:copy error:error];
    });
}
/// 包装唯一视频会话，直接订阅编码进度而不创建轮询计时器。
/// @param asset 视频或组合素材。
/// @param outputURL 未占用的本地输出路径。
/// @param configure 启动前参数配置。
/// @param progress 主队列进度。
/// @param completion 主队列完成回调。
+ (SCCompressionTask *)sc_compressVideoAsset:(AVAsset *)asset outputURL:(NSURL *)outputURL configure:(void (^)(SCVideoCompressor *))configure progress:(void (^)(double))progress completion:(void (^)(NSURL *,NSError *))completion {
    // task：持有并协调本轮视频会话。
    SCCompressionTask *task=[SCCompressionTask sc_taskWithProgress:progress];
    // session：视频编码器，先做必要预处理，再与实际压缩前文件择小。
    SCVideoCompressor *session=[SCVideoCompressor sc_exportSessionWithAsset:asset];
    session.outputFileType=AVFileTypeMPEG4;
    if (configure) configure(session);
    session.outputURL=outputURL;
    session.sc_defersPublication=YES;
    // value：值。
    session.progressHandler=^(float value){ if (value < 1) [task sc_reportProgress:value]; };
    [session sc_exportAsynchronouslyWithCompletionHandler:^{
        // success：编码成功后由高层终态决定是否发布。
        BOOL success = session.status == AVAssetExportSessionStatusCompleted;
        [task sc_recordVideoStatistics:session durations:session.stageDurations];
        if (success) [task sc_recordComparisonBytes:session.comparisonBytes converted:session.usesConvertedBaseline];
        // error：编码失败原因；任务取消在终态优先。
        NSError *error = session.status == AVAssetExportSessionStatusCancelled ? sc_taskError(@"Cancelled",YES) : session.error;
        if (!success && !error) error = sc_taskError(@"Video export failed",NO);
        // publish：仅操作本轮的私有文件，迟到取消无须删除公开路径。
        BOOL (^publish)(BOOL, NSError **) = success ? [session sc_deferredPublication] : nil;
        [task sc_finish:^{
            // deliveryError：终态锁定后捕获真实发布错误。
            NSError *deliveryError = task.cancelled ? sc_taskError(@"Cancelled",YES) : error;
            // delivered：成功写入且任务仍应交付时才尝试原子发布。
            BOOL delivered = publish && publish(!task.cancelled, &deliveryError);
            // outputBytes：使用成功发布的真实文件字节。
            unsigned long long outputBytes = delivered ? [NSFileManager.defaultManager attributesOfItemAtPath:outputURL.path error:nil].fileSize : 0;
            [task sc_publishOutcomeWithKind:SCCompressionMediaKindVideo outputBytes:outputBytes succeeded:delivered];
            if (delivered) [task sc_reportDeliveredProgress:progress];
            completion(delivered ? outputURL : nil, deliveryError);
        }];
    }];
    // 先入队导出，再安装取消动作，避免取消先到达时被尚未启动的会话忽略。
    [task sc_setCancellationHandler:^{ [session sc_cancelExport]; }];
    return task;
}
/// 在独立目录中完成 JPEG、视频编码及配对；源文件永不覆盖。
/// @param imageURL 原始图片文件。
/// @param videoURL 原始配对视频文件。
/// @param directory 输出父目录。
/// @param options 图片与 Live 视频共享的配置。
/// @param configure 视频编码参数配置，不能覆盖图片提供的 Live 尺寸。
/// @param progress 主队列阶段进度。
/// @param completion 主队列唯一终态回调。
+ (SCCompressionTask *)sc_compressLivePhotoImageURL:(NSURL *)imageURL videoURL:(NSURL *)videoURL outputDirectory:(NSURL *)directory imageOptions:(SCImageCompressionOptions *)options configureVideo:(void (^)(SCVideoCompressor *))configure progress:(void (^)(double))progress completion:(void (^)(NSURL *,NSURL *,NSError *))completion {
    // task：跨图片、视频及封装阶段的唯一任务。
    SCCompressionTask *task=[SCCompressionTask sc_taskWithProgress:progress];
    // copy：Live 图片与视频共享的尺寸、质量及 HDR 设置。
    SCImageCompressionOptions *copy = sc_imageOptionsForTask(options, task);
    copy.quality = sc_NormalizedQuality(copy.quality,sc_DefaultImageQuality);
    // imagePerformance：仅保存配对前不可变快照，最终成功/失败均从它合并，不重复计数。
    __block SCImagePerformance *imagePerformance=nil;
    // pairMetrics：只记录 JPEG 配对工作，不把跨视频等待计入图片耗时。
    SCImageMetrics *pairMetrics=[[SCImageMetrics alloc]sc_initWithInputBytes:0];
    // recordPerformance：沿用普通图片任务的快照记录方式。
    void (^recordPerformance)(SCImagePerformance *) = copy.sc_performanceHandler;
    // performance：Live 额外冻结配对前快照，供最终统计使用。
    copy.sc_performanceHandler=^(SCImagePerformance *performance){imagePerformance=performance;recordPerformance(performance);};
    // folder：本操作唯一拥有的输出目录。
    NSURL *folder=[directory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    // fail：各阶段共用失败收尾，只删除本次创建的子目录。
    void (^fail)(NSError *)=^(NSError *error){
        if(task.finished)return;
        [task sc_recordImagePerformance:sc_ImagePerformanceWithPairing(imagePerformance,pairMetrics,0,NO)];
        [task sc_recordImageQuality:SCImageQualityStatusNotEvaluated requested:copy.quality score:nil];
        [task sc_publishOutcomeWithKind:SCCompressionMediaKindLivePhoto outputBytes:0 succeeded:NO];
        [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
        [task sc_finish:^{completion(nil,nil,task.cancelled ? sc_taskError(@"Cancelled",YES) : error);}];
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ @autoreleasepool {
        // error：取源、图片编码或写入错误。
        NSError *error=nil;
        if (!directory.isFileURL || !imageURL.isFileURL || !videoURL.isFileURL || task.cancelled ||
            ![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&error]) { fail(error ?: sc_taskError(@"Invalid Live Photo input or destination",task.cancelled)); return; }
        // operationStarted：不包含相册取源的本轮起点。
        CFAbsoluteTime operationStarted=CFAbsoluteTimeGetCurrent();
        // data：原始静态图的编码数据。
        NSData *data=[NSData dataWithContentsOfURL:imageURL options:NSDataReadingMappedIfSafe error:&error];
        // preservesHDR：独立 HDR 开关要求保留的源 HDR，配对不能静默丢失。
        BOOL preservesHDR=copy.preservesHDR&&[SCImageCompressor sc_containsHDRInData:data];
        // identifier：在图片最终择小前确定最终配对 ID，全部候选复用。
        NSString *identifier=[SCLivePhotoResourceWriter sc_livePhotoIdentifierForImageURL:imageURL] ?: NSUUID.UUID.UUIDString;
        // imageBaseline、rawBaseline：最终配对基线与对应的压缩前真实数据。
        __block NSData *imageBaseline=nil,*rawBaseline=nil;
        // pairedBaselineSource、pairedBaseline：相同基线内容只重写一次，之后直接复用真实字节。
        __block NSData *pairedBaselineSource=nil,*pairedBaseline=nil;
        // lastSource、lastPaired：相邻相同候选不重复配对，不持有所有大候选。
        __block NSData *lastSource=nil,*lastPaired=nil;
        // sizeSource、sizePhoto：本轮目录中用于实际 JPEG 配对的临时文件。
        NSURL *sizeSource=[folder URLByAppendingPathComponent:@"size-source.jpg"],*sizePhoto=[folder URLByAppendingPathComponent:@"size-photo.jpg"];
        // baseline：同步已有基线；已配对的相同内容不再次重写。
        copy.sc_baselineDataHandler=^(NSData *baseline){rawBaseline=baseline;imageBaseline=[pairedBaselineSource isEqualToData:baseline]?pairedBaseline:baseline;};
        // pairingError：同步 JPEG 最终写入的真实失败原因，避免被图片通用错误覆盖。
        __block NSError *pairingError=nil;
        // candidate、metrics：从真实候选得到最终配对 JPEG，在最终字节比较前测量并计数。
        copy.sc_imageFinalizer=^NSData *(NSData *candidate,SCImageMetrics *metrics){
            if(task.cancelled)return nil;
            if([lastSource isEqualToData:candidate])return lastPaired;
            if([pairedBaselineSource isEqualToData:candidate])return pairedBaseline;
            if(![candidate writeToURL:sizeSource options:NSDataWritingAtomic error:&pairingError])return nil;
            [NSFileManager.defaultManager removeItemAtURL:sizePhoto error:nil];
            // paired：同步图片写入结果，MOV 的异步封装不进入本回调。
            __block BOOL paired=NO;
            // success：只有 ImageIO 完成后才读取实际最终 JPEG。
            [SCLivePhotoResourceWriter sc_writePairedJPEGAtURL:sizeSource toURL:sizePhoto identifier:identifier metrics:metrics completion:^(BOOL success,NSError *failure){paired=success;pairingError=failure;}];
            // output：只保留本次已完成的文件字节，读失败不会冒充小文件。
            NSData *output=paired?[NSData dataWithContentsOfURL:sizePhoto options:NSDataReadingMappedIfSafe error:&pairingError]:nil;
            if(output&&preservesHDR&&![SCImageCompressor sc_containsHDRInData:output])output=nil;
            lastSource=candidate;lastPaired=output;
            if(output&&([candidate isEqualToData:data]||[candidate isEqualToData:rawBaseline])){pairedBaselineSource=candidate;pairedBaseline=output;imageBaseline=output;}
            return output;
        };
        // encoded：强制 JPEG 的静态图结果。
        NSData *encoded=data ? [SCImageCompressor sc_compressLivePhotoData:data options:copy error:&error] : nil;
        // baseline：当前静态图的有效基准数据。
        copy.sc_baselineDataHandler=nil;copy.sc_imageFinalizer=nil;
        // baselineStill：待写入相同配对 ID 的基准 JPEG。
        NSURL *baselineStill=[folder URLByAppendingPathComponent:@"baseline.jpg"];
        if(!imageBaseline || ![imageBaseline writeToURL:baselineStill options:NSDataWritingAtomic error:&error]) {fail(pairingError ? sc_taskErrorWithUnderlying(@"Live Photo JPEG pairing failed",task.cancelled,pairingError) : (error ?: sc_taskError(@"Live Photo baseline image failed",task.cancelled)));return;}
        // still：配对前静态图的暂存路径。
        NSURL *still=[folder URLByAppendingPathComponent:@"encoded.jpg"];
        if (!encoded || task.cancelled || ![encoded writeToURL:still options:NSDataWritingAtomic error:&error]) {fail(pairingError ? sc_taskErrorWithUnderlying(@"Live Photo JPEG pairing failed",task.cancelled,pairingError) : (error ?: sc_taskError(@"Live Photo image failed",task.cancelled)));return;}
        [NSFileManager.defaultManager removeItemAtURL:sizeSource error:nil];[NSFileManager.defaultManager removeItemAtURL:sizePhoto error:nil];
        // sharesPairedImage：冻结相等关系，后续封装期间可提前释放大块图片字节。
        BOOL sharesPairedImage = [imageBaseline isEqualToData:encoded];
        // imagePairElapsed：图片预算判断前已经执行的 JPEG 配对，单独纳入 Live pair。
        double imagePairElapsed=[imagePerformance.stageDurations[@"pair"]doubleValue];
        // imageElapsed：剔除 JPEG 配对，避免整组阶段重复计时。
        double imageElapsed=MAX(0,CFAbsoluteTimeGetCurrent()-operationStarted-imagePairElapsed);
        [task sc_reportProgress:0.25];
        // movie：唯一的视频编码中间文件。
        NSURL *movie=[folder URLByAppendingPathComponent:@"encoded.mp4"];
        // pairedVideo：必要转换时在体积判断前完成最终配对，成功后直接复用。
        NSURL *pairedVideo=[folder URLByAppendingPathComponent:@"video.mov"];
        // session：直接使用静态图尺寸配置的 Live 视频编码器。
        SCVideoCompressor *session=[SCVideoCompressor sc_exportSessionWithAsset:[AVURLAsset URLAssetWithURL:videoURL options:nil]];
        session.outputFileType=AVFileTypeMPEG4;
        if (configure) configure(session);
        session.outputURL=movie; session.livePhoto=YES; session.livePhotoImageOptions=copy;
        session.maximumSize=copy.maximumSize;session.videoQuality=copy.quality;session.preservesHDR=copy.preservesHDR;
        session.sc_comparisonOutputURL=[folder URLByAppendingPathComponent:@"baseline.mp4"];
        // value：值。
        session.progressHandler=^(float value){[task sc_reportProgress:0.25+0.6*value];};
        [session sc_exportAsynchronouslyWithCompletionHandler:^{
            [task sc_recordVideoStatistics:session durations:session.stageDurations];
            if (task.cancelled || session.status!=AVAssetExportSessionStatusCompleted) {fail(session.error ?: sc_taskError(@"Live Photo video failed",task.cancelled));return;}
            // pairingStarted：候选与基准配对的共同起点。
            CFAbsoluteTime pairingStarted=CFAbsoluteTimeGetCurrent();
            // pairedImage：成功交付的静态图路径。
            NSURL *pairedImage=[folder URLByAppendingPathComponent:@"photo.jpg"];
            // imageOK：图片OK。
            [SCLivePhotoResourceWriter sc_writePairedJPEGAtURL:still toURL:pairedImage identifier:identifier metrics:pairMetrics completion:^(BOOL imageOK,NSError *imageError){
                if (!imageOK || task.cancelled) {fail(sc_taskErrorWithUnderlying(@"Live Photo JPEG pairing failed",task.cancelled,imageError));return;}
                [task sc_reportProgress:0.9];
                // videoReady：复用已测量的最终 MOV，普通视频才在这里首次配对。
                void (^videoReady)(BOOL,NSError *)=^(BOOL videoOK,NSError *videoError){
                    if (!videoOK || task.cancelled) {fail(sc_taskErrorWithUnderlying(@"Live Photo MOV pairing failed",task.cancelled,videoError));return;}
                    // baselinePhoto：使用相同配对 ID 的基准静态图。
                    NSURL *baselinePhoto=[folder URLByAppendingPathComponent:@"baseline-photo.jpg"];
                    // baselineVideo：使用相同配对 ID 和 MOV 容器的基准视频。
                    NSURL *baselineVideo=[folder URLByAppendingPathComponent:@"baseline-video.mov"];
                    // imageReady：基准图片配对是否成功。
                    [SCLivePhotoResourceWriter sc_writePairedJPEGAtURL:sharesPairedImage ? pairedImage : baselineStill toURL:baselinePhoto identifier:identifier metrics:pairMetrics completion:^(BOOL imageReady,NSError *baselineImageError){
                        if(!imageReady || task.cancelled) {fail(sc_taskErrorWithUnderlying(@"Live Photo baseline pairing failed",task.cancelled,baselineImageError));return;}
                        // finishBaseline：已有配对字节可复用时直接进入相同的最终择小流程。
                        void (^finishBaseline)(BOOL,NSError *)=^(BOOL ready,NSError *baselineVideoError){
                            if(!ready || task.cancelled) {fail(sc_taskErrorWithUnderlying(@"Live Photo baseline MOV failed",task.cancelled,baselineVideoError));return;}
                            // total：最终封装后的整组基准，不采用中间 MP4 或 JPEG 的大小。
                            unsigned long long total=0;
                            // paths：基准与候选使用同一配对 ID，可分别选择较小资源。
                            NSArray<NSArray<NSURL *> *> *paths=@[@[baselinePhoto,pairedImage],@[baselineVideo,pairedVideo]];
                            // pair：基准与候选路径。
                            for(NSArray<NSURL *> *pair in paths) {
                                // bytes：当前资源的基准体积。
                                unsigned long long bytes=[NSFileManager.defaultManager attributesOfItemAtPath:pair[0].path error:nil].fileSize; total+=bytes;
                                if([NSFileManager.defaultManager attributesOfItemAtPath:pair[1].path error:nil].fileSize>=bytes) {
                                    if([NSFileManager.defaultManager contentsEqualAtPath:pair[0].path andPath:pair[1].path])continue;
                                    if([pair[1] isEqual:pairedVideo] && !session.sc_comparisonBaselineReusable) {total+=([NSFileManager.defaultManager attributesOfItemAtPath:pair[1].path error:nil].fileSize-bytes);continue;}
                                    if([pair[1] isEqual:pairedVideo])[session sc_useBaselineQuality];
                                    if([pair[1] isEqual:pairedImage]) {
                                        // score：最终改选基线时复用配对后已有评分，不能继承落选候选。
                                        NSNumber *score=copy.sc_baselineFidelityScore;
                                        [task sc_recordImageQuality:score?(score.doubleValue+1e-9>=copy.effectiveQualityTarget?SCImageQualityStatusMet:SCImageQualityStatusNotMet):SCImageQualityStatusNotEvaluated requested:copy.quality score:score];
                                        // baselineSource：最终 JPEG 的真实像素与方向，不能回退超限原图。
                                        CGImageSourceRef baselineSource=CGImageSourceCreateWithURL((__bridge CFURLRef)baselinePhoto,NULL);
                                        // properties：基准图片的真实文件属性。
                                        NSDictionary *properties=baselineSource ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(baselineSource,0,NULL)) : nil;
                                        if(baselineSource)CFRelease(baselineSource);
                                        if(!properties || [properties[(__bridge NSString *)kCGImagePropertyPixelWidth]doubleValue]*[properties[(__bridge NSString *)kCGImagePropertyPixelHeight]doubleValue]>sc_MaximumDecodedPixels || (copy.maximumSize.width>0 && [properties[(__bridge NSString *)kCGImagePropertyPixelWidth]doubleValue]>copy.maximumSize.width) || (copy.maximumSize.height>0 && [properties[(__bridge NSString *)kCGImagePropertyPixelHeight]doubleValue]>copy.maximumSize.height) || [properties[(__bridge NSString *)kCGImagePropertyOrientation]integerValue]>1) {fail(sc_taskError(@"Live Photo baseline violates image output constraints",NO));return;}
                                    }
                                    // replacementError：替换为同配置基准时的文件错误。
                                    NSError *replacementError=nil;
                                    if(![NSFileManager.defaultManager removeItemAtURL:pair[1] error:&replacementError] || ![NSFileManager.defaultManager moveItemAtURL:pair[0] toURL:pair[1] error:&replacementError]) {fail(replacementError);return;}
                                }
                            }
                            [task sc_recordComparisonBytes:total converted:YES];
                            // photoBytes：最终 JPEG 文件元数据，不新增图片解码或内容扫描。
                            unsigned long long photoBytes=[NSFileManager.defaultManager attributesOfItemAtPath:pairedImage.path error:nil].fileSize;
                            if(!photoBytes){fail(sc_taskError(@"Live Photo image output is empty",NO));return;}
                            [task sc_recordImagePerformance:sc_ImagePerformanceWithPairing(imagePerformance,pairMetrics,photoBytes,YES)];
                            // durations：视频阶段保持原值，并补充整组图片、配对和总耗时。
                            NSMutableDictionary *durations=[session.stageDurations mutableCopy];
                            durations[@"image"]=@(imageElapsed); durations[@"pair"]=@(CFAbsoluteTimeGetCurrent()-pairingStarted+imagePairElapsed); durations[@"total"]=@(CFAbsoluteTimeGetCurrent()-operationStarted);
                            [task sc_recordVideoStatistics:session durations:durations];
                            // temporary：只清理本轮配对中间文件。
                            for(NSURL *temporary in @[still,movie,baselineStill,session.sc_comparisonOutputURL,baselinePhoto,baselineVideo]) [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
                            [task sc_reportProgress:1];
                            // liveOutput：最终配对 JPEG 与 MOV 的合计交付字节。
                            unsigned long long liveOutput=photoBytes+[NSFileManager.defaultManager attributesOfItemAtPath:pairedVideo.path error:nil].fileSize;
                            [task sc_publishOutcomeWithKind:SCCompressionMediaKindLivePhoto outputBytes:liveOutput succeeded:YES];
                            [task sc_finish:^{if(task.cancelled) { [task sc_recordImageQuality:SCImageQualityStatusNotEvaluated requested:copy.quality score:nil];[task sc_recordImagePerformance:sc_ImagePerformanceWithPairing(imagePerformance,pairMetrics,0,NO)];[task sc_publishOutcomeWithKind:SCCompressionMediaKindLivePhoto outputBytes:0 succeeded:NO]; [NSFileManager.defaultManager removeItemAtURL:folder error:nil]; completion(nil,nil,sc_taskError(@"Cancelled",YES)); } else completion(pairedImage,pairedVideo,nil);}];
                        };
                        if([NSFileManager.defaultManager contentsEqualAtPath:movie.path andPath:session.sc_comparisonOutputURL.path]) {
                            // copyError：仅复制已经配对的相同内容，不重复执行 MOV 封装。
                            NSError *copyError=nil;
                            // copied：复用已有配对资源，失败时保留实际复制错误。
                            BOOL copied=[NSFileManager.defaultManager copyItemAtURL:pairedVideo toURL:baselineVideo error:&copyError];
                            finishBaseline(copied,copyError);
                        } else {
                            // cancel：基准内容不同时注册封装队列拥有的取消动作。
                            [SCLivePhotoResourceWriter sc_writePairedMovieAtURL:session.sc_comparisonOutputURL toURL:baselineVideo identifier:identifier cancellation:^(dispatch_block_t cancel){
                                [task sc_setCancellationHandler:cancel];
                            } completion:finishBaseline];
                        }
                    }];
                };
                // cancel：只请求最终候选的 MOV 配对取消，停止后再由完成回调清理。
                [SCLivePhotoResourceWriter sc_writePairedMovieAtURL:movie toURL:pairedVideo identifier:identifier cancellation:^(dispatch_block_t cancel){
                    [task sc_setCancellationHandler:cancel];
                } completion:videoReady];
            }];
        }];
        [task sc_setCancellationHandler:^{[session sc_cancelExport];}];
    }});
    return task;
}
@end
