// SPDX-License-Identifier: GPL-3.0-or-later
// Hello World: one screen, one label, plus one line from a helper TrollStore lets us run as root. UIKit, no storyboard, no Xcode.
#import <UIKit/UIKit.h>
#include <spawn.h>

// Private libsystem calls TrollStore uses to spawn as root (persona 99, uid/gid 0).
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t);
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t);
extern char **environ;

static NSString *rootLine(void) {
    NSString *path = [NSBundle.mainBundle pathForResource:@"roothelper" ofType:nil];
    int fds[2]; pipe(fds);
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawnattr_t attr; posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid; char *argv[] = {(char *)path.UTF8String, NULL};
    int err = posix_spawn(&pid, argv[0], &fa, &attr, argv, environ);
    close(fds[1]);
    if (err) { close(fds[0]); return [NSString stringWithFormat:@"root: spawn failed (%d)", err]; }
    char buf[256] = {0}; ssize_t n = read(fds[0], buf, sizeof buf - 1); close(fds[0]);
    int st; waitpid(pid, &st, 0);
    NSString *out = n > 0 ? [[NSString stringWithUTF8String:buf] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] : @"no output";
    return [@"root: " stringByAppendingString:out];
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(24, 0, vc.view.bounds.size.width - 48, vc.view.bounds.size.height)];
    label.text = [@"hello, world. Trollstore is working. Now gfy and rtfm.\n\n" stringByAppendingString:rootLine()];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.font = [UIFont boldSystemFontOfSize:32];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:label];

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
