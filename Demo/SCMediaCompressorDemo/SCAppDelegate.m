#import <UIKit/UIKit.h>
/// Demo 应用生命周期，不包含业务服务器或账号配置。
@interface SCAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation SCAppDelegate
/// 系统 Scene 配置回调，显式使用 Demo 的 SceneDelegate。
/// @param application 系统应用对象。
/// @param session 新连接的窗口会话。
/// @param options 启动上下文。
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    // configuration：本窗口使用的控制器配置。
    UISceneConfiguration *configuration=[[UISceneConfiguration alloc]initWithName:@"Demo" sessionRole:session.role];
    configuration.delegateClass=NSClassFromString(@"SCSceneDelegate");return configuration;
}
@end
