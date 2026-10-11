#import "DeviceAutomation.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Selectors verified against Xcode 26.6 (XCUIAutomation / XCTAutomationSupport, iOS device platform):
//   -[XCUIDevice accessibilityInterface]                         → XCAXClient_iOS
//   -[XCAXClient_iOS activeApplications] / systemApplication     → XCAccessibilityElement
//   -[XCAXClient_iOS defaultParameters]
//   -[XCAXClient_iOS requestSnapshotForElement:attributes:parameters:error:]   @48@0:8@16@24@32^@40
//   +[XCElementSnapshot axAttributesForElementSnapshotKeyPaths:isMacOS:]
//   -[XCAXClient_iOS applicationProcessTracker] -applicationProcessWithPID: -bundleID
//   -[XCAXClient_iOS accessibilityElementForElementAtPoint:error:]   (used as in iphone-use's runner, MIT)
//   -[LSApplicationWorkspace allInstalledApplications] → LSApplicationProxy -applicationIdentifier -localizedName
//   -[XCTRunnerDaemonSession launchApplicationWithPath:bundleID:arguments:environment:completion:]
//       completion is ^(id|BOOL, NSError *) depending on version — only the NSError is read.
//   -[XCTRunnerDaemonSession openDefaultApplicationForURL:completion:]  ^(BOOL, NSError *)

typedef id (*MsgSend_id)(id, SEL);
typedef id (*MsgSend_id_id)(id, SEL, id);
typedef id (*MsgSend_id_int)(id, SEL, int);
typedef id (*MsgSend_snapshot)(id, SEL, id, id, id, NSError **);
typedef id (*MsgSend_attrs)(id, SEL, id, BOOL);
typedef BOOL (*MsgSend_bool_id)(id, SEL, id);
typedef void (*MsgSend_launch)(id, SEL, id, id, id, id, id);
typedef void (*MsgSend_open)(id, SEL, id, id);
typedef id (*MsgSend_point)(id, SEL, CGPoint, NSError **);

static NSString *const SpringBoardBundleID = @"com.apple.springboard";
/// Presents the in-app Safari sheet over its host app; reads and taps belong to it while it shows.
static NSString *const SafariViewServiceBundleID = @"com.apple.SafariViewService";
/// XCUIElementTypeAlert.
static const NSInteger AlertElementType = 7;

static id Call(id target, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!target || ![target respondsToSelector:sel]) return nil;
    return ((MsgSend_id)objc_msgSend)(target, sel);
}

static id AXClient(void) {
    Class deviceClass = NSClassFromString(@"XCUIDevice");
    id device = Call(deviceClass, @"sharedDevice");
    id client = Call(device, @"accessibilityInterface");
    if (!client) client = Call(NSClassFromString(@"XCAXClient_iOS"), @"sharedClient");
    return client;
}

static id DaemonSession(void) {
    return Call(NSClassFromString(@"XCTRunnerDaemonSession"), @"sharedSession");
}

static NSString *StringOrNil(id value) {
    if (!value || value == [NSNull null]) return nil;
    NSString *string = [value isKindOfClass:[NSString class]] ? value : [value description];
    return string.length ? string : nil;
}

static id KV(id object, NSString *key) {
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

@implementation DeviceAutomation

#pragma mark - Snapshot

+ (int)pidOf:(id)element {
    return [KV(element, @"processIdentifier") intValue];
}

/// The app the user sees. Several apps can report active at once (the in-app Safari sheet's view service over its
/// host, picture in picture, an app extension); then the one owning the screen centre is in front.
+ (nullable id)foregroundElement:(id)client probe:(CGPoint)probe {
    NSArray *apps = Call(client, @"activeApplications");
    id springboard = nil;
    NSMutableArray *candidates = [NSMutableArray new];
    for (id element in apps) {
        NSString *bundle = [self bundleIDForPID:[self pidOf:element] client:client];
        if ([bundle isEqualToString:SpringBoardBundleID]) {
            springboard = element;
        } else {
            [candidates addObject:element];
        }
    }
    if (candidates.count == 1) return candidates.firstObject;
    if (candidates.count > 1) {
        SEL hitSel = NSSelectorFromString(@"accessibilityElementForElementAtPoint:error:");
        if ([client respondsToSelector:hitSel]) {
            id hit = nil;
            @try {
                NSError *error = nil;
                hit = ((MsgSend_point)objc_msgSend)(client, hitSel, probe, &error);
            } @catch (__unused NSException *e) {
            }
            int hitPID = [self pidOf:hit];
            for (id element in candidates) {
                if (hitPID > 0 && [self pidOf:element] == hitPID) return element;
            }
        }
        for (id element in candidates) {
            if ([[self bundleIDForPID:[self pidOf:element] client:client] isEqualToString:SafariViewServiceBundleID]) {
                return element;
            }
        }
        return candidates.firstObject;
    }
    return springboard ?: Call(client, @"systemApplication");
}

+ (nullable NSString *)bundleIDForPID:(int)pid client:(id)client {
    if (pid <= 0) return nil;
    @try {
        id tracker = Call(client, @"applicationProcessTracker");
        SEL sel = NSSelectorFromString(@"applicationProcessWithPID:");
        if (!tracker || ![tracker respondsToSelector:sel]) return nil;
        id process = ((MsgSend_id_int)objc_msgSend)(tracker, sel, pid);
        return StringOrNil(Call(process, @"bundleID"));
    } @catch (__unused NSException *e) {
        return nil;
    }
}

/// The snapshot attributes for our key paths, mapped once.
+ (id)snapshotAttributes {
    static id attributes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *keyPaths = @[ @"identifier", @"value", @"label", @"frame", @"enabled", @"elementType",
                               @"placeholderValue", @"selected", @"hasFocus" ];
        attributes = keyPaths;
        Class snapshotClass = NSClassFromString(@"XCElementSnapshot");
        SEL attrSel = NSSelectorFromString(@"axAttributesForElementSnapshotKeyPaths:isMacOS:");
        if ([snapshotClass respondsToSelector:attrSel]) {
            id converted = ((MsgSend_attrs)objc_msgSend)(snapshotClass, attrSel, keyPaths, NO);
            if ([converted isKindOfClass:[NSSet class]]) converted = [converted allObjects];
            if (converted) attributes = converted;
        }
    });
    return attributes;
}

/// One accessibility snapshot of `element`, or nil with `error` set.
+ (nullable id)snapshotOf:(id)element client:(id)client maxDepth:(NSInteger)maxDepth error:(NSString **)outError {
    NSMutableDictionary *parameters = [Call(client, @"defaultParameters") mutableCopy] ?: [NSMutableDictionary new];
    parameters[@"maxDepth"] = @(maxDepth);
    SEL snapSel = NSSelectorFromString(@"requestSnapshotForElement:attributes:parameters:error:");
    if (![client respondsToSelector:snapSel]) {
        if (outError) *outError = @"requestSnapshotForElement:attributes:parameters:error: not found";
        return nil;
    }
    NSError *error = nil;
    id result = ((MsgSend_snapshot)objc_msgSend)(client, snapSel, element, [self snapshotAttributes], parameters, &error);
    if (!result) {
        if (outError) *outError = error.localizedDescription ?: @"Snapshot returned nil";
        return nil;
    }
    return Call(result, @"rootElementSnapshot") ?: result;
}

+ (nullable id)firstAlertIn:(id)snapshot depth:(NSInteger)depth {
    if (!snapshot || depth > 80) return nil;
    if ([KV(snapshot, @"elementType") integerValue] == AlertElementType) return snapshot;
    for (id child in KV(snapshot, @"children")) {
        id found = [self firstAlertIn:child depth:depth + 1];
        if (found) return found;
    }
    return nil;
}

/// An alert SpringBoard shows over the foreground app (permission prompts, tel: confirmations). The app's own
/// tree does not contain it, so without this the agent cannot see the alert that blocks every tap.
+ (nullable id)springBoardAlert:(id)client foregroundPID:(int)foregroundPID {
    @try {
        id springboard = Call(client, @"systemApplication");
        if (!springboard || [self pidOf:springboard] == foregroundPID) return nil;
        id root = [self snapshotOf:springboard client:client maxDepth:30 error:NULL];
        return [self firstAlertIn:root depth:0];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

+ (nullable NSDictionary *)snapshotForegroundAppWithMaxDepth:(NSInteger)maxDepth
                                                  probePoint:(CGPoint)probe
                                                       error:(NSString **)outError {
    @try {
        id client = AXClient();
        if (!client) {
            if (outError) *outError = @"XCUIDevice.accessibilityInterface unavailable — is UI automation started?";
            return nil;
        }
        id element = [self foregroundElement:client probe:probe];
        if (!element) {
            if (outError) *outError = @"No active application found";
            return nil;
        }
        id root = [self snapshotOf:element client:client maxDepth:maxDepth error:outError];
        if (!root) return nil;

        int pid = [self pidOf:element];
        NSMutableDictionary *app = [NSMutableDictionary new];
        if (pid > 0) app[@"pid"] = @(pid);
        NSString *bundle = [self bundleIDForPID:pid client:client];
        if (bundle) app[@"bundleID"] = bundle;
        NSString *name = StringOrNil(KV(root, @"label"));
        if (name) app[@"name"] = name;

        NSMutableDictionary *result = [@{ @"app": app, @"root": [self dictionaryForSnapshot:root depth:0] } mutableCopy];
        if (![self firstAlertIn:root depth:0]) {
            id alert = [self springBoardAlert:client foregroundPID:pid];
            if (alert) result[@"alert"] = [self dictionaryForSnapshot:alert depth:0];
        }
        return result;
    } @catch (NSException *e) {
        if (outError) *outError = [NSString stringWithFormat:@"Snapshot threw %@: %@", e.name, e.reason];
        return nil;
    }
}

+ (NSDictionary *)dictionaryForSnapshot:(id)snapshot depth:(NSInteger)depth {
    NSMutableDictionary *node = [NSMutableDictionary new];
    node[@"type"] = KV(snapshot, @"elementType") ?: @0;
    NSString *label = StringOrNil(KV(snapshot, @"label"));
    if (label) node[@"label"] = label;
    NSString *identifier = StringOrNil(KV(snapshot, @"identifier"));
    if (identifier) node[@"identifier"] = identifier;
    NSString *value = StringOrNil(KV(snapshot, @"value"));
    if (value) node[@"value"] = value;
    NSString *placeholder = StringOrNil(KV(snapshot, @"placeholderValue"));
    if (placeholder) node[@"placeholder"] = placeholder;

    NSValue *frameValue = KV(snapshot, @"frame");
    CGRect frame = frameValue ? frameValue.CGRectValue : CGRectZero;
    if (CGRectIsNull(frame) || CGRectIsInfinite(frame)) frame = CGRectZero;
    node[@"frame"] = @[ @(frame.origin.x), @(frame.origin.y), @(frame.size.width), @(frame.size.height) ];

    node[@"enabled"] = KV(snapshot, @"enabled") ?: @YES;
    node[@"selected"] = KV(snapshot, @"selected") ?: @NO;
    node[@"focused"] = KV(snapshot, @"hasFocus") ?: @NO;

    NSArray *children = KV(snapshot, @"children");
    if (children.count && depth < 80) {
        NSMutableArray *converted = [NSMutableArray arrayWithCapacity:children.count];
        for (id child in children) [converted addObject:[self dictionaryForSnapshot:child depth:depth + 1]];
        node[@"children"] = converted;
    }
    return node;
}

#pragma mark - Launching

/// Waits for an async XCTest completion; returns its error description or nil.
+ (nullable NSString *)waitFor:(void (^)(void (^done)(NSString *_Nullable)))start timeout:(NSTimeInterval)timeout {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSString *result = nil;
    start(^(NSString *error) {
        result = error;
        dispatch_semaphore_signal(semaphore);
    });
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        return @"timed out";
    }
    return result;
}

+ (nullable NSString *)launchAppWithBundleID:(NSString *)bundleID path:(NSString **)outPath {
    NSMutableArray<NSString *> *failures = [NSMutableArray new];

    // 1. testmanagerd: privileged, works while this app is in the background.
    id session = DaemonSession();
    SEL launchSel = NSSelectorFromString(@"launchApplicationWithPath:bundleID:arguments:environment:completion:");
    if ([session respondsToSelector:launchSel]) {
        NSString *error = [self waitFor:^(void (^done)(NSString *)) {
            @try {
                // First argument is an id or a BOOL depending on the OS; declared void * so ARC never touches it.
                void (^completion)(void *, NSError *) = ^(__unused void *first, NSError *err) {
                    done(err ? err.localizedDescription : nil);
                };
                ((MsgSend_launch)objc_msgSend)(session, launchSel, nil, bundleID, @[], @{}, completion);
            } @catch (NSException *e) {
                done([NSString stringWithFormat:@"threw %@", e.reason]);
            }
        } timeout:20];
        if (!error) {
            if (outPath) *outPath = @"XCTRunnerDaemonSession.launchApplication";
            return nil;
        }
        [failures addObject:[@"daemon: " stringByAppendingString:error]];
    }

    // 2. LSApplicationWorkspace: no XCTest involvement, but FrontBoard may refuse from the background.
    id workspace = Call(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if ([workspace respondsToSelector:openSel]) {
        BOOL ok = NO;
        @try {
            ok = ((MsgSend_bool_id)objc_msgSend)(workspace, openSel, bundleID);
        } @catch (__unused NSException *e) {
        }
        if (ok) {
            if (outPath) *outPath = @"LSApplicationWorkspace";
            return nil;
        }
        [failures addObject:@"workspace: refused"];
    }

    // 3. XCUIApplication.activate: public XCTest API, heavier (waits for the app to settle).
    Class appClass = NSClassFromString(@"XCUIApplication");
    if (appClass) {
        @try {
            id app = ((MsgSend_id_id)objc_msgSend)([appClass alloc], NSSelectorFromString(@"initWithBundleIdentifier:"), bundleID);
            Call(app, @"activate");
            if (outPath) *outPath = @"XCUIApplication.activate";
            return nil;
        } @catch (NSException *e) {
            [failures addObject:[NSString stringWithFormat:@"activate: %@", e.reason]];
        }
    }
    return [NSString stringWithFormat:@"Could not launch %@ (%@)", bundleID, [failures componentsJoinedByString:@"; "]];
}

+ (nullable NSString *)openURL:(NSURL *)url path:(NSString **)outPath {
    NSMutableArray<NSString *> *failures = [NSMutableArray new];

    id session = DaemonSession();
    SEL openSel = NSSelectorFromString(@"openDefaultApplicationForURL:completion:");
    if ([session respondsToSelector:openSel]) {
        NSString *error = [self waitFor:^(void (^done)(NSString *)) {
            @try {
                void (^completion)(void *, NSError *) = ^(__unused void *ok, NSError *err) {
                    done(err ? err.localizedDescription : nil);
                };
                ((MsgSend_open)objc_msgSend)(session, openSel, url, completion);
            } @catch (NSException *e) {
                done([NSString stringWithFormat:@"threw %@", e.reason]);
            }
        } timeout:20];
        if (!error) {
            if (outPath) *outPath = @"XCTRunnerDaemonSession.openDefaultApplicationForURL";
            return nil;
        }
        [failures addObject:[@"daemon: " stringByAppendingString:error]];
    }

    id workspace = Call(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    SEL wsSel = NSSelectorFromString(@"openURL:");
    if ([workspace respondsToSelector:wsSel]) {
        BOOL ok = NO;
        @try {
            ok = ((MsgSend_bool_id)objc_msgSend)(workspace, wsSel, url);
        } @catch (__unused NSException *e) {
        }
        if (ok) {
            if (outPath) *outPath = @"LSApplicationWorkspace.openURL";
            return nil;
        }
        [failures addObject:@"workspace: refused"];
    }
    return [NSString stringWithFormat:@"Could not open %@ (%@)", url, [failures componentsJoinedByString:@"; "]];
}

#pragma mark - Loading

+ (NSString *)preloadXCTest {
    NSMutableString *report = [NSMutableString new];
    NSArray *paths = @[
        @"/System/Developer/Library/Frameworks/Testing.framework/Testing",
        @"/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
        @"/System/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport",
        @"/System/Developer/Library/Frameworks/XCUIAutomation.framework/XCUIAutomation",
        @"/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
    ];
    for (NSString *path in paths) {
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW);
        const char *error = handle ? NULL : dlerror();
        [report appendFormat:@"%@ %@ (exists: %@)%@\n", handle ? @"OK " : @"ERR", path.lastPathComponent,
                             exists ? @"yes" : @"no", error ? [NSString stringWithFormat:@": %s", error] : @""];
    }
    return report;
}

#pragma mark - Installed apps

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)installedApplications {
    NSMutableArray *apps = [NSMutableArray new];
    @try {
        id workspace = Call(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
        NSArray *proxies = Call(workspace, @"allInstalledApplications") ?: Call(workspace, @"allApplications");
        for (id proxy in proxies) {
            NSString *bundle = StringOrNil(Call(proxy, @"applicationIdentifier")) ?: StringOrNil(Call(proxy, @"bundleIdentifier"));
            NSString *name = StringOrNil(Call(proxy, @"localizedName"));
            NSArray *tags = Call(proxy, @"appTags");
            if (!bundle || !name || ([tags isKindOfClass:[NSArray class]] && [tags containsObject:@"hidden"])) continue;
            [apps addObject:@{ @"bundleID": bundle, @"name": name }];
        }
    } @catch (__unused NSException *e) {
    }
    return apps;
}

#pragma mark - Diagnostics

+ (NSString *)diagnostics {
    NSMutableString *out = [NSMutableString new];
    id client = AXClient();
    [out appendFormat:@"AX client: %@\n", client ? NSStringFromClass([client class]) : @"nil"];
    NSArray *selectors = @[ @"activeApplications", @"systemApplication", @"defaultParameters",
                            @"requestSnapshotForElement:attributes:parameters:error:", @"applicationProcessTracker",
                            @"accessibilityElementForElementAtPoint:error:" ];
    for (NSString *name in selectors) {
        [out appendFormat:@"  %@: %@\n", name, [client respondsToSelector:NSSelectorFromString(name)] ? @"yes" : @"NO"];
    }
    id session = DaemonSession();
    [out appendFormat:@"Daemon session: %@\n", session ? @"yes" : @"nil"];
    for (NSString *name in @[ @"launchApplicationWithPath:bundleID:arguments:environment:completion:",
                              @"openDefaultApplicationForURL:completion:" ]) {
        [out appendFormat:@"  %@: %@\n", name, [session respondsToSelector:NSSelectorFromString(name)] ? @"yes" : @"NO"];
    }
    [out appendFormat:@"LSApplicationWorkspace: %@ (%lu installed apps listed)\n",
                      NSClassFromString(@"LSApplicationWorkspace") ? @"yes" : @"NO",
                      (unsigned long)[self installedApplications].count];
    @try {
        NSArray *apps = Call(client, @"activeApplications");
        for (id element in apps) {
            NSNumber *pid = KV(element, @"processIdentifier");
            [out appendFormat:@"  active pid %@ → %@\n", pid, [self bundleIDForPID:pid.intValue client:client] ?: @"?"];
        }
    } @catch (NSException *e) {
        [out appendFormat:@"activeApplications threw: %@\n", e.reason];
    }
    return out;
}

@end
