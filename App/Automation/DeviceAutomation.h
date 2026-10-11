#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Accessibility snapshots and app launching through XCTest private API, for use after
/// `TouchSynthesizer` has loaded XCTest and the self-runner has enabled automation mode.
///
/// Every call is blocking; run it off the main thread.
@interface DeviceAutomation : NSObject

/// Snapshot of the foreground app as nested dictionaries:
/// `{ app: { pid, bundleID?, name? }, root: { type, label?, identifier?, value?, placeholder?,
///   frame: [x, y, w, h], enabled, selected, focused, children: [...] }, alert?: { same shape } }`.
/// `probePoint` (the screen centre, in points) picks the app in front when several are active. `alert` is an
/// alert SpringBoard shows over the app, which the app's own tree does not contain.
/// Returns nil and sets `error` on failure.
+ (nullable NSDictionary *)snapshotForegroundAppWithMaxDepth:(NSInteger)maxDepth
                                                  probePoint:(CGPoint)probePoint
                                                       error:(NSString *_Nullable *_Nullable)error;

/// Installed apps as `{ bundleID, name }` (localized name), or empty when the system will not list them.
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)installedApplications;

/// Launches (or brings forward) an app. Returns nil on success or an error description.
/// `path` records which mechanism worked, for diagnostics.
+ (nullable NSString *)launchAppWithBundleID:(NSString *)bundleID path:(NSString *_Nullable *_Nullable)path;

/// Opens a URL with its default app. Returns nil on success or an error description.
+ (nullable NSString *)openURL:(NSURL *)url path:(NSString *_Nullable *_Nullable)path;

/// dlopens XCTest and its automation frameworks from the mounted DDI, logging each dlerror.
/// Returns a multi-line report; loading here first means TouchSynthesizer's own dlopen reuses the handle.
+ (NSString *)preloadXCTest;

/// Which of the classes and selectors this file depends on resolved at runtime.
+ (NSString *)diagnostics;

@end

NS_ASSUME_NONNULL_END
