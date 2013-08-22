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
    PMOperationExecutingState   = 2,
    PMOperationFinishedState    = 3,
} _PMOperationState;

typedef signed short PMOperationState;

static inline NSString * PMKeyPathFromOperationState(PMOperationState state) {
    switch (state) {
        case PMOperationReadyState:
            return @"isReady";
        case PMOperationExecutingState:
            return @"isExecuting";
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
                case PMOperationExecutingState:
                    return YES;
                case PMOperationFinishedState:
                    return isCancelled;
                default:
                    return NO;
            }
        case PMOperationExecutingState:
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

/**
 The result of this operation. Accessing this value before 'isFinished' is true will throw an exception. If there was an error
 executing this operation, the value will be nil.
 */
@property (readwrite, nonatomic, strong) id result;

/**
 The error, if any, that occurred while executing the operation. This value is undefined and invalid if 'isFinished' is false.
 */
@property (readwrite, nonatomic, strong) NSError *error;

@property (readwrite, nonatomic, assign) PMOperationState state;
//since this is a conPMrrent operation, we need a lock to ensure that
//our spawned threads don't conflict with each other. We could just surround
//all sensitive calls in @synchronized(self) but I actually prefer an
//explicit lock
@property (readwrite, nonatomic, strong) NSRecursiveLock *lock;

@property (readwrite, nonatomic, assign, getter = isCancelled) BOOL cancelled;

// The result of this operation.
@property (readwrite, nonatomic, strong) PMFuture *future;

@end

@implementation PMFutureOperation

+ (instancetype)futureOperationWithBlock:(future_block)block {
    return [[PMFutureOperation alloc] initWithBlock:block];
}

+ (instancetype)futureOperation {
    return [[PMFutureOperation alloc] init];
}

- (instancetype)initWithBlock:(future_block)body {
    if(self = [super init]) {
        _lock = [[NSRecursiveLock alloc] init];
        _lock.name = @"com.primemoverlabs.futureoperation.lock";
        _operationBody = body;
        _state = PMOperationReadyState;
    }
    return self;
    
}

- (instancetype)init {
    return [self initWithBlock:nil];
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
    return self.state == PMOperationExecutingState;
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
        self.state = PMOperationExecutingState;
        if([self isCancelled]) {
            //if we're cancelled, just mark as finished.
            [self finish];
        } else {
            if(self.operationBody) {
                id bodyResult = self.operationBody();
                if([bodyResult isKindOfClass:[PMFuture class]]) {
                    self.future = bodyResult;
                } else {
                    self.future = [PMFuture future];
                    [self.future tryComplete:bodyResult];
                }
                
                //this operation flips to finished when the contained future completes
                __weak PMFutureOperation *weakSelf = self;
                [self.future onComplete:^(id result, NSError *error) {
                    weakSelf.result = result;
                    weakSelf.error = error;
                    [weakSelf finish];
                }];
                [self.future onCancel:^{
                    [weakSelf cancel];
                }];
                //don't need it anymore
                self.operationBody = nil;
            } else {
                [self finish];
                NSLog(@"Completing future with no body.");
            }
        }
        self.operationBody = nil;
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
        [self.future cancel];
        if(self.isExecuting) {
            [self finish];
        }
    }
    [self.lock unlock];
}

- (void)finish {
    [self.lock lock];
    self.state = PMOperationFinishedState;
    self.future = nil;
    self.operationBody = nil;
    [self.lock unlock];
}

@end
