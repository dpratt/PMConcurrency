//
//  CUFuture.m
//
//  Created by David Pratt on 3/14/13.
//  Copyright (c) 2013 David Pratt. All rights reserved.
//

#import "CUFuture.h"

typedef void (^callback_block)(void);

NSString * const kCUFutureErrorDomain = @"CUFutureErrorDomain";

typedef enum {
    Incomplete = 0,
    Success   = 1,
    Failure   = 2,
    Cancelled = 3
} FutureState;

@interface CUFuture () {
    dispatch_queue_t _queue;
    NSMutableArray *_callbacks;
    id _value;
    NSError *_error;
    
    NSRecursiveLock *_stateLock;
    FutureState _state;
}

@property (nonatomic, strong) CUFuture *parentFuture;

@end

@implementation CUFuture

+ (instancetype)future {
    return [[CUFuture alloc] init];
}

+ (instancetype)futureWithQueue:(dispatch_queue_t)queue {
    return [[CUFuture alloc] initWithQueue:queue];
}

+ (instancetype)futureWithBlock:(future_block)block {
    return [self futureWithBlock:block withQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
}

+ (instancetype)futureWithBlock:(future_block)block withQueue:(dispatch_queue_t)queue {
    if(block == nil) {
        @throw [NSException exceptionWithName:@"NSInvalidArgumentException"
                                       reason:@"The block supplied to futureWithBlock must not be nil."
                                     userInfo:nil];
    }
    
    CUFuture *retval = [[CUFuture alloc] initWithQueue:queue];
    dispatch_async(queue, ^{
        NSError *error = nil;
        id result = block(&error);
        if(error != nil) {
            [retval tryFail:error];
        } else {
            [retval tryComplete:result];
        }
    });
    return retval;
}

+ (instancetype)futureWithResult:(id)result {
    CUFuture *future = [self future];
    [future tryComplete:result];
    return future;
}

+ (instancetype)futureWithError:(NSError *)error {
    CUFuture *future = [self future];
    [future tryFail:error];
    return future;    
}

+ (instancetype)sequenceFutures:(NSArray *)futures {
    CUFuture *promise = [CUFuture futureWithResult:[NSMutableArray arrayWithCapacity:futures.count]];
    for(CUFuture *future in futures) {
        promise = [promise flatMap:^CUFuture *(NSMutableArray *promiseResult) {
            return [future map:^id(id result) {
                [promiseResult addObject:result];
                return promiseResult;
            }];
        }];
    }
    return promise;
}

/*
 Await the result of the supplied future. THIS METHOD BLOCKS THE CURRENT THREAD.
 */
+ (id)awaitResult:(CUFuture *)future withTimeout:(NSTimeInterval)timeout andError:(NSError **)error {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block id futureResult = nil;
    
    [[future withTimeout:timeout] onComplete:^(id result, NSError *futureError) {
        futureResult = result;
        if(error != nil && futureError != nil) {
            *error = futureError;
        }
        dispatch_semaphore_signal(sem);
    }];
    
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return futureResult;
}

- (instancetype)init {
    return [self initWithQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    return [self initWithQueue:queue andParent:nil];
}

- (BOOL)tryComplete:(id)value {
    [_stateLock lock];
    _value = value;
    BOOL didComplete = [self complete:Success];
    [_stateLock unlock];
    return didComplete;
}

- (BOOL)tryFail:(NSError *)error {
    [_stateLock lock];
    if(error == nil) {
        //we're being marked as a failure, but with no error.
        _error = [NSError errorWithDomain:kCUFutureErrorDomain
                                     code:kCUFutureErrorUnknown
                                 userInfo:@{NSLocalizedDescriptionKey : @"Future marked as failed, but with no supplied error."}];
    } else {
        _error = error;
    }
    BOOL didComplete = [self complete:Failure];
    [_stateLock unlock];
    return didComplete;
}

- (BOOL)completeWith:(CUFuture *)otherFuture {
    [_stateLock lock];
    BOOL didComplete = NO;
    if(!self.isCompleted && _parentFuture == nil) {
        _parentFuture = otherFuture;
        didComplete = YES;
        [otherFuture onComplete:^(id result, NSError *error) {
            if(error != nil) {
                [self tryFail:error];
            } else {
                [self tryComplete:result];
            }
        }];
    }
    [_stateLock unlock];
    return didComplete;
}

- (void)cancel {
    [_stateLock lock];
    if(!self.isCompleted) {
        //not completed yet, we can cancel
        
        //cancel our parent first
        [_parentFuture cancel];
        
        _error = [NSError errorWithDomain:kCUFutureErrorDomain
                                     code:kCUFutureErrorCancelled
                                 userInfo:@{NSLocalizedDescriptionKey : @"The future has been cancelled."}];
        //now transition our state
        [self complete:Cancelled];
        
        
        _callbacks = nil;
        _parentFuture = nil;
    }
    [_stateLock unlock];
}

- (BOOL)isCompleted {
    return _state != Incomplete;
}

- (BOOL)isSuccess {
    return _state == Success;
}

- (BOOL)isFailed {
    return _state == Failure;
}

- (BOOL)isCancelled {
    return _state == Cancelled;
}

- (void)onSuccess:(void (^)(id result))successBlock {
    if(successBlock == nil) return;
    __weak CUFuture *weakSelf = self;
    [self invokeOrAddCallback:^{
        if(weakSelf.isSuccess) {
            successBlock(_value);
        }
    }];
}

- (void)onFailure:(void (^)(NSError *error))failureBlock {
    if(failureBlock == nil) return;
    __weak CUFuture *weakSelf = self;
    [self invokeOrAddCallback:^{
        if(weakSelf.isFailed) {
            failureBlock(_error);
        }
    }];    
}

- (void)onComplete:(void (^)(id result, NSError *error))completeBlock {
    if(completeBlock == nil) return;
    //use weakSelf because otherwise the block below would capture
    //self and we'd get a retain cycle.
    __weak CUFuture *weakSelf = self;
    [self invokeOrAddCallback:^{
        //don't run completion blocks for cancelled futures
        if(!weakSelf.isCancelled) {
            completeBlock(_value, _error);
        }
    }];
}

- (void)onCancel:(void (^)())cancelBlock {
    if(cancelBlock == nil) return;
    __weak CUFuture *weakSelf = self;
    [self invokeOrAddCallback:^{
        if(weakSelf.isCancelled) {
            cancelBlock();
        }
    }];
}

- (CUFuture *)map:(id (^)(id result))mapper {
    if(mapper == nil) return self;
    
    CUFuture *promise = [[CUFuture alloc] initWithQueue:_queue andParent:self];
    
    [self onComplete:^(id result, NSError *error) {
        if(error != nil) {
            [promise tryFail:error];
        } else {
            id mapped = mapper(result);
            [promise tryComplete:mapped];
        }
    }];
    
    return promise;
}

- (CUFuture *)flatMap:(CUFuture *(^)(id result))mapper {
    if(mapper == nil) return self;
    
    CUFuture *promise = [[CUFuture alloc] initWithQueue:_queue andParent:self];
    
    [self onComplete:^(id result, NSError *error) {
        if(error != nil) {
            [promise tryFail:error];
        } else {
            CUFuture *nested = mapper(result);
            [nested onComplete:^(id result, NSError *error) {
                if(error != nil) {
                    [promise tryFail:error];
                } else {
                    [promise tryComplete:result];
                }
            }];
        }
    }];
    
    return promise;
}

- (CUFuture *)recover:(recover_block)recoverBlock {
    if(recoverBlock == nil) return self;
    
    CUFuture *other = [[CUFuture alloc] initWithQueue:_queue andParent:self];
    [self onFailure:^(NSError *error) {
        NSError *internalError = error;
        id result = recoverBlock(&internalError);
        if(internalError != nil) {
            [other tryFail:internalError];
        } else {
            [other tryComplete:result];
        }
    }];
    return other;
}

- (CUFuture *)recoverWith:(flat_recover_block)recoverBlock {
    if(recoverBlock == nil) return self;
    
    CUFuture *other = [[CUFuture alloc] initWithQueue:_queue andParent:self];
    [self onFailure:^(NSError *error) {
        NSError *internalError = error;
        CUFuture *result = recoverBlock(&internalError);
        if(internalError != nil) {
            [other tryFail:internalError];
        } else {
            [other completeWith:result];
        }
    }];
    return other;
}

- (CUFuture *)withTimeout:(NSTimeInterval)timeout {
    CUFuture *timeoutFuture = [[CUFuture alloc] initWithQueue:_queue];
    
    //complete the timeout future when we complete
    [timeoutFuture completeWith:self];
    
    dispatch_queue_t timeoutQueue = _queue;
    if(timeoutQueue == nil) {
        //use the default background queue
        //note - there's a danger here, in that the thread/queue that the callback
        //handlers are invoked on is defined as 'the current thread' when the queue is nil
        //since a timeout completion will be handled by the system rather than explicitly
        //in user code, this may cause the user's code to act strange. I don't think this is a big deal
        //since the case of having an undefined queue is a rare one, and users do understand the danger there
        timeoutQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    }
    
    dispatch_source_t timeoutTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, timeoutQueue);
    dispatch_source_set_timer(timeoutTimer, dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(timeoutTimer, ^{
        [timeoutFuture tryFail:[NSError errorWithDomain:kCUFutureErrorDomain
                                                   code:kCUFutureErrorTimeout
                                               userInfo:@{NSLocalizedDescriptionKey : @"The future timed out."}]];
         dispatch_source_cancel(timeoutTimer);
    });
    
    //start the timer
    dispatch_resume(timeoutTimer);
    
    return timeoutFuture;
}

- (CUFuture *)withQueue:(dispatch_queue_t)queue {
    return [[CUFuture alloc] initWithQueue:queue andParent:self];
}

#pragma mark - internal private methods

- (void)invokeOrAddCallback:(callback_block)block {
    
    if(block == nil) return;
    
    BOOL shouldExecute = YES;
    
    [_stateLock lock];
    
    if(!self.isCompleted) {
        [_callbacks addObject:block];
        shouldExecute = NO;
    }
    
    [_stateLock unlock];
    
    if(shouldExecute) {
        [self runBlock:block];
    }
}

- (BOOL)complete:(FutureState)newState {
    NSArray *callbackBlocks = nil;
    BOOL didComplete = NO;
    [_stateLock lock];
    if(_state == Incomplete) {
        didComplete = YES;
        callbackBlocks = _callbacks;
        _callbacks = nil;
        _state = newState;
    }
    [_stateLock unlock];
    if(callbackBlocks != nil) {
        for(callback_block block in callbackBlocks) {
            [self runBlock:block];
        }
    }
    return didComplete;
}

- (void)runBlock:(callback_block)block {
    if(_queue) {
        dispatch_async(_queue, block);
    } else {
        block();
    }
}

//internal use only
- (instancetype)initWithQueue:(dispatch_queue_t)queue andParent:(CUFuture *)parent {
    if(self = [super init]) {
        _queue = queue;
        _state = Incomplete;
        _callbacks = [NSMutableArray array];
        _stateLock = [[NSRecursiveLock alloc] init];
        _parentFuture = parent;
    }
    return self;
}


@end
