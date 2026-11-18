#import "PDUI.h"
#import "PDStore.h"
#import "PDHostServer.h"
#import "PDTargets.h"
#import "PDPatch.h"
#import "PdProtocol.h"
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - 日志中心

@interface PDLogCenter ()
@property (nonatomic, strong) NSMutableArray<NSString *> *lines;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation PDLogCenter

+ (instancetype)shared {
    static PDLogCenter *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PDLogCenter new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lines = [NSMutableArray array];
        _lock = [NSLock new];
    }
    return self;
}

- (void)add:(NSString *)line {
    if (line.length == 0) return;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *stamped = [NSString stringWithFormat:@"%@  %@", [df stringFromDate:[NSDate date]], line];

    [_lock lock];
    [_lines addObject:stamped];
    if (_lines.count > 600) [_lines removeObjectsInRange:NSMakeRange(0, _lines.count - 600)];
    [_lock unlock];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"PDLogChanged" object:nil];
    });
}

- (NSString *)text {
    [_lock lock];
    NSString *t = [_lines componentsJoinedByString:@"\n"];
    [_lock unlock];
    return t;
}

@end

#pragma mark - 后台保活

/// 容器 App 一旦进后台被挂起，脚本服务器就断了。
/// 用一条静音音频把自己钉在后台（Info.plist 里要 UIBackgroundModes: audio）。
@interface PDKeepAlive : NSObject
@property (nonatomic, strong) AVAudioPlayer *player;
+ (instancetype)shared;
- (void)start;
@end

@implementation PDKeepAlive

+ (instancetype)shared {
    static PDKeepAlive *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PDKeepAlive new]; });
    return s;
}

/// 生成 1 秒 8kHz 单声道静音 WAV
static NSData *pd_silent_wav(void) {
    const int rate = 8000, seconds = 1, channels = 1, bits = 16;
    const int dataSize = rate * seconds * channels * bits / 8;
    NSMutableData *d = [NSMutableData data];

    uint32_t u32; uint16_t u16;
    [d appendBytes:"RIFF" length:4];
    u32 = (uint32_t)(36 + dataSize); [d appendBytes:&u32 length:4];
    [d appendBytes:"WAVEfmt " length:8];
    u32 = 16; [d appendBytes:&u32 length:4];
    u16 = 1;  [d appendBytes:&u16 length:2];
    u16 = channels; [d appendBytes:&u16 length:2];
    u32 = rate; [d appendBytes:&u32 length:4];
    u32 = rate * channels * bits / 8; [d appendBytes:&u32 length:4];
    u16 = channels * bits / 8; [d appendBytes:&u16 length:2];
    u16 = bits; [d appendBytes:&u16 length:2];
    [d appendBytes:"data" length:4];
    u32 = dataSize; [d appendBytes:&u32 length:4];
    [d appendData:[NSMutableData dataWithLength:dataSize]];
    return d;
}

- (void)start {
    if (_player) return;
    NSError *e = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback
       withOptions:AVAudioSessionCategoryOptionMixWithOthers
             error:&e];
    [s setActive:YES error:&e];

    _player = [[AVAudioPlayer alloc] initWithData:pd_silent_wav() error:&e];
    if (!_player) {
        [[PDLogCenter shared] add:[NSString stringWithFormat:@"后台保活失败: %@", e.localizedDescription]];
        return;
    }
    _player.numberOfLoops = -1;
    _player.volume = 0.0;
    [_player play];
    [[PDLogCenter shared] add:@"后台保活已开启（静音音频）"];
}

@end

#pragma mark - 脚本编辑

@interface PDEditorVC : UIViewController <UITextViewDelegate>
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) UITextView *textView;
@end

@implementation PDEditorVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = self.name;

    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    _textView.autocorrectionType = UITextAutocorrectionTypeNo;
    _textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _textView.keyboardType = UIKeyboardTypeASCIICapable;
    _textView.text = [[NSString alloc] initWithData:[[PDStore shared] dataForName:self.name]
                                           encoding:NSUTF8StringEncoding] ?: @"";
    _textView.contentInset = UIEdgeInsetsMake(8, 4, 8, 4);
    [self.view addSubview:_textView];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(save)];
}

- (void)save {
    NSData *d = [self.textView.text dataUsingEncoding:NSUTF8StringEncoding];
    BOOL ok = [[PDStore shared] writeData:d name:self.name];
    [[PDLogCenter shared] add:[NSString stringWithFormat:@"%@ %@（%lu 字节）",
                               ok ? @"已保存" : @"保存失败", self.name, (unsigned long)d.length]];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - 脚本列表

@interface PDScriptsVC : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@end

@implementation PDScriptsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"脚本";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self action:@selector(newScript)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                      target:self action:@selector(importFile)];
    [self reload];
}

- (void)reload {
    self.items = [[PDStore shared] files];
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)newScript {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"新建脚本"
                                                              message:@"hack.js（自带 JSC）· hack.pjs（跑游戏自己的 PuerTS，能用 CS.*）· hack.lua"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"main.js"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *name = a.textFields.firstObject.text;
        if (name.length == 0) return;
        NSString *ext = name.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"js"] && ![ext isEqualToString:@"lua"] && ![ext isEqualToString:@"pjs"])
            name = [name stringByAppendingString:@".js"];

        name = [[PDStore shared] uniqueNameFor:name];
        NSString *tpl = [name.pathExtension isEqualToString:@"lua"]
            ? @"function on_tick(dt)\n  -- native.log('tick')\nend\n"
            : @"onTick(function (dt) {\n  // console.log(dt);\n});\n";
        [[PDStore shared] writeData:[tpl dataUsingEncoding:NSUTF8StringEncoding] name:name];
        [[PDLogCenter shared] add:[NSString stringWithFormat:@"已新建 %@", name]];
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)importFile {
    UIDocumentPickerViewController *p =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    p.delegate = self;
    p.allowsMultipleSelection = YES;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *u in urls) {
        NSString *ext = u.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"js"] && ![ext isEqualToString:@"lua"] && ![ext isEqualToString:@"pjs"]) {
            [[PDLogCenter shared] add:[NSString stringWithFormat:@"跳过 %@：只收 .js / .lua / .pjs", u.lastPathComponent]];
            continue;
        }
        BOOL scoped = [u startAccessingSecurityScopedResource];
        NSData *d = [NSData dataWithContentsOfURL:u];
        if (scoped) [u stopAccessingSecurityScopedResource];

        if (!d) {
            [[PDLogCenter shared] add:[NSString stringWithFormat:@"读不到 %@", u.lastPathComponent]];
            continue;
        }
        NSString *name = [[PDStore shared] uniqueNameFor:u.lastPathComponent];
        [[PDStore shared] writeData:d name:name];
        [[PDLogCenter shared] add:[NSString stringWithFormat:@"已导入 %@（%lu 字节）",
                                   name, (unsigned long)d.length]];
    }
    [self reload];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSDictionary *f = self.items[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%@  ·  %@", f[@"name"], f[@"lang"]];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%lld 字节", [f[@"size"] longLongValue]];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"编辑" forState:UIControlStateNormal];
    btn.frame = CGRectMake(0, 0, 56, 32);
    btn.tag = ip.row;
    [btn addTarget:self action:@selector(editTapped:) forControlEvents:UIControlEventTouchUpInside];
    c.accessoryView = btn;
    return c;
}

- (void)editTapped:(UIButton *)b {
    PDEditorVC *e = [PDEditorVC new];
    e.name = self.items[b.tag][@"name"];
    [self.navigationController pushViewController:e animated:YES];
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style == UITableViewCellEditingStyleDelete) {
        NSString *name = self.items[ip.row][@"name"];
        [[PDStore shared] deleteName:name];
        [[PDLogCenter shared] add:[NSString stringWithFormat:@"已删除 %@", name]];
        [self reload];
    }
}

@end

#pragma mark - 目标 App


#pragma mark - 选择脚本

@interface PDScriptSelectVC : UITableViewController
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, strong) NSMutableSet<NSString *> *picked;
@property (nonatomic, copy) void (^onDone)(NSArray<NSString *> *names);
@end

@implementation PDScriptSelectVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"这个 App 加载哪些脚本";
    self.items = [[PDStore shared] files];
    self.picked = [NSMutableSet set];

    NSArray *saved = [[PDStore shared] selectionForBundle:self.bundleId];
    if (saved) [self.picked addObjectsFromArray:saved];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(save)];
}

- (void)save {
    NSArray *names = self.picked.allObjects;
    if (names.count == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"一个都没选"
                                                                  message:@"至少要选一个脚本，否则目标 App 里没有可执行的东西。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    /* 全选 = 不记录绑定（以后新增脚本自动带上） */
    BOOL all = (names.count == self.items.count);
    [[PDStore shared] setSelection:(all ? nil : names) forBundle:self.bundleId];

    if (self.onDone) self.onDone(all ? nil : names);
    [self.navigationController popViewControllerAnimated:YES];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.items.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSDictionary *f = self.items[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%@  ·  %@", f[@"name"], f[@"lang"]];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%lld 字节", [f[@"size"] longLongValue]];
    c.accessoryType = [self.picked containsObject:f[@"name"]] ? UITableViewCellAccessoryCheckmark
                                                              : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *name = self.items[ip.row][@"name"];
    if ([self.picked containsObject:name]) [self.picked removeObject:name];
    else [self.picked addObject:name];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}

@end

@interface PDTargetsVC : UITableViewController
@property (nonatomic, strong) NSArray<PDTarget *> *apps;
@property (nonatomic, strong) NSArray<NSDictionary *> *clients;
@end

@implementation PDTargetsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"注入";
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    self.apps = [PDTargets installedApps];
    self.clients = [[PDHostServer shared] clients];
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"准备（一次性）" : @"已安装 App";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) {
        return @"点目标 App 右边的「部署」→「注入并同步」，注入 + 同步一次完成。\n"
                "注入会备份原可执行文件，随时可以还原；失败自动回滚。";
    }
    return @"「部署」→「同步脚本」把脚本写进目标沙盒，目标 App 不用在运行。\n"
            "「选择脚本…」可以给每个 App 绑定不同的脚本。\n"
            "点这一行 = attach 注入，只有越狱设备才成功。";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 2 : self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    c.accessoryView = nil;
    c.textLabel.textColor = UIColor.labelColor;

    if (ip.section == 0) {
        if (ip.row == 0) {
            BOOL has = [PDTargets payloadPath] != nil;
            c.textLabel.text = @"导出 PandoraLoader.dylib（手动备用）";
            c.detailTextLabel.text = has ? @"想手动用 TrollFools 时用 · 导出到本 App 的 Documents" : @"包里没有 dylib，打包脚本没跑对";
            c.textLabel.textColor = has ? UIColor.labelColor : UIColor.systemRedColor;
            c.accessoryType = has ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        } else {
            c.textLabel.text = [PDHostServer shared].running
                ? [NSString stringWithFormat:@"脚本服务器 127.0.0.1:%d · %lu 个客户端",
                   [PDHostServer shared].port, (unsigned long)self.clients.count]
                : @"脚本服务器未启动";
            c.detailTextLabel.text = @"可选：容器 App 在后台时走 socket 实时热更新";
        }
        return c;
    }

    PDTarget *t = self.apps[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%@%@", t.name, t.running ? @"  ●" : @""];
    c.textLabel.textColor = t.running ? UIColor.labelColor : UIColor.secondaryLabelColor;
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@%@", t.bundleId,
                               t.running ? [NSString stringWithFormat:@"  pid %d", t.pid] : @"  未运行"];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"部署" forState:UIControlStateNormal];
    btn.frame = CGRectMake(0, 0, 56, 32);
    btn.tag = ip.row;
    [btn addTarget:self action:@selector(deployTapped:) forControlEvents:UIControlEventTouchUpInside];
    c.accessoryView = btn;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 0 && ip.row == 0) {
        NSString *err = nil;
        NSString *path = [PDTargets exportPayload:&err];
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:(path ? @"已导出" : @"导出失败")
                             message:(path ?: err)
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        if (path) [[PDLogCenter shared] add:[NSString stringWithFormat:@"dylib 已导出: %@", path]];
        return;
    }

    if (ip.section != 1) return;

    PDTarget *t = self.apps[ip.row];
    if (!t.running) {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"App 没在运行"
                             message:@"attach 注入需要目标先启动。\n静态注入不需要这一步，用「同步」即可。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    [[PDLogCenter shared] add:[NSString stringWithFormat:@"尝试 attach 注入 %@ (pid %d)", t.bundleId, t.pid]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *msg = nil;
        BOOL ok = [PDTargets inject:t error:&msg];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[PDLogCenter shared] add:[NSString stringWithFormat:@"%@：%@", ok ? @"注入成功" : @"注入失败", msg ?: @""]];
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:(ok ? @"注入成功" : @"attach 注入失败")
                                 message:msg
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            [self reload];
        });
    });
}

- (void)deployTapped:(UIButton *)b {
    PDTarget *t = self.apps[b.tag];
    BOOL injected = [PDPatch isInjected:t];
    NSArray *saved = [[PDStore shared] selectionForBundle:t.bundleId];

    NSString *title = [NSString stringWithFormat:@"%@%@", t.name, injected ? @"（已注入）" : @""];
    NSString *msg = injected
        ? [NSString stringWithFormat:@"脚本绑定：%@", saved ? [saved componentsJoinedByString:@", "] : @"全部"]
        : @"还没注入。选「注入并同步」会修改目标的可执行文件并重签；原文件自动备份，失败自动回滚。";

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:(injected ? @"同步脚本" : @"注入并同步")
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *a) {
        if (injected) [self syncOnly:t button:b];
        else [self confirmInject:t button:b];
    }]];

    if (!injected) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"只同步脚本（暂不注入）"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) { [self syncOnly:t button:b]; }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"选择脚本…"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        PDScriptSelectVC *v = [PDScriptSelectVC new];
        v.bundleId = t.bundleId;
        v.onDone = ^(NSArray<NSString *> *names) {
            (void)names;
            [[PDLogCenter shared] add:[NSString stringWithFormat:@"%@ 的脚本绑定已更新", t.name]];
        };
        [self.navigationController pushViewController:v animated:YES];
    }]];

    if ([PDPatch hasBackup:t]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"还原（撤销注入）"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *a) { [self confirmRestore:t]; }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    /* iPad 上 ActionSheet 需要锚点 */
    sheet.popoverPresentationController.sourceView = b;
    sheet.popoverPresentationController.sourceRect = b.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmInject:(PDTarget *)t button:(UIButton *)b {
    UIAlertController *c = [UIAlertController
        alertControllerWithTitle:@"确认修改目标 App？"
                         message:[NSString stringWithFormat:
                                  @"将对 %@ 做三件事：\n"
                                  @"  · 把 dylib 拷进 Frameworks/\n"
                                  @"  · 往可执行文件加一条 LC_LOAD_DYLIB\n"
                                  @"  · 重签 + 打 CoreTrust 补丁\n\n"
                                  @"原可执行文件会备份成 .pandora.bak；\n"
                                  @"失败自动回滚；随时可以「还原」。\n"
                                  @"目标正在运行的话会被结束。", t.bundleId]
                  preferredStyle:UIAlertControllerStyleAlert];
    [c addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [c addAction:[UIAlertAction actionWithTitle:@"继续" style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction *a) {
        b.enabled = NO;
        [b setTitle:@"…" forState:UIControlStateNormal];
        [[PDLogCenter shared] add:[NSString stringWithFormat:@"开始注入 %@", t.bundleId]];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *msg = nil;
            BOOL ok = [PDPatch inject:t error:&msg];
            dispatch_async(dispatch_get_main_queue(), ^{
                b.enabled = YES;
                [b setTitle:@"部署" forState:UIControlStateNormal];
                [[PDLogCenter shared] add:[NSString stringWithFormat:@"%@：%@", ok ? @"注入成功" : @"注入失败", msg ?: @""]];

                UIAlertController *r = [UIAlertController
                    alertControllerWithTitle:(ok ? @"注入成功" : @"注入失败")
                                     message:msg
                              preferredStyle:UIAlertControllerStyleAlert];
                [r addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:r animated:YES completion:nil];

                if (ok) [self syncOnly:t button:b];
                [self reload];
            });
        });
    }]];
    [self presentViewController:c animated:YES completion:nil];
}

- (void)syncOnly:(PDTarget *)t button:(UIButton *)b {
    b.enabled = NO;
    [b setTitle:@"…" forState:UIControlStateNormal];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *msg = nil;
        BOOL ok = [PDTargets syncScripts:t error:&msg];
        dispatch_async(dispatch_get_main_queue(), ^{
            b.enabled = YES;
            [b setTitle:@"部署" forState:UIControlStateNormal];
            [[PDLogCenter shared] add:[NSString stringWithFormat:@"同步 %@：%@", t.name, msg ?: @""]];
            if (!ok) {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"同步失败"
                                                                          message:msg
                                                                   preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:a animated:YES completion:nil];
            }
        });
    });
}

- (void)confirmRestore:(PDTarget *)t {
    UIAlertController *c = [UIAlertController
        alertControllerWithTitle:@"还原到注入前？"
                         message:@"会用 .pandora.bak 覆盖可执行文件，并删掉 Frameworks 里的 dylib。脚本目录保留。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [c addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [c addAction:[UIAlertAction actionWithTitle:@"还原" style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction *a) {
        NSString *msg = nil;
        BOOL ok = [PDPatch restore:t error:&msg];
        [[PDLogCenter shared] add:[NSString stringWithFormat:@"还原 %@：%@", t.name, msg ?: @""]];

        UIAlertController *r = [UIAlertController alertControllerWithTitle:(ok ? @"已还原" : @"还原失败")
                                                                  message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [r addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:r animated:YES completion:nil];
        [self reload];
    }]];
    [self presentViewController:c animated:YES completion:nil];
}

@end

#pragma mark - 日志

@interface PDLogsVC : UIViewController
@property (nonatomic, strong) UITextView *tv;
@end

@implementation PDLogsVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"日志";

    _tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.editable = NO;
    _tv.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    _tv.textContainerInset = UIEdgeInsetsMake(8, 4, 8, 4);
    [self.view addSubview:_tv];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(clear)];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh)
                                                 name:@"PDLogChanged" object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)refresh {
    _tv.text = [PDLogCenter shared].text;
    if (_tv.text.length) {
        [_tv scrollRangeToVisible:NSMakeRange(_tv.text.length - 1, 1)];
    }
}

- (void)clear {
    _tv.text = @"";
}

@end

#pragma mark - AppDelegate

@implementation PDAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    UITabBarController *tab = [UITabBarController new];

    UINavigationController *n1 = [[UINavigationController alloc] initWithRootViewController:[PDScriptsVC new]];
    n1.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"脚本" image:[UIImage systemImageNamed:@"doc.text"] tag:0];

    UINavigationController *n2 = [[UINavigationController alloc] initWithRootViewController:[PDTargetsVC new]];
    n2.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"注入" image:[UIImage systemImageNamed:@"bolt.fill"] tag:1];

    UINavigationController *n3 = [[UINavigationController alloc] initWithRootViewController:[PDLogsVC new]];
    n3.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"日志" image:[UIImage systemImageNamed:@"terminal"] tag:2];

    tab.viewControllers = @[n1, n2, n3];
    self.window.rootViewController = tab;
    [self.window makeKeyAndVisible];

    [[PDStore shared] seedIfEmpty];
    [[PDKeepAlive shared] start];

    NSString *err = nil;
    if (![[PDHostServer shared] startOnPort:PD_PORT error:&err]) {
        [[PDLogCenter shared] add:[NSString stringWithFormat:@"服务器启动失败: %@", err]];
    } else {
        [[PDLogCenter shared] add:[NSString stringWithFormat:@"脚本服务器 http://127.0.0.1:%d", PD_PORT]];
        [[PDLogCenter shared] add:[NSString stringWithFormat:@"脚本目录: %@", [PDStore shared].dir]];
    }

    [PDHostServer shared].logSink = ^(NSString *line) {
        [[PDLogCenter shared] add:[NSString stringWithFormat:@"[注入端] %@", line]];
    };
    [PDHostServer shared].stateSink = ^(NSDictionary *st) {
        [[PDLogCenter shared] add:[NSString stringWithFormat:@"[心跳] %@ v%@ pid%@ %@",
                                   st[@"bid"], st[@"ver"], st[@"pid"], st[@"msg"] ?: @""]];
    };

    return YES;
}

@end
