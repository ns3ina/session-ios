//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "OWSMessageServiceParams.h"
#import "TSConstants.h"
#import <SignalCoreKit/NSData+OWS.h>

NS_ASSUME_NONNULL_BEGIN

@implementation OWSMessageServiceParams

+ (NSDictionary *)JSONKeyPathsByPropertyKey
{
    return [NSDictionary mtl_identityPropertyMapWithModel:[self class]];
}

- (instancetype)initWithType:(TSWhisperMessageType)type
                 recipientId:(NSString *)destination
                      device:(int)deviceId
                     content:(NSData *)content
                    isSilent:(BOOL)isSilent
                    isOnline:(BOOL)isOnline
              registrationId:(int)registrationId
                         ttl:(uint)ttl
                      isPing:(BOOL)isPing
             isFriendRequest:(BOOL)isFriendRequest
{
    self = [super init];

    if (!self) {
        return self;
    }

    _type = type;
    _destination = destination;
    _destinationDeviceId = deviceId;
    _destinationRegistrationId = registrationId;
    _content = [content base64EncodedString];
    _silent = isSilent;
    _online = isOnline;
    _ttl = ttl;
    _isPing = isPing;
    _isFriendRequest = isFriendRequest;

    return self;
}

@end

NS_ASSUME_NONNULL_END
