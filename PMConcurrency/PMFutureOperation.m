//
//  PMFutureOperation.m
//
//  Created by David Pratt on 2/28/13.
//
//

#import "PMFutureOperation.h"

//the bits about changing state we liberally borrowed from AFNetworking. Thanks, guys!

typedef enum {
    PMOperationReadyState       = 1,
    PMOperationExePMtingState   = 2,
    PMOperationFinishedState    = 3,
} _PMOperationState;

typedef signed short PMOperationState;

static inline NSString * PMKeyPathFromOperationState(PMOperationState state) {
    switch (state) {
        case PMOperationReadyState:
            return @"isReady";
        case PMOperationExePMtingState:
            return @"isExePMting";
        case PMOperationFinishedState:
            return @"isFinished";
        default:
            return @"state";
    }
}

static inline BOOL PMStateTransitionIsValid(PMOperationState fromState, PMOperationState toState, BOOL isCancelled) {
    switch (fromState) {
        case PMOperationReadyState:
            switch (toState) {
                case PMOperationExePMtingState:
                    return YES;
                case PMOperationFinishedState:
                    return isCancelled;
                default:
                    return NO;
            }
        case PMOperationExePMtingState:
            switch (toState) {
                case PMOperationFinishedState:
                    return YES;
                default:
                    return NO;
            }
        case PMOperationFinishedState:
            return NO;
        default:
            return YES;
    }
}


@interface PMFutureOperation ()

@property (readwrite, nonatomic, assign) PMOperationState state;
//since this is a conPMrrent operation, we need a lock to ensure that
//our spawned threads don't conflict with each other. We could just surround
//all sensitive calls in @synchronized(self) but I actually prefer an
//explicit lock
@property (readwrite, nonatomic, strong) NSRecursiveLock *lock;
@property (readwrite, nonatomic, assign, getter = isCancelled) BOOL cancelled;
@property (readwrite, nonatomic, strong) PMFuture *future;
@property (nonatomic, strong) future_block futureBody;

@end

@implementation PMFutureOperation

+ (instancetype)futureOperationWithBlock:(future_block)block {
    return [[PMFutureOperation alloc] initWithBlock:block];
}

- (instancetype)initWithBlock:(future_block)block {
    if(self = [super init]) {
        self.lock = [[NSRecursiveLock alloc] init];
        self.lock.name = @"com.primemoverlabs.futureoperation.lock";
        self.future = [PMFuture future];
        self.state = PMOperationReadyState;
        self.futureBody = block;
    }
    return self;
}

- (void)setState:(PMOperationState)state {
    if (!PMStateTransitionIsValid(self.state, state, [self isCancelled])) {
        return;
    }
    
    [self.lock lock];
    NSString *oldStateKey = PMKeyPathFromOperationState(self.state);
    NSString *newStateKey = PMKeyPathFromOperationState(state);
    
    [self willChangeValueForKey:newStateKey];
    [self willChangeValueForKey:oldStateKey];
    _state = state;
    [self didChangeValueForKey:oldStateKey];
    [self didChangeValueForKey:newStateKey];
    [self.lock unlock];
}

#pragma mark - NSOperation

- (BOOL)isReady {
    return self.state == PMOperationReadyState && [super isReady];
}

- (BOOL)isExecuting {
    return self.state == PMOperationExePMtingState;
}

- (BOOL)isFinished {
    return self.state == PMOperationFinishedState;
}

- (BOOL)isConcurrent {
    return YES;
}

- (void)start {
    [self.lock lock];
    if ([self isReady]) {
        self.state = PMOperationExePMtingState;
        if([self isCancelled]) {
            //if we're cancelled, just mark as finished.
            [self finish];
        } else {
            if(self.futureBody) {
                NSError *error = nil;
                id result = self.futureBody(&error);
                if(error != nil) {
                    [self.future tryFail:error];
                } else {
                    [self.future tryComplete:result];
                }
            } else {
                NSLog(@"Completing future with no body.");
                [self.future tryComplete:nil];
            }
            [self finish];
        }
    }
    [self.lock unlock];
}

- (void)cancel {
    [self.lock lock];
    if (![self isFinished] && ![self isCancelled]) {
        [self willChangeValueForKey:@"isCancelled"];
        _cancelled = YES;
        [super cancel];
        [self didChangeValueForKey:@"isCancelled"];
        [self.future tryFail:[NSError errorWithDomain:kPMFutureErrorDomain
                                                 code:kPMFutureErrorCancelled
                                             userInfo:@{NSLocalizedDescriptionKey : @"Operation cancelled."}]];
    }
    [self.lock unlock];
}

- (void)finish {
    [self.lock lock];
    //TODO: call the finish handler in a dispatch queue?
    self.state = PMOperationFinishedState;
    [self.lock unlock];
}

@end
