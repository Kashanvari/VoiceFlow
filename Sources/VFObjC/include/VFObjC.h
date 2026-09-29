#import <Foundation/Foundation.h>

/// Runs `block` and returns nil, or the reason if it raised an Objective-C exception.
/// Swift cannot catch these; without this, one bad microphone format quits the whole app.
NSString * _Nullable VFCatch(void (NS_NOESCAPE ^ _Nonnull block)(void));
