// duopose: puts a booted iPhone Duo simulator in a pose, for run-simulator.sh -f. It asks
// SpringBoard's display tool service to sweep the hinge, as Device Hub's pose controls do, and
// takes the same arguments as SpringBoard's own display tool:
//
//   duopose -position=<closed|book|open|0.0-1.0> [-deviceOrientation=<portrait|landscapeLeft|…>]
//           [-duration=<seconds>] [-wait]
//
// Built for the simulator only (run-simulator.sh does it) and run with `simctl spawn`. The service
// takes clients that hold com.apple.springboard.sbdisplay.service (duopose.entitlements). Private
// API, so it lives with the tests and never ships in the app.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

// The parser fills the service's settings through its second argument and returns BOOL.
// This is the 64-byte iOS 27.1 simulator ABI, not a struct-return function.
typedef struct { long long state; double duration; long long orientation; long long profile; BOOL wait; long long mode; double position; double lockedUntil; } SwapSettings;
_Static_assert(sizeof(SwapSettings) == 64, "iOS 27.1 display-tool settings ABI");

int main(int argc, char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/SpringBoardFoundation.framework/SpringBoardFoundation", RTLD_NOW);
        BOOL (*parse)(NSArray *, SwapSettings *, NSError **) = dlsym(RTLD_DEFAULT, "SBFDisplayToolSwapSettingsFromArguments");
        Class service = NSClassFromString(@"SBSDisplayToolService");
        if (!parse || !service) {
            fprintf(stderr, "duopose: this runtime has no display tool service (not an iPhone Duo runtime?)\n");
            return 69;
        }
        NSMutableArray *arguments = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [arguments addObject:@(argv[i])];
        NSError *error = nil;
        SwapSettings settings = { 0 };
        if (!parse(arguments, &settings, &error)) {
            fprintf(stderr, "duopose: %s\n", error ? error.localizedDescription.UTF8String : "invalid pose arguments");
            return 64;
        }
        id tool = [[service alloc] init];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSError *failure = nil;
        ((void (*)(id, SEL, SwapSettings, void (^)(NSError *)))objc_msgSend)(
            tool, sel_registerName("swapDisplayWithSettings:completionHandler:"), settings, ^(NSError *e) {
                failure = e;
                dispatch_semaphore_signal(done);
            });
        long late = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
        ((void (*)(id, SEL))objc_msgSend)(tool, sel_registerName("invalidate"));
        if (late) {
            fprintf(stderr, "duopose: SpringBoard did not answer\n");
            return 75;
        }
        if (failure) {
            fprintf(stderr, "duopose: %s\n", failure.description.UTF8String);
            return 70;
        }
    }
    return 0;
}
