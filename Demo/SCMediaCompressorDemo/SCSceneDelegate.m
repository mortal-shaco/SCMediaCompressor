#import <UIKit/UIKit.h>
#import "SCDemoViewController.h"
/// Demo 的独立窗口容器。
@interface SCSceneDelegate : UIResponder <UIWindowSceneDelegate>
/// 持有本窗口及其压缩对比控制器。
@property (nonatomic,strong) UIWindow *window;
@end
@implementation SCSceneDelegate
/// 系统 Scene 初始化回调。
/// @param scene 当前窗口场景。
/// @param session 当前场景会话。
/// @param options 场景连接上下文。
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if(![scene isKindOfClass:UIWindowScene.class])return;
    self.window=[[UIWindow alloc]initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController=[[UINavigationController alloc]initWithRootViewController:[SCDemoViewController new]];
    [self.window makeKeyAndVisible];
}
@end
