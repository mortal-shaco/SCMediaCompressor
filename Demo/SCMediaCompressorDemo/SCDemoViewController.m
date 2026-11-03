#import "SCDemoViewController.h"
#import <SCMediaCompressor/SCMediaCompressor.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <AVKit/AVKit.h>
#import <ImageIO/ImageIO.h>

/// 单资源或 Live 双资源的实际字节数，不读取私有 PhotoKit fileSize 字段。
/// @param url 本地已经完成取源或编码的文件。
static unsigned long long sc_demoBytes(NSURL *url) { return [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil].fileSize; }
/// 显示实际字节及便于阅读的 MB 数值。
/// @param bytes 已读取的真实文件大小。
static NSString *sc_demoByteText(unsigned long long bytes) {return [NSString stringWithFormat:@"%llu 字节（%.2f MB）",bytes,bytes/1048576.0];}
/// 读取图片真实像素及方向；预览缩略图不参与此统计。
/// @param url 原始或压缩后的文件 URL。
static NSString *sc_demoImageText(NSURL *url) {
    // source：图片的只读元数据源。
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,NULL);
    // info：第一帧原始像素属性。
    NSDictionary *info=source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL)) : nil;
    // type：读取文件真实编码，不以扩展名判断格式。
    NSString *type=source ? (__bridge NSString *)CGImageSourceGetType(source) : @"未知格式";
    if(source)CFRelease(source);
    // width：按显示方向归一后的宽度。
    double width=[info[(__bridge NSString *)kCGImagePropertyPixelWidth]doubleValue];
    // height：按显示方向归一后的高度。
    double height=[info[(__bridge NSString *)kCGImagePropertyPixelHeight]doubleValue];
    // orientation：EXIF 方向，不触发重新编码。
    NSInteger orientation=[info[(__bridge NSString *)kCGImagePropertyOrientation]integerValue];
    if(orientation>=5&&orientation<=8){double swap=width;width=height;height=swap;}
    return [NSString stringWithFormat:@"%.0f × %.0f · %@",width,height,[type stringByReplacingOccurrencesOfString:@"public." withString:@""]];
}
/// 显示实际视频显示尺寸、时长与容器内编码类型。
/// @param url 原始或压缩后的视频文件。
static NSString *sc_demoVideoText(NSURL *url) {
    // asset：本次只读的视频资源。
    AVAsset *asset=[AVAsset assetWithURL:url];
    // track：第一个视频轨道。
    AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    // bounds：应用方向后的显示范围。
    CGRect bounds=CGRectApplyAffineTransform((CGRect){CGPointZero,track.naturalSize},track.preferredTransform);
    // type：实际编码 FourCC。
    FourCharCode type=track.formatDescriptions.count ? CMFormatDescriptionGetMediaSubType((__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject) : 0;
    // header：读取真实 ftyp 主品牌，不根据扩展名猜测容器。
    NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:url error:nil];NSData *header=[file readDataOfLength:12];[file closeFile];
    // brand：QuickTime 使用 qt 品牌，其他已知品牌为 MP4。
    NSString *brand=header.length==12?[[NSString alloc]initWithBytes:(const uint8_t *)header.bytes+8 length:4 encoding:NSASCIIStringEncoding]:nil;
    // container：仅展示能够识别的实际容器。
    NSString *container=[brand isEqual:@"qt  "]?@"MOV":([@[@"isom",@"iso2",@"mp41",@"mp42",@"avc1"]containsObject:brand]?@"MP4":@"未知容器");
    // range：由真实视频轨道判断动态范围，不把 HEVC 等同于 HDR。
    NSString *range=[asset tracksWithMediaCharacteristic:AVMediaCharacteristicContainsHDRVideo].count?@"HDR":@"SDR";
    return [NSString stringWithFormat:@"%.0f×%.0f %.3fs %@/%@/%@",fabs(bounds.size.width),fabs(bounds.size.height),CMTimeGetSeconds(asset.duration),type==kCMVideoCodecType_HEVC?@"HEVC":type==kCMVideoCodecType_H264?@"H.264":@"其他编码",container,range];
}

/// 只展示已完成的图片工作，保持阶段紧凑且不新增媒体扫描。
/// @param performance 已冻结的图片统计，未开始处理时为 nil。
static NSString *sc_demoImagePerformanceText(SCImagePerformance *performance) {
    if(!performance)return @"";
    // durations：图片内核各阶段的已有实测值。
    NSDictionary *durations=performance.stageDurations;
    return [NSString stringWithFormat:@"\n图片编码%lu次·准备%.0fms/编码%.0fms/评分%.0fms/择小%.0fms",(unsigned long)performance.encodingPassCount,[durations[@"prepare"]doubleValue]*1000,[durations[@"encode"]doubleValue]*1000,[durations[@"evaluate"]doubleValue]*1000,[durations[@"finish"]doubleValue]*1000];
}

/// 按需打开图片或原生 Live Photo，避免主页面占位与自动解码。
@interface SCDemoPreviewController : UIViewController
/// 已完成的静态文件，保持到预览关闭后再由主页面清理。
@property NSURL *imageURL;
/// Live 配对视频；普通静态图片时为空。
@property NSURL *videoURL;
@end
@implementation SCDemoPreviewController
/// 只在进入独立预览页面后加载结果。
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.systemBackgroundColor;self.title=self.videoURL?@"Live Photo 预览":@"图片预览";
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(sc_close)];
    // content：图片与 Live 使用相同的全屏显示边界。
    UIView *content;
    if(self.videoURL){
        // live：系统原生配对显示，长按可再次播放。
        PHLivePhotoView *live=[PHLivePhotoView new];live.contentMode=UIViewContentModeScaleAspectFit;content=live;
        // hint：加载或失败说明，不把失败的配对当作可播放结果。
        UILabel *hint=[UILabel new];hint.text=@"正在加载 Live Photo…";hint.textAlignment=NSTextAlignmentCenter;hint.numberOfLines=0;hint.frame=self.view.bounds;hint.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[live addSubview:hint];
        [PHLivePhoto requestLivePhotoWithResourceFileURLs:@[self.imageURL,self.videoURL] placeholderImage:nil targetSize:CGSizeMake(1200,1200) contentMode:PHImageContentModeAspectFit resultHandler:^(PHLivePhoto *photo,NSDictionary *info){dispatch_async(dispatch_get_main_queue(),^{
            if(photo){hint.hidden=YES;live.livePhoto=photo;if(![info[PHLivePhotoInfoIsDegradedKey]boolValue])[live startPlaybackWithStyle:PHLivePhotoViewPlaybackStyleFull];}
            else if(info[PHLivePhotoInfoErrorKey])hint.text=[NSString stringWithFormat:@"Live Photo 加载失败：%@",[info[PHLivePhotoInfoErrorKey]localizedDescription]];
        });}];
    } else {
        // image：仅解码压缩完成的文件，不影响压缩计时。
        UIImageView *image=[UIImageView new];image.contentMode=UIViewContentModeScaleAspectFit;image.image=[UIImage imageWithContentsOfFile:self.imageURL.path];content=image;
    }
    content.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:content];
    [NSLayoutConstraint activateConstraints:@[[content.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[content.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],[content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
}
/// 关闭预览后继续保留主页面的本次结果。
- (void)sc_close {[self dismissViewControllerAnimated:YES completion:nil];}
@end

@interface SCDemoViewController () <PHPickerViewControllerDelegate>
/// 静态图片独立保留 HDR，默认关闭。
@property UISwitch *imageHDRSwitch;
/// 视频独立保留 HDR，默认关闭。
@property UISwitch *videoHDRSwitch;
/// 普通视频封装选择，默认 MP4；Live 最终视频固定 MOV。
@property UISegmentedControl *videoContainer;
/// 自动、JPEG、PNG、HEIC 或 WebP 图片格式。
@property UISegmentedControl *imageFormat;
/// 本次图片与视频质量参数。
@property UISlider *qualitySlider;
/// 显示当前参数，避免误解为主观百分比。
@property UILabel *qualityLabel;
/// 静态图边界，也是 Live 视频唯一的尺寸配置。
@property UITextField *imageSide;
/// 仅普通视频使用的尺寸边界。
@property UITextField *videoSide;
/// 原始与压缩后统计信息。
@property UITextView *report;
/// 当前任务进度。
@property UIProgressView *progressView;
/// 进度条旁的实时百分比和任务状态。
@property UILabel *progressLabel;
/// 主动保存结果的按钮。
@property UIButton *saveButton;
/// 按需打开图片、视频或 Live Photo 的统一入口。
@property UIButton *playButton;
/// 当前公共库异步任务。
@property SCCompressionTask *task;
/// 取源和编码共用的本轮独立目录。
@property NSURL *folder;
/// 需要保存的图片文件，Live 时与 outputVideo 成对。
@property NSURL *outputImage;
/// 普通视频或 Live 配对视频。
@property NSURL *outputVideo;
/// 防止旧 PhotoKit/iCloud 回调覆盖新选择。
@property NSString *operationID;
/// 当前选择器是否仅允许视频。
@property BOOL choosingVideo;
/// 保存完成前不得删除仍被 Photos 读取的双资源文件。
@property BOOL saving;
@end

@implementation SCDemoViewController
/// 系统加载入口，构建独立于业务项目的测试界面。
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"媒体压缩 Demo";self.view.backgroundColor=UIColor.systemBackgroundColor;
    // scroll：常规竖屏一屏布局，小屏和大字体时允许外层滚动。
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;[self.view addSubview:scroll];
    // stack：仅保留配置、进度、实际阶段信息和结果操作。
    UIStackView *stack=[UIStackView new];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=6;stack.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:8],[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-8],[stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:12],[stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-12],[stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-24]]];
    // fitting：优先填满一屏，控件最小高度不足时自动滚动而不裁剪。
    NSLayoutConstraint *fitting=[stack.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor constant:-16];fitting.priority=UILayoutPriorityDefaultHigh;fitting.active=YES;
    self.imageHDRSwitch=[UISwitch new];self.videoHDRSwitch=[UISwitch new];
    self.imageHDRSwitch.accessibilityLabel=@"图片与 Live Photo 保留 HDR";self.imageHDRSwitch.accessibilityHint=@"普通图片指定格式优先，不能保留 HDR 时输出同格式 SDR；自动模式和 Live 要求保留 HDR。";self.videoHDRSwitch.accessibilityLabel=@"普通视频保留 HDR";
    [stack addArrangedSubview:[self sc_columns:@[[self sc_switchRow:@"图片/Live HDR" control:self.imageHDRSwitch],[self sc_switchRow:@"视频 HDR" control:self.videoHDRSwitch]]]];
    self.imageFormat=[[UISegmentedControl alloc]initWithItems:@[@"自动",@"JPEG",@"PNG",@"HEIC",@"WebP"]];self.imageFormat.selectedSegmentIndex=0;
    self.imageFormat.accessibilityHint=@"自动保留 HDR 时在可用格式中按保真和实际体积择优，Live 固定 JPEG。";
    [stack addArrangedSubview:[self sc_row:@"图片格式" control:self.imageFormat]];
    self.videoContainer=[[UISegmentedControl alloc]initWithItems:@[@"MP4",@"MOV"]];self.videoContainer.selectedSegmentIndex=0;self.videoContainer.accessibilityLabel=@"普通视频格式，Live 固定 MOV";
    [stack addArrangedSubview:[self sc_row:@"视频格式" control:self.videoContainer]];
    self.imageSide=[self sc_sideField:@"1920"];self.videoSide=[self sc_sideField:@"1280"];
    [stack addArrangedSubview:[self sc_columns:@[[self sc_row:@"图片/Live 边长" control:self.imageSide],[self sc_row:@"视频边长" control:self.videoSide]]]];
    self.qualityLabel=[UILabel new];self.qualityLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.qualitySlider=[UISlider new];self.qualitySlider.minimumValue=0;self.qualitySlider.maximumValue=1;self.qualitySlider.value=.8;[self.qualitySlider addTarget:self action:@selector(sc_qualityChanged) forControlEvents:UIControlEventValueChanged];
    // qualityRow：滑条使用剩余宽度，数值保留自身宽度。
    UIStackView *qualityRow=[[UIStackView alloc]initWithArrangedSubviews:@[self.qualitySlider,self.qualityLabel]];qualityRow.spacing=8;qualityRow.alignment=UIStackViewAlignmentCenter;[self.qualityLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [stack addArrangedSubview:[self sc_row:@"画质目标" control:qualityRow]];[self sc_qualityChanged];
    [stack addArrangedSubview:[self sc_columns:@[[self sc_button:@"图片 / Live Photo" action:@selector(sc_pickImage)],[self sc_button:@"选择视频" action:@selector(sc_pickVideo)]]]];
    [stack addArrangedSubview:[self sc_button:@"取消 / 清理本次文件" action:@selector(sc_cancel)]];
    self.progressView=[UIProgressView new];self.progressLabel=[UILabel new];self.progressLabel.font=[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];self.progressLabel.text=@"待选择";
    [stack addArrangedSubview:[self sc_progressRow]];
    self.report=[UITextView new];self.report.editable=NO;self.report.font=[UIFont systemFontOfSize:12];self.report.backgroundColor=UIColor.secondarySystemBackgroundColor;self.report.layer.cornerRadius=8;self.report.textContainerInset=UIEdgeInsetsMake(8,6,8,6);self.report.text=@"选择图片、视频或 Live Photo 开始压缩。\n按实际流程展示：原始 → 必要转换 → 压缩结果。\n没有转换时省略该阶段；取源下载不计入压缩耗时。\n所有资源仅在本机处理，保存与预览均需主动点击。";[self.report.heightAnchor constraintGreaterThanOrEqualToConstant:150].active=YES;[stack addArrangedSubview:self.report];
    self.saveButton=[self sc_button:@"保存压缩结果到相册" action:@selector(sc_save)];self.saveButton.enabled=NO;[stack addArrangedSubview:self.saveButton];
    self.playButton=[self sc_button:@"预览压缩视频 / 图片 / Live Photo" action:@selector(sc_play)];self.playButton.enabled=NO;[stack addArrangedSubview:self.playButton];
}
/// 将同组配置平分为紧凑两列。
/// @param views 配置行或操作按钮。
- (UIStackView *)sc_columns:(NSArray<UIView *> *)views {
    // columns：并排控件保持相同可用宽度。
    UIStackView *columns=[[UIStackView alloc]initWithArrangedSubviews:views];columns.axis=UILayoutConstraintAxisHorizontal;columns.spacing=10;columns.distribution=UIStackViewDistributionFillEqually;return columns;
}
/// 百分比占用固定内容宽度，进度条使用剩余空间。
- (UIView *)sc_progressRow {
    // row：只承载可访问的系统进度条与状态。
    UIStackView *row=[[UIStackView alloc]initWithArrangedSubviews:@[self.progressView,self.progressLabel]];row.axis=UILayoutConstraintAxisHorizontal;row.spacing=8;row.alignment=UIStackViewAlignmentCenter;[self.progressLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];[row.heightAnchor constraintEqualToConstant:20].active=YES;return row;
}
/// 创建带标题的配置行。
/// @param title 配置说明。
/// @param control 交互控件。
- (UIView *)sc_row:(NSString *)title control:(UIView *)control {
    // label：支持动态字体和换行的配置说明。
    UILabel *label=[UILabel new];label.text=title;label.numberOfLines=0;label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    // row：说明和控件共用的横向容器。
    UIStackView *row=[[UIStackView alloc]initWithArrangedSubviews:@[label,control]];row.axis=UILayoutConstraintAxisHorizontal;row.spacing=8;row.alignment=UIStackViewAlignmentCenter;
    [label setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];return row;
}
/// HDR 开关使用完整辅助功能名称，并为系统开关实际尺寸保留窄屏余量。
/// @param title 紧凑显示标题。
/// @param control 带完整可访问名称的开关。
- (UIView *)sc_switchRow:(NSString *)title control:(UISwitch *)control {
    // row：保留系统开关的实际触控尺寸。
    UIStackView *row=(UIStackView *)[self sc_row:title control:control];row.spacing=4;row.layoutMargins=UIEdgeInsetsMake(0,0,0,2);row.layoutMarginsRelativeArrangement=YES;
    // label：短标题使用系统小字样式，大字体时仍遵循动态字号。
    UILabel *label=(UILabel *)row.arrangedSubviews.firstObject;label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];return row;
}
/// 创建像素上限输入框，0 表示不限制。
/// @param value 默认像素上限。
- (UITextField *)sc_sideField:(NSString *)value {
    // field：独立的数值输入框。
    UITextField *field=[UITextField new];field.text=value;field.keyboardType=UIKeyboardTypeNumberPad;field.borderStyle=UITextBorderStyleRoundedRect;[field.widthAnchor constraintEqualToConstant:66].active=YES;return field;
}
/// 创建统一操作按钮。
/// @param title 操作名称。
/// @param action 当前控制器中带 sc_ 前缀的选择器。
- (UIButton *)sc_button:(NSString *)title action:(SEL)action {
    // button：具有足够触控高度的操作入口。
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:title forState:UIControlStateNormal];button.backgroundColor=UIColor.secondarySystemBackgroundColor;button.layer.cornerRadius=8;button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];[button.heightAnchor constraintEqualToConstant:44].active=YES;[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
/// 更新源画质目标说明，最高档仍尝试压缩，必要转换尽力保真。
- (void)sc_qualityChanged {self.qualityLabel.text=[NSString stringWithFormat:@"%.2f",self.qualitySlider.value];self.qualitySlider.accessibilityLabel=@"画质一致度目标，结构、局部细节、颜色取最低，1 档目标为 0.95，全部可编码档尝试压缩";}
/// 打开图片和 Live Photo 选择。
- (void)sc_pickImage {self.choosingVideo=NO;[self sc_openPicker];}
/// 打开普通视频选择。
- (void)sc_pickVideo {self.choosingVideo=YES;[self sc_openPicker];}
/// 获取原始资源所需的相册授权后展示系统选择器。
- (void)sc_openPicker {
    if(self.saving)return;[self.view endEditing:YES];[self sc_cancel];
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus status){dispatch_async(dispatch_get_main_queue(),^{
        if(status!=PHAuthorizationStatusAuthorized&&status!=PHAuthorizationStatusLimited){self.report.text=@"未获得相册读取权限，请在系统设置中允许访问测试资源。";return;}
        // configuration：只允许单次选择，避免多任务争用编码器干扰耗时。
        PHPickerConfiguration *configuration=[[PHPickerConfiguration alloc]initWithPhotoLibrary:PHPhotoLibrary.sharedPhotoLibrary];configuration.selectionLimit=1;configuration.filter=self.choosingVideo ? PHPickerFilter.videosFilter : PHPickerFilter.imagesFilter;
        // picker：系统授权范围内的媒体选择器。
        PHPickerViewController *picker=[[PHPickerViewController alloc]initWithConfiguration:configuration];picker.delegate=self;[self presentViewController:picker animated:YES completion:nil];
    });}];
}
/// 系统选择器回调，取原始 PhotoKit 文件而不是预览图。
/// @param picker 系统选择器。
/// @param results 最多一项的选中资源。
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    // identifier：仅用于在已授权范围内定位这次选择。
    NSString *identifier=results.firstObject.assetIdentifier;if(!identifier)return;
    // asset：对应的真实相册资源。
    PHAsset *asset=[PHAsset fetchAssetsWithLocalIdentifiers:@[identifier] options:nil].firstObject;
    if(!asset){self.report.text=@"所选资源不在可读取的相册授权范围内，请补充允许访问后重试。";return;}
    // operation：隔离本次取源与旧异步回调。
    NSString *operation=NSUUID.UUID.UUIDString;self.operationID=operation;
    // folder：本次源文件与输出的唯一拥有目录。
    NSURL *folder=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:operation] isDirectory:YES];self.folder=folder;
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    // live：静态图是否带配对视频。
    BOOL live=asset.mediaType==PHAssetMediaTypeImage&&(asset.mediaSubtypes&PHAssetMediaSubtypePhotoLive);
    // resources：只选择原始 photo/video/pairedVideo，不采用本机预览缓存。
    NSMutableArray<PHAssetResource *> *resources=[NSMutableArray array];
    for(PHAssetResource *resource in [PHAssetResource assetResourcesForAsset:asset])if(resource.type==(self.choosingVideo?PHAssetResourceTypeVideo:PHAssetResourceTypePhoto)||(live&&resource.type==PHAssetResourceTypePairedVideo))[resources addObject:resource];
    if(resources.count!=(live?2:1)){self.report.text=@"未读取到完整原始资源。";[self sc_cancel];return;}
    self.progressLabel.text=@"取源中";self.report.text=@"正在读取原始资源，允许从 iCloud 下载；此阶段不计入压缩耗时。";
    // group：双资源取源的完成协调器。
    dispatch_group_t group=dispatch_group_create();
    // failure：任一原始资源读取失败的错误，在资源集合锁下写入。
    __block NSError *failure=nil;
    // imageURL：成功取出的原始静态图路径。
    __block NSURL *imageURL=nil;
    // videoURL：成功取出的原始视频路径。
    __block NSURL *videoURL=nil;
    for(PHAssetResource *resource in resources){
        // video：当前资源是否属于普通或配对视频。
        BOOL video=resource.type==PHAssetResourceTypeVideo||resource.type==PHAssetResourceTypePairedVideo;
        // url：保留原始扩展名的独立本地文件。
        NSURL *url=[folder URLByAppendingPathComponent:[(video?@"source-video":@"source-image")stringByAppendingPathExtension:resource.originalFilename.pathExtension.length?resource.originalFilename.pathExtension:@"dat"]];
        if(video)videoURL=url;else imageURL=url;
        // options：仅控制原始资源读取，不修改压缩策略。
        PHAssetResourceRequestOptions *options=[PHAssetResourceRequestOptions new];options.networkAccessAllowed=YES;
        dispatch_group_enter(group);
        [PHAssetResourceManager.defaultManager writeDataForAssetResource:resource toFile:url options:options completionHandler:^(NSError *error){if(error)@synchronized(resources){failure=error;}dispatch_group_leave(group);}];
    }
    dispatch_group_notify(group,dispatch_get_main_queue(),^{
        if(![self.operationID isEqualToString:operation]){[NSFileManager.defaultManager removeItemAtURL:folder error:nil];return;}
        if(failure){self.report.text=failure.localizedDescription;return;}
        [self sc_compressImageURL:imageURL videoURL:videoURL live:live operation:operation];
    });
}
/// 从界面生成一次不可变使用的静态图配置快照。
- (SCImageCompressionOptions *)sc_imageOptions {
    // options：静态图片与 Live 视频共享的尺寸、质量和 HDR 来源。
    SCImageCompressionOptions *options=[SCImageCompressionOptions new];options.maximumSize=CGSizeMake(self.imageSide.text.doubleValue,self.imageSide.text.doubleValue);options.quality=self.qualitySlider.value;options.format=(SCImageFormat)self.imageFormat.selectedSegmentIndex;options.preservesHDR=self.imageHDRSwitch.on;return options;
}
/// 在主线程捕获视频配置，避免编码工作队列读取 UIKit 控件。
- (void (^)(SCVideoCompressor *))sc_videoConfiguration {
    // side：仅普通视频使用的尺寸上限。
    double side=self.videoSide.text.doubleValue;
    // quality：图片、视频共同的源画质相对目标。
    double quality=self.qualitySlider.value;
    // preserve：是否保留源 HDR；库结合真实动态范围自动决定编码。
    BOOL preserve=self.videoHDRSwitch.on;
    // container：普通视频封装，Live 由调用入口保持内部 MP4 与最终 MOV 的固定配对流程。
    AVFileType container=self.videoContainer.selectedSegmentIndex?AVFileTypeQuickTimeMovie:AVFileTypeMPEG4;
    return ^(SCVideoCompressor *session){session.maximumSize=CGSizeMake(side,side);session.videoQuality=quality;session.preservesHDR=preserve;session.outputFileType=container;};
}
/// 调用公共异步 API，并在主队列显示真实文件统计。
/// @param imageURL 已取出的原始图片。
/// @param videoURL 已取出的原始视频。
/// @param live 是否为一组 Live 资源。
/// @param operation 本轮回调隔离标识。
- (void)sc_compressImageURL:(NSURL *)imageURL videoURL:(NSURL *)videoURL live:(BOOL)live operation:(NSString *)operation {
    // before：原始文件的真实元数据，Live 两个资源展示在同一阶段。
    NSMutableString *before=[NSMutableString stringWithString:@"原始\n"];
    if(imageURL)[before appendFormat:@"图片 %@ · %@\n",sc_demoByteText(sc_demoBytes(imageURL)),sc_demoImageText(imageURL)];
    if(videoURL)[before appendFormat:@"视频 %@ · %@\n",sc_demoByteText(sc_demoBytes(videoURL)),sc_demoVideoText(videoURL)];
    self.report.text=[before stringByAppendingString:@"\n正在压缩…"];self.progressView.progress=0;self.progressLabel.text=@"0%";
    // start：不包含 PhotoKit/iCloud 取源，也不包含按需预览加载。
    CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
    // videoSession：仅在完成时读取这次会话的公开转换诊断，避免把 Live 配对当转换。
    __block SCVideoCompressor *videoSession=nil;
    // configuration：先捕获控件值，再由视频阶段应用并保留本轮会话。
    void (^configuration)(SCVideoCompressor *)=[self sc_videoConfiguration];
    // configure：不修改库策略，只为 Demo 记录独立视频转换基准。
    void (^configure)(SCVideoCompressor *)=^(SCVideoCompressor *session){configuration(session);if(live)session.outputFileType=AVFileTypeMPEG4;videoSession=session;};
    // progress：不把总进度比例冒充独立的转换阶段进度。
    void (^progress)(double)=^(double value){if([self.operationID isEqualToString:operation]){self.progressView.progress=value;self.progressLabel.text=[NSString stringWithFormat:@"%.0f%%",value*100];}};
    // finish：依实际原始、转换、编码、配对顺序组织已有诊断。
    void (^finish)(NSURL *,NSURL *,NSError *)=^(NSURL *photo,NSURL *movie,NSError *error){
        // session：取出后释放 block 的持有，旧任务完成同样不会留下会话环。
        SCVideoCompressor *session=videoSession;videoSession=nil;
        if(![self.operationID isEqualToString:operation])return;
        // outcome：交付、质量及节省使用统一摘要，转换与分段耗时仍读取专项诊断。
        SCCompressionOutcome *outcome=self.task.outcome;
        // result：只报告确实已知的信息，转换阶段不虚构尺寸或独立耗时。
        NSMutableString *result=[before mutableCopy];
        if(self.task.imageUsesConvertedBaseline && self.task.imageComparisonBytes){[result appendFormat:@"转换\n图片实际基准%@：%@\n",live?@"（配对后）":@"",sc_demoByteText(self.task.imageComparisonBytes)];}
        if(session.conversionBytes){if(!self.task.imageUsesConvertedBaseline)[result appendString:@"转换\n"];[result appendFormat:@"视频首次转换%@：%@\n",live?@"（配对前）":@"",sc_demoByteText(session.conversionBytes)];}
        [result appendString:error?@"压缩失败":(live?@"压缩":(photo?@"压缩结果":@"压缩结果"))];
        [result appendString:sc_demoImagePerformanceText(self.task.imagePerformance)];
        if(session.stageDurations.count){
            // durations：公开视频计时不拆分共享的转换和压缩编码。
            NSDictionary *durations=session.stageDurations;
            [result appendFormat:@"\n视频编码 %lu 次 · 准备 %.3fs / 编码 %.3fs / 收尾 %.3fs",(unsigned long)session.encodingPassCount,[durations[@"prepare"]doubleValue],[durations[@"compress"]doubleValue],[durations[@"finish"]doubleValue]];
        }
        if(error&&self.task.imagePerformance.stageDurations[@"pair"].doubleValue>0)[result appendFormat:@"\nJPEG 重写 %lu 次 · 配对 %.3fs",(unsigned long)self.task.imagePerformance.pairingEncodingPassCount,self.task.imagePerformance.stageDurations[@"pair"].doubleValue];
        if(error){self.progressLabel.text=@"失败";[result appendFormat:@"\n%@\n未交付结果，不计算节省比例。",error.localizedDescription];[self sc_showReport:result];return;}
        self.outputImage=photo;self.outputVideo=movie;self.saveButton.enabled=YES;self.playButton.enabled=YES;self.progressLabel.text=@"完成 100%";
        if(photo){
            [result appendFormat:@"\n图片保真 %.2f→%.2f · %@",self.task.imageRequestedQuality,self.task.imageEffectiveQualityTarget,outcome.imageQualityStatus==SCImageQualityStatusMet?@"达标":outcome.imageQualityStatus==SCImageQualityStatusNotMet?@"未达标，尽力输出":@"未评分"];
            if(outcome.imageFidelityScore)[result appendFormat:@" · 评分 %.4f",outcome.imageFidelityScore.doubleValue];
        }
        if(movie){
            if(live)[result appendFormat:@"\n视频保真 · %@",outcome.videoQualityStatus==SCVideoQualityStatusMet?@"达标":outcome.videoQualityStatus==SCVideoQualityStatusNotMet?@"未达标，尽力输出":@"未评估"];
            else [result appendFormat:@"\n视频保真 %.2f→%.2f · %@",self.task.videoRequestedQuality,self.task.videoEffectiveQualityTarget,outcome.videoQualityStatus==SCVideoQualityStatusMet?@"达标":outcome.videoQualityStatus==SCVideoQualityStatusNotMet?@"未达标，尽力输出":@"未评估"];
            if(outcome.videoFidelityScore)[result appendFormat:@" %.3f",outcome.videoFidelityScore.doubleValue];
            [result appendFormat:@" · %@ · 评估 %.3fs",self.task.videoQualitySampleCount?[NSString stringWithFormat:@"抽样%lu帧",(unsigned long)self.task.videoQualitySampleCount]:(outcome.videoQualityStatus==SCVideoQualityStatusMet?@"原内容基准":@"未完成抽样"),self.task.videoQualityEvaluationDuration];
        }
        if(live)[result appendFormat:@"\nLive 配对与最终结果\nJPEG 重写 %lu 次 · JPEG %.3fs / 整组配对 %.3fs",(unsigned long)self.task.imagePerformance.pairingEncodingPassCount,[self.task.imagePerformance.stageDurations[@"pair"]doubleValue],[self.task.stageDurations[@"pair"]doubleValue]];
        if(photo)[result appendFormat:@"\n图片 %@ · %@",sc_demoByteText(sc_demoBytes(photo)),sc_demoImageText(photo)];
        if(movie)[result appendFormat:@"\n视频 %@ · %@",sc_demoByteText(sc_demoBytes(movie)),sc_demoVideoText(movie)];
        // baselineBytes：Live 使用最终配对后的合计基准，普通资源使用自己的实际基准。
        unsigned long long baselineBytes=outcome.baselineBytes;
        // outputBytes：只合计本轮实际交付的文件。
        unsigned long long outputBytes=outcome.outputBytes;
        if(outcome.savedRatio)[result appendFormat:@"\n%@ %@ · 节省 %.2f%%",live?@"配对整组基准":@"比较基准",sc_demoByteText(baselineBytes),outcome.savedRatio.doubleValue*100];
        else [result appendString:@"\n实际文件基准未知，不计算节省比例。"];
        if(!live&&movie&&baselineBytes&&!self.task.usesConvertedBaseline&&outputBytes==baselineBytes)[result appendString:@"\n无体积收益，返回合规原视频副本。"];
        [result appendFormat:@"\n总耗时 %.3fs（不含取源/预览） · 尚未保存",CFAbsoluteTimeGetCurrent()-start];[self sc_showReport:result];
    };
    if(live)self.task=[SCMediaCompressor sc_compressLivePhotoImageURL:imageURL videoURL:videoURL outputDirectory:self.folder imageOptions:[self sc_imageOptions] configureVideo:configure progress:progress completion:finish];
    else if(videoURL)self.task=[SCMediaCompressor sc_compressVideoAsset:[AVAsset assetWithURL:videoURL] outputURL:[self.folder URLByAppendingPathComponent:(self.videoContainer.selectedSegmentIndex?@"compressed.mov":@"compressed.mp4")] configure:configure progress:progress completion:^(NSURL *movie,NSError *error){finish(nil,movie,error);}];
    else self.task=[SCMediaCompressor sc_compressImageData:[NSData dataWithContentsOfURL:imageURL] options:[self sc_imageOptions] progress:progress completion:^(NSData *data,NSError *error){
        if(![self.operationID isEqualToString:operation])return;
        // output：与实际编码一致的扩展名，保存为文件后交给 PhotoKit。
        NSURL *output=data ? [self.folder URLByAppendingPathComponent:[@"compressed" stringByAppendingPathExtension:[SCImageCompressor sc_fileExtensionForData:data]]] : nil;
        // failure：压缩或写入失败原因。
        NSError *failure=error;if(data&&![data writeToURL:output options:NSDataWritingAtomic error:&failure])output=nil;finish(output,nil,failure);
    }];
}
/// 用加粗阶段标题替代空白行，保留更多可见结果空间。
/// @param text 按实际处理顺序组织的只读信息。
- (void)sc_showReport:(NSString *)text {
    // report：仅格式化已有文本，不执行额外媒体工作。
    NSMutableAttributedString *report=[[NSMutableAttributedString alloc]initWithString:text attributes:@{NSFontAttributeName:self.report.font,NSForegroundColorAttributeName:UIColor.labelColor}];
    // headings：只突出阶段边界，正文中的相同词语不作处理。
    NSSet *headings=[NSSet setWithArray:@[@"原始",@"转换",@"压缩",@"压缩结果",@"压缩失败",@"Live 配对与最终结果"]];
    [text enumerateSubstringsInRange:NSMakeRange(0,text.length) options:NSStringEnumerationByLines usingBlock:^(NSString *line,NSRange range,NSRange enclosingRange,BOOL *stop){if([headings containsObject:line])[report addAttribute:NSFontAttributeName value:[UIFont boldSystemFontOfSize:12] range:range];}];
    self.report.attributedText=report;[self.report setContentOffset:CGPointZero animated:NO];
}
/// 显式保存使用两个文件资源，保持其生命周期直到 Photos 完成。
- (void)sc_save {
    if(self.saving||(!self.outputImage&&!self.outputVideo))return;self.saving=YES;self.saveButton.enabled=NO;
    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
        // request：Live 的图片和视频必须属于同一个相册创建请求。
        PHAssetCreationRequest *request=[PHAssetCreationRequest creationRequestForAsset];
        if(self.outputImage)[request addResourceWithType:PHAssetResourceTypePhoto fileURL:self.outputImage options:nil];
        if(self.outputVideo)[request addResourceWithType:self.outputImage?PHAssetResourceTypePairedVideo:PHAssetResourceTypeVideo fileURL:self.outputVideo options:nil];
    } completionHandler:^(BOOL success,NSError *error){dispatch_async(dispatch_get_main_queue(),^{self.saving=NO;self.saveButton.enabled=YES;self.report.text=[self.report.text stringByAppendingFormat:@"\n\n%@",success?@"已保存到相册。":error.localizedDescription?:@"保存失败。"];});}];
}
/// 点击后才加载压缩结果，静态图、视频和 Live 分别使用原生预览。
- (void)sc_play {
    if(self.outputImage){
        // preview：独立页面承载图片或配对 Live，不挤占统计区。
        SCDemoPreviewController *preview=[SCDemoPreviewController new];preview.imageURL=self.outputImage;preview.videoURL=self.outputVideo;
        [self presentViewController:[[UINavigationController alloc]initWithRootViewController:preview] animated:YES completion:nil];return;
    }
    if(!self.outputVideo)return;
    // player：仅在主动预览时读取本轮已完成的视频。
    AVPlayerViewController *player=[AVPlayerViewController new];player.player=[AVPlayer playerWithURL:self.outputVideo];[self presentViewController:player animated:YES completion:^{[player.player play];}];
}
/// 取消任务并隔离旧回调；保存中不删除 PhotoKit 正在读取的资源。
- (void)sc_cancel {
    if(self.saving)return;self.operationID=nil;[self.task sc_cancel];self.task=nil;
    // folder：只清理本轮拥有的目录，不删除相册源文件。
    NSURL *folder=self.folder;
    if(folder)[NSFileManager.defaultManager removeItemAtURL:folder error:nil];self.folder=nil;
    self.outputImage=nil;self.outputVideo=nil;self.saveButton.enabled=NO;self.playButton.enabled=NO;self.progressView.progress=0;self.progressLabel.text=@"已清理";
    self.report.text=@"已取消并清理本次临时结果。请选择图片、视频或 Live Photo 进行对比。";
}
@end
