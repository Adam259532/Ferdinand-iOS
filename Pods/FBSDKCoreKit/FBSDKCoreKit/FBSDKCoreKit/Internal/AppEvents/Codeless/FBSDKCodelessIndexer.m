// Copyright (c) 2014-present, Facebook, Inc. All rights reserved.
//
// You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
// copy, modify, and distribute this software in source code or binary form for use
// in connection with the web services and APIs provided by Facebook.
//
// As with any software that integrates with the Facebook platform, your use of
// this software is subject to the Facebook Developer Principles and Policies
// [http://developers.facebook.com/policy/]. This copyright notice shall be
// included in all copies or substantial portions of the software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "FBSDKCodelessIndexer.h"

#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

#import <UIKit/UIKit.h>

#import <FBSDKCoreKit/FBSDKGraphRequest.h>
#import <FBSDKCoreKit/FBSDKSettings.h>

#import "FBSDKCoreKit+Internal.h"

@implementation FBSDKCodelessIndexer

static BOOL _isCodelessIndexing;
static BOOL _isCheckingSession;
static BOOL _isCodelessIndexingEnabled;

static NSString *_deviceSessionID;
static NSTimer *_appIndexingTimer;
static NSString *_lastTreeHash;

+ (void)load
{
#if TARGET_OS_SIMULATOR
  [self setupGesture];
#else
  [FBSDKServerConfigurationManager loadServerConfigurationWithCompletionBlock:^(FBSDKServerConfiguration *serverConfiguration, NSError *error) {
    if (serverConfiguration.codelessSetupEnabled) {
      [self setupGesture];
    }
  }];
#endif
}

+ (void)setupGesture
{
  [UIApplication sharedApplication].applicationSupportsShakeToEdit = YES;
  Class class = [UIApplication class];

  [FBSDKSwizzler swizzleSelector:@selector(motionBegan:withEvent:) onClass:class withBlock:^{
    if ([FBSDKServerConfigurationManager cachedServerConfiguration].isCodelessEventsEnabled) {
      [self checkCodelessIndexingSession];
    }
  } named:@"motionBegan"];
}



+ (void)checkCodelessIndexingSession
{
  if (_isCheckingSession) return;

  _isCheckingSession = YES;
  NSDictionary *parameters = @{
                               CODELESS_INDEXING_SESSION_ID_KEY: [self currentSessionDeviceID],
                               CODELESS_INDEXING_EXT_INFO_KEY: [self extInfo]
                               };
  FBSDKGraphRequest *request = [[FBSDKGraphRequest alloc]
                                initWithGraphPath:[NSString stringWithFormat:@"%@/%@",
                                                   [FBSDKSettings appID], CODELESS_INDEXING_SESSION_ENDPOINT]
                                parameters: parameters
                                HTTPMethod:@"POST"];
  [request startWithCompletionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
    _isCheckingSession = NO;
    if ([result isKindOfClass:[NSDictionary class]]) {
      _isCodelessIndexingEnabled = [[(NSDictionary *)result objectForKey:CODELESS_INDEXING_STATUS_KEY] boolValue];
      if (_isCodelessIndexingEnabled) {
        _lastTreeHash = nil;
        if (!_appIndexingTimer) {
          _appIndexingTimer = [NSTimer timerWithTimeInterval:CODELESS_INDEXING_UPLOAD_INTERVAL_IN_SECONDS
                                                target:self
                                              selector:@selector(startIndexing)
                                              userInfo:nil
                                               repeats:YES];

          [[NSRunLoop mainRunLoop] addTimer:_appIndexingTimer forMode:NSDefaultRunLoopMode];
        }
      } else {
        _deviceSessionID = nil;
      }
    }
  }];
}

+ (NSString *)currentSessionDeviceID
{
  if (!_deviceSessionID) {
    _deviceSessionID = [[NSUUID UUID] UUIDString];
  }
  return _deviceSessionID;
}

+ (NSString *)extInfo
{
  struct utsname systemInfo;
  uname(&systemInfo);
  NSString *machine = @(systemInfo.machine);
  NSString *advertiserID = nil;
  if (FBSDKAdvertisingTrackingAllowed == [FBSDKAppEventsUtility advertisingTrackingStatus]) {
    advertiserID = [FBSDKAppEventsUtility advertiserID];
  }
  machine = machine ?: @"";
  advertiserID = advertiserID ?: @"";
  NSString *debugStatus = [FBSDKAppEventsUtility isDebugBuild] ? @"1" : @"0";
#if TARGET_IPHONE_SIMULATOR
  NSString *isSimulator = @"1";
#else
  NSString *isSimulator = @"0";
#endif
  NSLocale *locale = [NSLocale currentLocale];
  NSString *languageCode = [locale objectForKey:NSLocaleLanguageCode];
  NSString *countryCode = [locale objectForKey:NSLocaleCountryCode];
  NSString *localeString = [locale localeIdentifier];
  if (languageCode && countryCode) {
    localeString = [NSString stringWithFormat:@"%@_%@", languageCode, countryCode];
  }

  NSString *extinfo = [FBSDKInternalUtility JSONStringForObject:@[machine,
                                                                  advertiserID,
                                                                  debugStatus,
                                                                  isSimulator,
                                                                  localeString]
                                                          error:NULL
                                           invalidObjectHandler:NULL];

  return extinfo ?: @"";
}

+ (void)startIndexing {
  if (!_isCodelessIndexingEnabled) {
    return;
  }

  if (UIApplicationStateActive != [UIApplication sharedApplication].applicationState) {
    return;
  }

  // If userAgentSuffix begins with Unity, trigger unity code to upload view hierarchy
  NSString *userAgentSuffix = [FBSDKSettings userAgentSuffix];
  if (userAgentSuffix != nil && [userAgentSuffix hasPrefix:@"Unity"]) {
    Class FBUnityUtility = objc_lookUpClass("FBUnityUtility");
    SEL selector = NSSelectorFromString(@"triggerUploadViewHierarchy");
    if (FBUnityUtility && selector && [FBUnityUtility respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [FBUnityUtility performSelector:selector];
#pragma clang diagnostic pop
    }
  } else {
    [self uploadIndexing];
  }
}

+ (void)uploadIndexing
{
  if (_isCodelessIndexing) {
        return;
  }

  NSString *tree = [FBSDKCodelessIndexer currentViewTree];

  [self uploadIndexing:tree];
}

+ (void)uploadIndexing:(NSString *)tree
{
    if (_isCodelessIndexing) {
        return;
    }

    if (!tree) {
        return;
    }

    NSString *currentTreeHash = [FBSDKUtility SHA256Hash:tree];
    if (_lastTreeHash && [_lastTreeHash isEqualToString:currentTreeHash]) {
        return;
    }

    _lastTreeHash = currentTreeHash;

    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *version = [mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];

    FBSDKGraphRequest *request = [[FBSDKGraphRequest alloc]
                                  initWithGraphPath:[NSString stringWithFormat:@"%@/%@",
                                                     [FBSDKSettings appID], CODELESS_INDEXING_ENDPOINT]
                                  parameters:@{
                                               CODELESS_INDEXING_TREE_KEY: tree,
                                               CODELESS_INDEXING_APP_VERSION_KEY: version ?: @"",
                                               CODELESS_INDEXING_PLATFORM_KEY: @"iOS",
                                               CODELESS_INDEXING_SESSION_ID_KEY: [self currentSessionDeviceID]
                                               }
                                  HTTPMethod:@"POST"];
    _isCodelessIndexing = YES;
    [request startWithCompletionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
        _isCodelessIndexing = NO;
        if ([result isKindOfClass:[NSDictionary class]]) {
            _isCodelessIndexingEnabled = [[result objectForKey:CODELESS_INDEXING_STATUS_KEY] boolValue];
            if (!_isCodelessIndexingEnabled) {
                _deviceSessionID = nil;
            }
        }
    }];
}

+ (NSString *)currentViewTree
{
  NSMutableArray *trees = [NSMutableArray array];

  NSArray *windows = [UIApplication sharedApplication].windows;
  for (UIWindow *window in windows) {
    NSDictionary *tree = [FBSDKCodelessIndexer recursiveCaptureTree:window];
    if (tree) {
      if (window.isKeyWindow) {
        [trees insertObject:tree atIndex:0];
      } else {
        [trees addObject:tree];
      }
    }
  }

  if (0 == trees.count) {
    return nil;
  }

  NSArray *viewTrees = [[trees reverseObjectEnumerator] allObjects];

  NSData *data = UIImageJPEGRepresentation([FBSDKCodelessIndexer screenshot], 0.5);
  NSString *screenshot = [data base64EncodedStringWithOptions:0];

  NSMutableDictionary *treeInfo = [NSMutableDictionary dictionary];

  [treeInfo setObject:viewTrees forKey:@"view"];
  [treeInfo setObject:screenshot ?: @"" forKey:@"screenshot"];

  NSString *tree = nil;
  data = [NSJSONSerialization dataWithJSONObject:treeInfo options:0 error:nil];
  if (data) {
    tree = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  }

  return tree;
}

+ (NSDictionary<NSString *, id> *)recursiveCaptureTree:(NSObject *)obj
{
  if (!obj) {
    return nil;
  }

  NSMutableDictionary *result = [FBSDKViewHierarchy getDetailAttributesOf:obj];

  NSArray *children = [FBSDKViewHierarchy getChildren:obj];
  NSMutableArray *childrenTrees = [NSMutableArray array];
  for (NSObject *child in children) {
    NSDictionary *objTree = [self recursiveCaptureTree:child];
    [childrenTrees addObject:objTree];
  }

  if (childrenTrees.count > 0) {
    [result setValue:[childrenTrees copy] forKey:CODELESS_VIEW_TREE_CHILDREN_KEY];
  }

  return [result copy];
}

+ (UIImage *)screenshot {
  UIWindow *window = [[UIApplication sharedApplication].delegate window];

  UIGraphicsBeginImageContext(window.bounds.size);
  [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
  UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();

  return image;
}

+ (NSDictionary<NSString *, NSNumber *> *)dimensionOf:(NSObject *)obj
{
  UIView *view = nil;

  if ([obj isKindOfClass:[UIView class]]) {
    view = (UIView *)obj;
  } else if ([obj isKindOfClass:[UIViewController class]]) {
    view = ((UIViewController *)obj).view;
  }

  CGRect frame = view.frame;
  CGPoint offset = CGPointZero;

  if ([view isKindOfClass:[UIScrollView class]])
    offset = ((UIScrollView *)view).contentOffset;

  return @{
           CODELESS_VIEW_TREE_TOP_KEY: @((int)frame.origin.y),
           CODELESS_VIEW_TREE_LEFT_KEY: @((int)frame.origin.x),
           CODELESS_VIEW_TREE_WIDTH_KEY: @((int)frame.size.width),
           CODELESS_VIEW_TREE_HEIGHT_KEY: @((int)frame.size.height),
           CODELESS_VIEW_TREE_OFFSET_X_KEY: @((int)offset.x),
           CODELESS_VIEW_TREE_OFFSET_Y_KEY: @((int)offset.y),
           CODELESS_VIEW_TREE_VISIBILITY_KEY: view.isHidden ? @4 : @0
           };
}

@end
