// Blocking HTTPS GET on Apple platforms (NSURLSession, ARC). Used by the DEM tile fetcher on its I/O threads.
#import <Foundation/Foundation.h>
#include <cstring>
#include "pw/env/codec.h"

namespace pw::env {

bool httpGet(const std::string& url, double timeoutSeconds, std::vector<uint8_t>& out, int& status, std::string& err) {
    status = 0; out.clear();
    @autoreleasepool {
        NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
        if (!u) { err = "bad URL"; return false; }
        static NSURLSession* session = [] {
            NSURLSessionConfiguration* c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            c.HTTPMaximumConnectionsPerHost = 6;
            c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;   // we keep our own disk cache
            return [NSURLSession sessionWithConfiguration:c];
        }();
        NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:u];
        req.timeoutInterval = timeoutSeconds;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSData* body = nil;
        __block NSInteger code = 0;
        __block NSString* error = nil;
        NSURLSessionDataTask* task = [session dataTaskWithRequest:req completionHandler:^(NSData* d, NSURLResponse* r, NSError* e) {
            if (e) error = [e localizedDescription];
            if ([r isKindOfClass:[NSHTTPURLResponse class]]) code = [(NSHTTPURLResponse*)r statusCode];
            body = d;
            dispatch_semaphore_signal(sem);
        }];
        [task resume];
        long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, int64_t((timeoutSeconds + 5) * NSEC_PER_SEC)));
        if (waited != 0) { [task cancel]; err = "timeout"; return false; }
        if (error) { err = [error UTF8String]; return false; }
        status = int(code);
        if (body) { out.resize([body length]); if (!out.empty()) std::memcpy(out.data(), [body bytes], out.size()); }
        return true;
    }
}

} // namespace pw::env
