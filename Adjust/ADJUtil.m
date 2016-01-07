//
//  ADJUtil.m
//  Adjust
//
//  Created by Christian Wellenbrock on 2013-07-05.
//  Copyright (c) 2013 adjust GmbH. All rights reserved.
//

#import "ADJUtil.h"
#import "ADJLogger.h"
#import "UIDevice+ADJAdditions.h"
#import "ADJAdjustFactory.h"
#import "NSString+ADJAdditions.h"
#import "ADJAdjustFactory.h"
#import "ADJResponseData.h"

#include <sys/xattr.h>

static NSDateFormatter *dateFormat;

static NSString * const kClientSdk      = @"ios4.5.4";
static NSString * const kDefaultScheme  = @"AdjustUniversalScheme";
static NSString * const kUniversalLinkPattern  = @"https://[^.]*\\.ulink\\.adjust\\.com/ulink/?(.*)";
static NSString * const kBaseUrl        = @"https://app.adjust.com";
static NSString * const kDateFormat     = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'Z";
static NSRegularExpression * universalLinkRegex = nil;

#pragma mark -
@implementation ADJUtil

+ (void) initialize {
    dateFormat = [[NSDateFormatter alloc] init];

    if ([NSCalendar instancesRespondToSelector:@selector(calendarWithIdentifier:)]) {
        // http://stackoverflow.com/a/3339787
        NSString * calendarIdentifier;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"
        if (&NSCalendarIdentifierGregorian != NULL) {
#pragma clang diagnostic pop
            calendarIdentifier = NSCalendarIdentifierGregorian;
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunreachable-code"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            calendarIdentifier = NSGregorianCalendar;
#pragma clang diagnostic pop
        }


        dateFormat.calendar = [NSCalendar calendarWithIdentifier:calendarIdentifier];
    }

    dateFormat.locale = [NSLocale systemLocale];
    [dateFormat setDateFormat:kDateFormat];
}

+ (NSString *)baseUrl {
    return kBaseUrl;
}

+ (NSString *)clientSdk {
    return kClientSdk;
}

// inspired by https://gist.github.com/kevinbarrett/2002382
+ (void)excludeFromBackup:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path];
    const char* filePath = [[url path] fileSystemRepresentation];
    const char* attrName = "com.apple.MobileBackup";
    id<ADJLogger> logger = ADJAdjustFactory.logger;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunreachable-code"
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"
    if (&NSURLIsExcludedFromBackupKey == nil) {
        u_int8_t attrValue = 1;
        int result = setxattr(filePath, attrName, &attrValue, sizeof(attrValue), 0, 0);
        if (result != 0) {
            [logger debug:@"Failed to exclude '%@' from backup", url.lastPathComponent];
        }
    } else { // iOS 5.0 and higher
        // First try and remove the extended attribute if it is present
        ssize_t result = getxattr(filePath, attrName, NULL, sizeof(u_int8_t), 0, 0);
        if (result != -1) {
            // The attribute exists, we need to remove it
            int removeResult = removexattr(filePath, attrName, 0);
            if (removeResult == 0) {
                [logger debug:@"Removed extended attribute on file '%@'", url];
            }
        }

        // Set the new key
        NSError *error = nil;
        BOOL success = [url setResourceValue:[NSNumber numberWithBool:YES]
                                      forKey:NSURLIsExcludedFromBackupKey
                                       error:&error];
        if (!success || error != nil) {
            [logger debug:@"Failed to exclude '%@' from backup (%@)", url.lastPathComponent, error.localizedDescription];
        }
    }
#pragma clang diagnostic pop

}

+ (NSString *)formatSeconds1970:(double) value {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:value];

    return [self formatDate:date];
}

+ (NSString *)formatDate:(NSDate *) value {
    return [dateFormat stringFromDate:value];
}

+ (void) saveJsonResponse:(NSData *)jsonData
             responseData:(ADJResponseData *)responseData
{
    NSError *error = nil;
    NSException *exception = nil;

    NSDictionary *jsonDict = [ADJUtil buildJsonDict:jsonData exceptionPtr:&exception errorPtr:&error];

    if (exception != nil) {
        NSString * message = [NSString stringWithFormat:@"Failed to parse json response. (%@)", exception.description];
        [ADJAdjustFactory.logger error:message];
        responseData.message = message;
        return;
    }

    if (error != nil) {
        NSString * message = [NSString stringWithFormat:@"Failed to parse json response. (%@)", error.localizedDescription];
        [ADJAdjustFactory.logger error:message];
        responseData.message = message;
        return;
    }

    responseData.jsonResponse = jsonDict;
}

+ (NSDictionary *) buildJsonDict:(NSData *)jsonData
                    exceptionPtr:(NSException **)exceptionPtr
                        errorPtr:(NSError **)error
{
    if (jsonData == nil) {
        return nil;
    }
    NSDictionary *jsonDict = nil;
    @try {
        jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:error];
    } @catch (NSException *ex) {
        *exceptionPtr = ex;
        return nil;
    }

    return jsonDict;
}

+ (NSString *)getFullFilename:(NSString *) baseFilename {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *path = [paths objectAtIndex:0];
    NSString *filename = [path stringByAppendingPathComponent:baseFilename];
    return filename;
}

+ (id)readObject:(NSString *)filename
      objectName:(NSString *)objectName
           class:(Class) classToRead
{
    id<ADJLogger> logger = [ADJAdjustFactory logger];
    @try {
        NSString *fullFilename = [ADJUtil getFullFilename:filename];
        id object = [NSKeyedUnarchiver unarchiveObjectWithFile:fullFilename];
        if ([object isKindOfClass:classToRead]) {
            [logger debug:@"Read %@: %@", objectName, object];
            return object;
        } else if (object == nil) {
            [logger verbose:@"%@ file not found", objectName];
        } else {
            [logger error:@"Failed to read %@ file", objectName];
        }
    } @catch (NSException *ex ) {
        [logger error:@"Failed to read %@ file (%@)", objectName, ex];
    }

    return nil;
}

+ (void)writeObject:(id)object
           filename:(NSString *)filename
         objectName:(NSString *)objectName {
    id<ADJLogger> logger = [ADJAdjustFactory logger];
    NSString *fullFilename = [ADJUtil getFullFilename:filename];
    BOOL result = [NSKeyedArchiver archiveRootObject:object toFile:fullFilename];
    if (result == YES) {
        [ADJUtil excludeFromBackup:fullFilename];
        [logger debug:@"Wrote %@: %@", objectName, object];
    } else {
        [logger error:@"Failed to write %@ file", objectName];
    }
}

+ (NSString *) queryString:(NSDictionary *)parameters {
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *key in parameters) {
        NSString *value = [parameters objectForKey:key];
        NSString *escapedValue = [value adjUrlEncode];
        NSString *escapedKey = [key adjUrlEncode];
        NSString *pair = [NSString stringWithFormat:@"%@=%@", escapedKey, escapedValue];
        [pairs addObject:pair];
    }

    double now = [NSDate.date timeIntervalSince1970];
    NSString *dateString = [ADJUtil formatSeconds1970:now];
    NSString *escapedDate = [dateString adjUrlEncode];
    NSString *sentAtPair = [NSString stringWithFormat:@"%@=%@", @"sent_at", escapedDate];

    [pairs addObject:sentAtPair];

    NSString *queryString = [pairs componentsJoinedByString:@"&"];
    
    return queryString;
}

+ (BOOL)isNull:(id)value {
    return value == nil || value == (id)[NSNull null];
}

+ (BOOL)isNotNull:(id)value {
    return value != nil && value != (id)[NSNull null];
}

+ (NSString *)formatErrorMessage:(NSString *)prefixErrorMessage
              systemErrorMessage:(NSString *)systemErrorMessage
              suffixErrorMessage:(NSString *)suffixErrorMessage
{
    NSString * errorMessage = [NSString stringWithFormat:@"%@ (%@)", prefixErrorMessage, systemErrorMessage];
    if (suffixErrorMessage == nil) {
        return errorMessage;
    } else {
        return [errorMessage stringByAppendingFormat:@" %@", suffixErrorMessage];
    }
}

+ (void)sendRequest:(NSMutableURLRequest *)request
 prefixErrorMessage:(NSString *)prefixErrorMessage
    activityPackage:(ADJActivityPackage *)activityPackage
responseDataHandler:(void (^) (ADJResponseData * responseData))responseDataHandler
{
    [ADJUtil sendRequest:request
      prefixErrorMessage:prefixErrorMessage
      suffixErrorMessage:nil
         activityPackage:activityPackage
     responseDataHandler:responseDataHandler];
}

+ (void)sendRequest:(NSMutableURLRequest *)request
 prefixErrorMessage:(NSString *)prefixErrorMessage
 suffixErrorMessage:(NSString *)suffixErrorMessage
    activityPackage:(ADJActivityPackage *)activityPackage
responseDataHandler:(void (^) (ADJResponseData * responseData))responseDataHandler
{
    Class NSURLSessionClass = NSClassFromString(@"NSURLSession");
    if (NSURLSessionClass != nil) {
        [ADJUtil sendNSURLSessionRequest:request
                      prefixErrorMessage:prefixErrorMessage
                      suffixErrorMessage:suffixErrorMessage
                         activityPackage:activityPackage
                     responseDataHandler:responseDataHandler];
    } else {
        [ADJUtil sendNSURLConnectionRequest:request
                         prefixErrorMessage:prefixErrorMessage
                         suffixErrorMessage:suffixErrorMessage
                            activityPackage:activityPackage
                        responseDataHandler:responseDataHandler];
    }
}

+ (void)sendNSURLSessionRequest:(NSMutableURLRequest *)request
             prefixErrorMessage:(NSString *)prefixErrorMessage
             suffixErrorMessage:(NSString *)suffixErrorMessage
                activityPackage:(ADJActivityPackage *)activityPackage
            responseDataHandler:(void (^) (ADJResponseData * responseData))responseDataHandler
{
    NSURLSession *session = [NSURLSession sharedSession];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:
                                  ^(NSData *data, NSURLResponse *response, NSError *error) {
                                      ADJResponseData * responseData = [ADJUtil completionHandler:data
                                                                                         response:(NSHTTPURLResponse *)response
                                                                                            error:error
                                                                               prefixErrorMessage:prefixErrorMessage
                                                                               suffixErrorMessage:suffixErrorMessage
                                                                                  activityPackage:activityPackage];
                                      responseDataHandler(responseData);
                                  }];
    [task resume];
}

+ (void)sendNSURLConnectionRequest:(NSMutableURLRequest *)request
                prefixErrorMessage:(NSString *)prefixErrorMessage
                suffixErrorMessage:(NSString *)suffixErrorMessage
                   activityPackage:(ADJActivityPackage *)activityPackage
               responseDataHandler:(void (^) (ADJResponseData * responseData))responseDataHandler
{
    NSError *responseError = nil;
    NSHTTPURLResponse *urlResponse = nil;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData * data = [NSURLConnection sendSynchronousRequest:request
                                                 returningResponse:&urlResponse
                                                             error:&responseError];
#pragma clang diagnostic pop

    ADJResponseData * responseData = [ADJUtil completionHandler:data
                                                       response:(NSHTTPURLResponse *)urlResponse
                                                          error:responseError
                                             prefixErrorMessage:prefixErrorMessage
                                             suffixErrorMessage:suffixErrorMessage
                                                activityPackage:activityPackage];

    responseDataHandler(responseData);
}

+ (ADJResponseData *)completionHandler:(NSData *)data
                              response:(NSHTTPURLResponse *)urlResponse
                                 error:(NSError *)responseError
                    prefixErrorMessage:(NSString *)prefixErrorMessage
                    suffixErrorMessage:(NSString *)suffixErrorMessage
                       activityPackage:(ADJActivityPackage *)activityPackage
{
    ADJResponseData * responseData = [ADJResponseData responseDataWithActivityPackage:activityPackage];

    // connection error
    if (responseError != nil) {
        NSString * errorMessage = [ADJUtil formatErrorMessage:prefixErrorMessage
                                           systemErrorMessage:responseError.localizedDescription
                                           suffixErrorMessage:suffixErrorMessage];
        [ADJAdjustFactory.logger error:errorMessage];
        responseData.message = errorMessage;
        return responseData;
    }
    if ([ADJUtil isNull:data]) {
        NSString * errorMessage = [ADJUtil formatErrorMessage:prefixErrorMessage
                                           systemErrorMessage:@"empty error"
                                           suffixErrorMessage:suffixErrorMessage];
        [ADJAdjustFactory.logger error:errorMessage];
        responseData.message = errorMessage;
        return responseData;
    }

    NSString *responseString = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] adjTrim];
    NSInteger statusCode = urlResponse.statusCode;

    [ADJAdjustFactory.logger verbose:@"Response: %@", responseString];

    [ADJUtil saveJsonResponse:data responseData:responseData];

    if ([ADJUtil isNull:responseData.jsonResponse]) {
        return responseData;
    }

    NSString* messageResponse = [responseData.jsonResponse objectForKey:@"message"];

    responseData.message = messageResponse;
    responseData.timeStamp = [responseData.jsonResponse objectForKey:@"timestamp"];
    responseData.adid = [responseData.jsonResponse objectForKey:@"adid"];

    if (messageResponse == nil) {
        messageResponse = @"No message found";
    }

    if (statusCode == 200) {
        [ADJAdjustFactory.logger info:@"%@", messageResponse];
        responseData.success = YES;
    } else {
        [ADJAdjustFactory.logger error:@"%@", messageResponse];
    }

    return responseData;
}

// convert all values to strings, if value is dictionary -> recursive call
+ (NSDictionary *)convertDictionaryValues:(NSDictionary *)dictionary
{
    NSMutableDictionary * convertedDictionary = [[NSMutableDictionary alloc] initWithCapacity:dictionary.count];

    for (NSString * key in dictionary) {
        id value = [dictionary objectForKey:key];
        if ([value isKindOfClass:[NSDictionary class]]) {
            // dictionary value, recursive call
            NSDictionary * dictionaryValue = [ADJUtil convertDictionaryValues:(NSDictionary *)value];
            [convertedDictionary setObject:dictionaryValue forKey:key];

        } else if ([value isKindOfClass:[NSDate class]]) {
            // format date to our custom format
            NSString * dateStingValue = [ADJUtil formatDate:value];
            [convertedDictionary setObject:dateStingValue forKey:key];

        } else {
            // convert all other objects directly to string
            NSString * stringValue = [NSString stringWithFormat:@"%@", value];
            [convertedDictionary setObject:stringValue forKey:key];
        }
    }

    return convertedDictionary;
}

+ (NSString *)idfa {
    return [[UIDevice currentDevice] adjIdForAdvertisers];
}

+ (NSURL *)convertUniversalLink:(NSURL *)url scheme:(NSString *)scheme {
    id<ADJLogger> logger = ADJAdjustFactory.logger;

    if ([ADJUtil isNull:scheme] || [scheme length] == 0) {
        [logger warn:@"Non-empty scheme required, using the scheme \"AdjustUniversalScheme\""];
        scheme = kDefaultScheme;
    }

    if ([ADJUtil isNull:url]) {
        [logger error:@"Received universal link is nil"];
        return nil;
    }

    NSString *urlString = [url absoluteString];

    if ([ADJUtil isNull:urlString]) {
        [logger error:@"Parsed universal link is nil"];
        return nil;
    }

    if (universalLinkRegex == nil) {
        NSError *error = NULL;

        NSRegularExpression *regex  = [NSRegularExpression
                                       regularExpressionWithPattern:kUniversalLinkPattern
                                       options:NSRegularExpressionCaseInsensitive
                                       error:&error];

        if ([ADJUtil isNotNull:error]) {
            [logger error:@"Universal link regex rule error (%@)", [error description]];
            return nil;
        }

        universalLinkRegex = regex;
    }

    NSArray<NSTextCheckingResult *> *matches = [universalLinkRegex matchesInString:urlString options:0 range:NSMakeRange(0, [urlString length])];

    if ([matches count] == 0) {
        [logger error:@"Url doesn't match as universal link with format https://[hash].ulink.adjust.com/ulink/..."];
        return nil;
    }

    if ([matches count] > 1) {
        [logger error:@"Url match as universal link multiple times"];
        return nil;
    }

    NSTextCheckingResult *match = matches[0];

    if ([match numberOfRanges] != 2) {
        [logger error:@"Wrong number of ranges matched"];
        return nil;
    }

    NSString *tailSubString = [urlString substringWithRange:[match rangeAtIndex:1]];

    NSString *extractedUrlString = [NSString stringWithFormat:@"%@://%@", scheme, tailSubString];

    [logger info:@"Converted deeplink from universal link %@", extractedUrlString];

    NSURL *extractedUrl = [NSURL URLWithString:extractedUrlString];

    if ([ADJUtil isNull:extractedUrl]) {
        [logger error:@"Unable to parse converted deeplink from universal link %@", extractedUrlString];
        return nil;
    }

    return extractedUrl;
}

@end
