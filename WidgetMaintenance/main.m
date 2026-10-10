#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import <libproc.h>
#import <sys/proc_info.h>

// A narrow, non-privileged XPC interface. No caller-supplied paths, commands,
// process IDs, network requests or access to the user's launcher configuration.
@protocol LauncherWidgetMaintenance
- (void)prepareWidgetForUpdateWithReply:(void (^)(NSString * _Nullable))reply;
- (void)registerInstalledWidgetWithReply:(void (^)(NSString * _Nullable))reply;
@end

static NSString * const AppIdentifier = @"com.openai.MyAppLauncher";
static NSString * const WidgetIdentifier = @"com.openai.MyAppLauncher.widget";
static NSString * const TeamIdentifier = @"96H6RP27K3";

static NSURL *ApplicationURL(void) {
    NSURL *service = NSBundle.mainBundle.bundleURL.URLByResolvingSymlinksInPath;
    NSURL *app = service.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSString *expected = [app.path stringByAppendingPathComponent:@"Contents/XPCServices/WidgetMaintenance.xpc"];
    return ([service.path isEqualToString:expected] && [app.pathExtension isEqualToString:@"app"]) ? app : nil;
}

static BOOL ValidateBundle(NSURL *url, NSString *identifier) {
    NSBundle *bundle = [NSBundle bundleWithURL:url];
    if (![bundle.bundleIdentifier isEqualToString:identifier]) return NO;
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    NSString *text = [NSString stringWithFormat:@"anchor apple generic and identifier \"%@\" and certificate leaf[subject.OU] = \"%@\"", identifier, TeamIdentifier];
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess) status = SecRequirementCreateWithString((__bridge CFStringRef)text, kSecCSDefaultFlags, &requirement);
    if (status == errSecSuccess) status = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode, requirement);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    return status == errSecSuccess;
}

static NSString *ValidateInstallation(NSURL **appResult, NSURL **widgetResult) {
    NSURL *app = ApplicationURL();
    if (!app || !ValidateBundle(app, AppIdentifier)) return @"Signature de l’application invalide.";
    NSURL *widget = [app URLByAppendingPathComponent:@"Contents/PlugIns/MyAppLauncherWidget.appex"];
    if (!ValidateBundle(widget, WidgetIdentifier)) return @"Signature du widget invalide.";
    id appVersion = [[NSBundle bundleWithURL:app] objectForInfoDictionaryKey:@"CFBundleVersion"];
    id widgetVersion = [[NSBundle bundleWithURL:widget] objectForInfoDictionaryKey:@"CFBundleVersion"];
    if (![appVersion isKindOfClass:NSString.class] || ![appVersion isEqual:widgetVersion]) return @"Versions de l’application et du widget différentes.";
    *appResult = app;
    *widgetResult = widget;
    return nil;
}

// Widget extensions need not be NSRunningApplication instances. Enumerate
// native process metadata and signal only this user's exact installed binary.
static BOOL ReadWidgetProcess(pid_t pid, NSString *expected, struct proc_bsdinfo *info) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof(*info)) != sizeof(*info) || info->pbi_uid != geteuid()) return NO;
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    return [[[NSURL fileURLWithPath:@(path)] URLByResolvingSymlinksInPath].path isEqualToString:expected];
}
static NSString *StopWidget(NSURL *widget) {
    NSString *expected = [[widget URLByAppendingPathComponent:@"Contents/MacOS/MyAppLauncherWidget"] URLByResolvingSymlinksInPath].path;
    int capacity = proc_listallpids(NULL, 0) + 128;
    if (capacity <= 128 || capacity > 100000) return @"Liste des processus indisponible.";
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (!pids) return @"Mémoire de maintenance indisponible.";
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    NSMutableArray<NSDictionary *> *stopped = [NSMutableArray array];
    NSString *error = nil;
    for (int i = 0; i < MIN(count, capacity); i++) {
        struct proc_bsdinfo original, current;
        if (!ReadWidgetProcess(pids[i], expected, &original)) continue;
        // Recheck UID, path and start time immediately before TERM.
        if (!ReadWidgetProcess(pids[i], expected, &current) || current.pbi_start_tvsec != original.pbi_start_tvsec || current.pbi_start_tvusec != original.pbi_start_tvusec) continue;
        if (kill(pids[i], SIGTERM) != 0 && errno != ESRCH) { error = @"Fermeture du widget refusée."; break; }
        [stopped addObject:@{@"pid": @(pids[i]), @"sec": @(original.pbi_start_tvsec), @"usec": @(original.pbi_start_tvusec)}];
    }
    free(pids);
    if (count <= 0) return @"Liste des processus indisponible.";
    if (error) return error;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while ([deadline timeIntervalSinceNow] > 0) {
        BOOL stillRunning = NO;
        for (NSDictionary *entry in stopped) {
            struct proc_bsdinfo info;
            if (ReadWidgetProcess([entry[@"pid"] intValue], expected, &info) && info.pbi_start_tvsec == [entry[@"sec"] unsignedLongLongValue] && info.pbi_start_tvusec == [entry[@"usec"] unsignedLongLongValue]) stillRunning = YES;
        }
        if (!stillRunning) return nil;
        [NSThread sleepForTimeInterval:0.1];
    }
    return @"Le widget ne s’est pas fermé dans le délai prévu.";
}

static BOOL RunRegistration(NSString *executable, NSArray<NSString *> *arguments) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
    while (task.running && [deadline timeIntervalSinceNow] > 0) [NSThread sleepForTimeInterval:0.05];
    if (task.running) { [task terminate]; return NO; }
    return task.terminationReason == NSTaskTerminationReasonExit && task.terminationStatus == 0;
}

@interface WidgetMaintenance : NSObject <LauncherWidgetMaintenance, NSXPCListenerDelegate>
@property(nonatomic, strong) dispatch_queue_t workQueue;
@end
@implementation WidgetMaintenance
- (instancetype)init {
    self = [super init];
    if (self) _workQueue = dispatch_queue_create("com.openai.MyAppLauncher.widget-maintenance", DISPATCH_QUEUE_SERIAL);
    return self;
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    if (connection.effectiveUserIdentifier != geteuid()) return NO;
    [connection setCodeSigningRequirement:@"anchor apple generic and identifier \"com.openai.MyAppLauncher\" and certificate leaf[subject.OU] = \"96H6RP27K3\""];
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(LauncherWidgetMaintenance)];
    connection.exportedObject = self;
    [connection activate];
    return YES;
}
- (void)prepareWidgetForUpdateWithReply:(void (^)(NSString *))reply {
    dispatch_async(self.workQueue, ^{
        NSURL *app = nil, *widget = nil;
        NSString *error = ValidateInstallation(&app, &widget);
        if (!error) error = StopWidget(widget);
        reply(error);
    });
}
- (void)registerInstalledWidgetWithReply:(void (^)(NSString *))reply {
    dispatch_async(self.workQueue, ^{
        NSURL *app = nil, *widget = nil;
        NSString *error = ValidateInstallation(&app, &widget);
        if (!error && !RunRegistration(@"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", @[@"-f", app.path])) error = @"Réenregistrement de l’application refusé.";
        if (!error && !RunRegistration(@"/usr/bin/pluginkit", @[@"-a", widget.path])) error = @"Réenregistrement du widget refusé.";
        if (!error) error = StopWidget(widget);
        reply(error);
    });
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSXPCListener *listener = [NSXPCListener serviceListener];
        WidgetMaintenance *delegate = [[WidgetMaintenance alloc] init];
        listener.delegate = delegate;
        [listener resume];
    }
    return 0;
}
