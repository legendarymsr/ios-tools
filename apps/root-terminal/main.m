// SPDX-License-Identifier: GPL-3.0-or-later
// Hello World terminal: UITextView + input, root shell via TrollStore persona spawn.
#import <UIKit/UIKit.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t);
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t);
extern char **environ;

static int rootSpawn(char *const argv[], int *outfd) {
    int fds[2]; pipe(fds);
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDERR_FILENO);
    posix_spawnattr_t attr; posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid; int err = posix_spawn(&pid, argv[0], &fa, &attr, argv, environ);
    close(fds[1]);
    if (err) { close(fds[0]); return -err; }
    *outfd = fds[0];
    int st; waitpid(pid, &st, 0);
    return 0;
}

static NSString *rootRun(NSString *script) {
    NSString *bash = @"/var/jb/usr/bin/bash";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:bash]) bash = @"/bin/sh";
    char *argv[] = { (char *)bash.UTF8String, "-lc", (char *)script.UTF8String, NULL };
    int fd = -1;
    if (rootSpawn(argv, &fd) != 0 || fd < 0) return @"[spawn failed]\n";
    NSMutableData *data = [NSMutableData data];
    char buf[4096]; ssize_t n;
    while ((n = read(fd, buf, sizeof buf)) > 0) [data appendBytes:buf length:(NSUInteger)n];
    close(fd);
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return s ?: @"[binary output]\n";
}

@interface TermVC : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextView *outView;
@property (nonatomic, strong) UITextField *inp;
@end

@implementation TermVC
- (void)append:(NSString *)s {
    self.outView.text = [self.outView.text stringByAppendingString:s ?: @""];
    NSUInteger len = self.outView.text.length;
    if (len > 0) [self.outView scrollRangeToVisible:NSMakeRange(len - 1, 1)];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGFloat kb = 36, pad = 8;

    self.outView = [[UITextView alloc] initWithFrame:CGRectMake(0, 50, w, h - 50 - kb - pad * 2)];
    self.outView.editable = NO;
    self.outView.backgroundColor = UIColor.blackColor;
    self.outView.textColor = [UIColor colorWithRed:0.7 green:1 blue:0.7 alpha:1];
    self.outView.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.outView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.outView.text = @"Root Terminal (TrollStore root)\nType a command, or: fastfetch / dnf --version\n\n";
    [self.view addSubview:self.outView];

    UILabel *prompt = [[UILabel alloc] initWithFrame:CGRectMake(pad, h - kb - pad, 20, kb)];
    prompt.text = @"#";
    prompt.textColor = [UIColor colorWithRed:0.7 green:1 blue:0.7 alpha:1];
    prompt.font = self.outView.font;
    prompt.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:prompt];

    self.inp = [[UITextField alloc] initWithFrame:CGRectMake(pad + 22, h - kb - pad, w - pad * 2 - 22, kb)];
    self.inp.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    self.inp.textColor = UIColor.whiteColor;
    self.inp.font = self.outView.font;
    self.inp.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.inp.autocorrectionType = UITextAutocorrectionTypeNo;
    self.inp.keyboardType = UIKeyboardTypeASCIICapable;
    self.inp.returnKeyType = UIReturnKeySend;
    self.inp.delegate = self;
    self.inp.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.inp];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *bundle = NSBundle.mainBundle.bundlePath;
        NSString *setup = [NSString stringWithFormat:
            @"set -e; B='%@'; "
            @"mkdir -p /var/jb/usr/local/bin /var/jb/dnfroot/var/lib/dnf/installed /var/jb/dnfroot/var/cache/dnf; "
            @"cp -f \"$B/fastfetch\" \"$B/rpm2cpio\" \"$B/rpm2cpio.py\" \"$B/dnf\" /var/jb/usr/local/bin/; "
            @"chmod 755 /var/jb/usr/local/bin/fastfetch /var/jb/usr/local/bin/rpm2cpio /var/jb/usr/local/bin/rpm2cpio.py /var/jb/usr/local/bin/dnf; "
            @"echo fastfetch-ios-tools-native > /var/jb/dnfroot/var/lib/dnf/installed/fastfetch; "
            @"export PATH=/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:$PATH; "
            @"command -v curl >/dev/null || apt-get install -y curl cpio gzip xz-utils zstd 2>/dev/null || true; "
            @"echo setup-ok; fastfetch; echo; dnf --version; echo; dnf list installed", bundle];
        NSString *r = rootRun(setup);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self append:r];
            [self.inp becomeFirstResponder];
        });
    });
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    NSString *cmd = [tf.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    tf.text = @"";
    if (cmd.length == 0) return NO;
    [self append:[NSString stringWithFormat:@"# %@\n", cmd]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *script = [NSString stringWithFormat:
            @"export PATH=/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin; "
            @"export DNFROOT=/var/jb/dnfroot; export USER=root HOME=/var/root; %@", cmd];
        NSString *r = rootRun(script);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self append:r];
            if (r.length == 0 || [r characterAtIndex:r.length - 1] != '\n') [self append:@"\n"];
        });
    });
    return NO;
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [TermVC new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
