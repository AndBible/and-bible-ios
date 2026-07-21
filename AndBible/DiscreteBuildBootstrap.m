// DiscreteBuildBootstrap.m - Calculator SKU startup defaults

#import <Foundation/Foundation.h>

/**
 Enforces the Calculator SKU's launch gate before SwiftUI initializes `@AppStorage`.

 The dedicated discrete target has a fixed Calculator bundle identity. Its startup path must also
 present the calculator gate regardless of settings restored from another product. This constructor
 runs before the SwiftUI app value is created, persists the target-owned bootstrap preference, and
 places the same value in the process argument domain so later restore or sync writes cannot disable
 the gate while the discrete app is running.

 Side effects:
 - writes `show_calculator = true` to the Calculator SKU's isolated persistent defaults domain
 - forces `show_calculator = true` in the process-local argument domain for the app lifetime

 Failure modes:
 - `NSUserDefaults` writes are best-effort and do not report an error; failure leaves the app's
   compiled Swift default in effect.
 */
__attribute__((constructor))
static void ABEnforceDiscreteBuildDefaults(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary<NSString *, id> *argumentDefaults =
            [[defaults volatileDomainForName:NSArgumentDomain] mutableCopy];
        if (argumentDefaults == nil) {
            argumentDefaults = [NSMutableDictionary dictionary];
        }

        argumentDefaults[@"show_calculator"] = @YES;
        [defaults setVolatileDomain:argumentDefaults forName:NSArgumentDomain];
        [defaults setBool:YES forKey:@"show_calculator"];
    }
}
