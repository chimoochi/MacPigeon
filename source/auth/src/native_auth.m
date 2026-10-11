#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// Own-process authentication headers only. No account credentials or message access.
static long last_error;
long mp_auth_error(void) { return last_error; }
char *mp_auth_headers(void) {
    @autoreleasepool {
        static void *aos, *ak;
        aos = aos ?: dlopen("/System/Library/PrivateFrameworks/AOSKit.framework/AOSKit", RTLD_NOW);
        ak = ak ?: dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW);
        if (!aos || !ak) return NULL;
        @try {
            Class utilities = NSClassFromString(@"AOSUtilities"), deviceClass = NSClassFromString(@"AKDevice");
            SEL otpSel = NSSelectorFromString(@"retrieveOTPHeadersForDSID:");
            SEL currentSel = NSSelectorFromString(@"currentDevice");
            if (![utilities respondsToSelector:otpSel] || ![deviceClass respondsToSelector:currentSel]) return NULL;
            id otp = ((id (*)(id, SEL, id))objc_msgSend)(utilities, otpSel, @"-2");
            id device = ((id (*)(id, SEL))objc_msgSend)(deviceClass, currentSel);
            if (!device) return NULL;
            if (![otp isKindOfClass:NSDictionary.class] || ![otp[@"X-Apple-MD"] isKindOfClass:NSString.class] || ![otp[@"X-Apple-MD-M"] isKindOfClass:NSString.class]) {
                Class controllerClass = NSClassFromString(@"AKAnisetteProvisioningController");
                SEL fetch = NSSelectorFromString(@"fetchAnisetteDataAndProvisionIfNecessary:error:");
                Method method = class_getInstanceMethod(controllerClass, fetch);
                if (!method || strcmp(method_getTypeEncoding(method), "@28@0:8B16^@20") != 0) return NULL;
                id controller = [controllerClass new];
                NSError *error = nil;
                // Read native data only; explicitly forbid provisioning here.
                id data = ((id (*)(id, SEL, BOOL, NSError **))objc_msgSend)(controller, fetch, NO, &error);
                if (!data || error || ![data respondsToSelector:NSSelectorFromString(@"machineID")] || ![data respondsToSelector:NSSelectorFromString(@"oneTimePassword")]) { last_error = error ? error.code : -1; return NULL; }
                id mid = ((id (*)(id, SEL))objc_msgSend)(data, NSSelectorFromString(@"machineID"));
                id password = ((id (*)(id, SEL))objc_msgSend)(data, NSSelectorFromString(@"oneTimePassword"));
                if (![mid isKindOfClass:NSString.class] || ![password isKindOfClass:NSString.class]) return NULL;
                otp = @{@"X-Apple-MD-M":mid, @"X-Apple-MD":password};
            }
            NSMutableDictionary *headers = [NSMutableDictionary dictionary];
            NSDictionary *otpKeys = @{@"X-Apple-MD": @"X-Apple-I-MD", @"X-Apple-MD-M": @"X-Apple-I-MD-M"};
            for (NSString *key in otpKeys) {
                id value = otp[key];
                if (![value isKindOfClass:NSString.class] || ![value length]) return NULL;
                headers[otpKeys[key]] = value;
            }
            NSDictionary *deviceKeys = @{@"localUserUUID": @"X-Apple-I-MD-LU", @"uniqueDeviceIdentifier": @"X-Mme-Device-Id", @"serverFriendlyDescription": @"X-Mme-Client-Info"};
            for (NSString *name in deviceKeys) {
                SEL selector = NSSelectorFromString(name);
                if (![device respondsToSelector:selector]) return NULL;
                id value = ((id (*)(id, SEL))objc_msgSend)(device, selector);
                if (![value isKindOfClass:NSString.class] || ![value length]) return NULL;
                headers[deviceKeys[name]] = value;
            }
            headers[@"X-Apple-I-MD-RINFO"] = @"17106176";
            NSData *data = [NSJSONSerialization dataWithJSONObject:headers options:0 error:nil];
            if (!data || data.length > 16384) return NULL;
            char *result = calloc(data.length + 1, 1);
            if (result) memcpy(result, data.bytes, data.length);
            return result;
        } @catch (NSException *exception) { return NULL; }
    }
}
void mp_auth_free(char *value) { if (value) { memset(value, 0, strlen(value)); free(value); } }
