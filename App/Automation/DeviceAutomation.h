#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Accessibility snapshots and app launching through XCTest private API, for use after
/// `TouchSynthesizer` has loaded XCTest and the self-runner has enabled automation mode.
///
/// Every call is blocking; run it off the main thread.
@interface DeviceAutomation : NSObject

/// Snapshot of the foreground app as nested dictionaries:
/// `{ app: { pid, bundleID?, name? }, root: { type, label?, identifier?, value?, placeholder?,
///   frame: [x, y, w, h], enabled, selected, focused, children: [...] } }`.
/// Returns nil and sets `error` on failure.
+ (nullable NSDictionary *)snapshotForegroundAppWithMaxDepth:(NSInteger)maxDepth
                                                       error:(NSString *_Nullable *_Nullable)error;

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
