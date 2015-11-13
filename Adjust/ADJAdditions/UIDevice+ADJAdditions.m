//
//  UIDevice+ADJAdditions.m
//  Adjust
//
//  Created by Christian Wellenbrock on 23.07.12.
//  Copyright (c) 2012-2014 adjust GmbH. All rights reserved.
//

#import "UIDevice+ADJAdditions.h"
#import "NSString+ADJAdditions.h"

#import <sys/sysctl.h>

#if !ADJUST_NO_IDFA
#import <AdSupport/ASIdentifierManager.h>
#endif

#if !ADJUST_NO_IAD && !TARGET_OS_TV
#import <iAd/iAd.h>
#endif

#import "ADJAdjustFactory.h"

@implementation UIDevice(ADJAdditions)

- (BOOL)adjTrackingEnabled {
#if ADJUST_NO_IDFA
    return NO;
#else
    return [[ASIdentifierManager sharedManager] isAdvertisingTrackingEnabled];
#endif
}

- (NSString *)adjIdForAdvertisers {
#if ADJUST_NO_IDFA
    return @"";
#else
    NSUUID *advertisingIdentifier = [[ASIdentifierManager sharedManager]  advertisingIdentifier];
    return [advertisingIdentifier UUIDString];
#endif
}

- (NSString *)adjFbAttributionId {
#if ADJUST_NO_UIPASTEBOARD || defined (TARGET_OS_TV)
    return @"";
#else
    NSString *result = [UIPasteboard pasteboardWithName:@"fb_app_attribution" create:NO].string;
    if (result == nil) return @"";
    return result;
#endif
}

- (NSString *)adjDeviceType {
    NSString *type = [self.model stringByReplacingOccurrencesOfString:@" " withString:@""];
    return type;
}

- (NSString *)adjDeviceName {
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *name = malloc(size);
    sysctlbyname("hw.machine", name, &size, NULL, 0);
    NSString *machine = [NSString stringWithUTF8String:name];
    free(name);
    return machine;
}

- (NSString *)adjCreateUuid {
    CFUUIDRef newUniqueId = CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef stringRef = CFUUIDCreateString(kCFAllocatorDefault, newUniqueId);
    NSString *uuidString = (__bridge_transfer NSString*)stringRef;
    NSString *lowerUuid = [uuidString lowercaseString];
    CFRelease(newUniqueId);
    return lowerUuid;
}

- (NSString *)adjVendorId {
    if ([UIDevice.currentDevice respondsToSelector:@selector(identifierForVendor)]) {
        return [UIDevice.currentDevice.identifierForVendor UUIDString];
    }
    return @"";
}

- (void) adjSetIad:(ADJActivityHandler *) activityHandler
{
    id<ADJLogger> logger = [ADJAdjustFactory logger];

#if ADJUST_NO_IAD || TARGET_OS_TV
    [logger debug:@"ADJUST_NO_IAD or TARGET_OS_TV set"];
    return;
#else
    [logger debug:@"ADJUST_NO_IAD or TARGET_OS_TV not set"];

    // [[ADClient sharedClient] lookupAdConversionDetails:...]
    Class ADClientClass = NSClassFromString(@"ADClient");
    if (ADClientClass == nil) {
        return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

    SEL sharedClientSelector = NSSelectorFromString(@"sharedClient");
    if (![ADClientClass respondsToSelector:sharedClientSelector]) {
        return;
    }
    id ADClientSharedClientInstance = [ADClientClass performSelector:sharedClientSelector];

    SEL iadDateSelector = NSSelectorFromString(@"lookupAdConversionDetails:");
    if (![ADClientSharedClientInstance respondsToSelector:iadDateSelector]) {
        return;
    }

    [ADClientSharedClientInstance performSelector:iadDateSelector
                                       withObject:^(NSDate *appPurchaseDate, NSDate *iAdImpressionDate) {
                                           [activityHandler setIadDate:iAdImpressionDate withPurchaseDate:appPurchaseDate];
                                       }];

#pragma clang diagnostic pop
#endif
}
@end
