//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import "LSApplicationProxy.h"
#import "LSApplicationWorkspace.h"
#import "StripedTextTableViewController.h"

#import <UIKit/UIKit.h>

FOUNDATION_EXTERN NSString *TFGetDisplayVersion(void);
FOUNDATION_EXTERN void TFUtilKillAll(NSString *processPath, BOOL softly);
FOUNDATION_EXTERN NSData * _Nullable TFZStdDecompressData(NSData * _Nonnull data);

FOUNDATION_EXTERN BOOL TFExecuteSafely(void (^ _Nonnull block)(void),
                                       NSString * __autoreleasing _Nullable * _Nullable outError);

@interface UIImage (Private)
+ (instancetype)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier 
                                                  format:(int)format
                                                   scale:(CGFloat)scale;
@end
