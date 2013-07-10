//
//  PMFuture.m
//
//  Created by David Pratt on 3/14/13.
//  Copyright (c) 2013 David Pratt. All rights reserved.
//

#import "PMFuture.h"

NSString * const kPMFutureErrorDomain = @"PMFutureErrorDomain";

typedef enum {
    Incomplete = 0,
    Success   = 1,
    Failure   = 2,
    Cancelled = 3
} FutureState;

@interface PMFuture () {
    NSMutableArray *_callbacks;
    
    NSRecursiveLock *_stateLock;
    FutureState _state;
    
    callback_runner _callbackRunner;
}

@property (nonatomic, strong) id value;
@property (nonatomic, strong) NSError *error;

@end

@implementation PMFuture

+ (instancetype)future {
    return [[PMFuture alloc] init];
}

+ (instancetype)futureWithQueue:(dispatch_queue_t)queue {
    return [[PMFuture alloc] initWithQueue:queue];
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
    
    PMFuture *retval = [[PMFuture alloc] initWithQueue:queue];
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
    PMFuture *future = [self future];
    [future tryComplete:result];
    return future;
}

+ (instancetype)futureWithError:(NSError *)error {
    PMFuture *future = [self future];
    [future tryFail:error];
    return future;    
}

+ (instancetype)sequenceFutures:(NSArray *)futures {
    PMFuture *promise = [PMFuture futureWithResult:[NSMutableArray arrayWithCapacity:futures.count]];
    for(PMFuture *future in futures) {
        promise = [promise flatMap:^PMFuture *(NSMutableArray *promiseResult, NSError **flatError) {
            PMFuture *futureOfResultArray = [future map:^id(id result, NSError **error) {
                [promiseResult addObject:result];
                return promiseResult;
            }];
            return futureOfResultArray;
        }];
    }
    return promise;
}

/*
 Await the result of the supplied future. THIS METHOD BLOCKS THE CURRENT THREAD.
 */
+ (id)awaitResult:(PMFuture *)future withTimeout:(NSTimeInterval)timeout andError:(NSError **)error {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block id futureResult;
    __weak PMFuture *weakFuture = future;
    //this violates the contract slightly - we actually want this callback to execute even if it's cancelled
    [future invokeOrAddCallback: ^{
        if(weakFuture.error != nil) {
            *error = weakFuture.error;
        } else {
            futureResult = weakFuture.value;
        }
        dispatch_semaphore_signal(sem);
    }];
    
    long result = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_SEC));
    if(result != 0) {
        //timed out!
        *error = [NSError errorWithDomain:kPMFutureErrorDomain
                                     code:kPMFutureErrorTimeout
                                 userInfo:@{NSLocalizedDescriptionKey : @"Timed out waiting for result of future."}];
        return nil;
    } else {
        return futureResult;
    }
    
}

- (instancetype)init {
    return [self initWithQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    return [self initWithQueue:queue andParent:nil];
}

- (instancetype)initWithCallbackRunner:(callback_runner)callbackRunner {
    return [self initWithCallbackRunner:callbackRunner andParent:nil];
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
        _error = [NSError errorWithDomain:kPMFutureErrorDomain
                                     code:kPMFutureErrorUnknown
                                 userInfo:@{NSLocalizedDescriptionKey : @"Future marked as failed, but with no supplied error."}];
    } else {
        _error = error;
    }
    BOOL didComplete = [self complete:Failure];
    [_stateLock unlock];
    return didComplete;
}

- (BOOL)completeWith:(PMFuture *)otherFuture {
    [_stateLock lock];
    BOOL didComplete = NO;
    if(!self.isCompleted) {
        didComplete = YES;
        [otherFuture onComplete:^(id result, NSError *error) {
            if(error != nil) {
                [self tryFail:error];
            } else {
                [self tryComplete:result];
            }
        }];
        //ensure that this future is cancelled if the parent future is cancelled.
        [otherFuture onCancel:^{
            [self cancel];
        }];
    }
    [_stateLock unlock];
    return didComplete;
}

- (void)cancel {
    [_stateLock lock];
    if(!self.isCompleted) {
        //not completed yet, we can cancel
        
        _error = [NSError errorWithDomain:kPMFutureErrorDomain
                                     code:kPMFutureErrorCancelled
                                 userInfo:@{NSLocalizedDescriptionKey : @"The future has been cancelled."}];
        //now transition our state
        [self complete:Cancelled];
        
        _callbacks = nil;
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
    __weak PMFuture *weakSelf = self;
    [self onComplete:^(id result, NSError *error) {
        if(weakSelf.isSuccess) {
            successBlock(result);
        }
    }];
}

- (void)onFailure:(void (^)(NSError *error))failureBlock {
    if(failureBlock == nil) return;
    __weak PMFuture *weakSelf = self;
    [self onComplete:^(id result, NSError *error) {
        if(weakSelf.isSuccess) {
            failureBlock(error);
        }
    }];
}

- (void)onComplete:(void (^)(id result, NSError *error))completeBlock {
    if(completeBlock == nil) return;
    //use weakSelf because otherwise the block below would capture
    //self and we'd get a retain cycle.
    __weak PMFuture *weakSelf = self;
    [self invokeOrAddCallback:^{
        //don't run completion blocks for cancelled futures
        if(!weakSelf.isCancelled && weakSelf.isCompleted) {
            completeBlock(_value, _error);
        }
    }];
}

- (void)onCancel:(void (^)())cancelBlock {
    if(cancelBlock == nil) return;
    __weak PMFuture *weakSelf = self;
    [self invokeOrAddCallback:^{
        if(weakSelf.isCancelled) {
            cancelBlock();
        }
    }];
}

- (PMFuture *)map:(id (^)(id value, NSError** error))mapper {
    if(mapper == nil) return self;
    
    PMFuture *promise = [[PMFuture alloc] initWithCallbackRunner:_callbackRunner andParent:self];
    
    [self onComplete:^(id result, NSError *error) {
        if(error != nil) {
            [promise tryFail:error];
        } else {
            NSError *nestedError = nil;
            id mapped = mapper(result, &nestedError);
            if(nestedError != nil) {
                //an error in the mapper function itself
                [promise tryFail:nestedError];
            } else {
                [promise tryComplete:mapped];
            }        
        }
    }];
    
    return promise;
}

- (PMFuture *)flatMap:(PMFuture *(^)(id value, NSError** error))mapper {
    if(mapper == nil) return self;
    
    PMFuture *promise = [[PMFuture alloc] initWithCallbackRunner:_callbackRunner andParent:self];
    
    [self onComplete:^(id result, NSError *error) {
        if(error != nil) {
            [promise tryFail:error];
        } else {
            NSError *nestedError = nil;
            PMFuture *nested = mapper(result, &nestedError);
            if(nestedError != nil) {
                //there was an error in the mapper itself
                //the promise returned by this method should be failed
                [promise tryFail:nestedError];
            } else {
                [nested onComplete:^(id result, NSError *error) {
                    if(error != nil) {
                        [promise tryFail:error];
                    } else {
                        [promise tryComplete:result];
                    }
                }];
            }
        }
    }];
    
    return promise;
}

- (PMFuture *)recover:(recover_block)recoverBlock {
    if(recoverBlock == nil) return self;
    
    PMFuture *other = [[PMFuture alloc] initWithCallbackRunner:_callbackRunner andParent:self];
    [self onComplete:^(id result, NSError *error) {
        if(error != nil) {
            NSError *internalError = error;
            id internalResult = recoverBlock(&internalError);
            if(internalError != nil) {
                [other tryFail:internalError];
            } else {
                [other tryComplete:internalResult];
            }
        } else {
            [other tryComplete:result];
        }
    }];
    return other;
}

- (PMFuture *)recoverWith:(flat_recover_block)recoverBlock {
    if(recoverBlock == nil) return self;
    
    PMFuture *other = [[PMFuture alloc] initWithCallbackRunner:_callbackRunner andParent:self];
    [self onComplete:^(id result, NSError *error) {
        if(error != nil) {
            NSError *internalError = error;
            PMFuture *internalResult = recoverBlock(&internalError);
            if(internalError != nil) {
                [other tryFail:internalError];
            } else {
                [other completeWith:internalResult];
            }
        } else {
            [other tryComplete:result];
        }
    }];
    return other;
}

- (PMFuture *)withTimeout:(NSTimeInterval)timeout {
    PMFuture *timeoutFuture = [[PMFuture alloc] initWithCallbackRunner:_callbackRunner andParent:nil];
    
    //complete the timeout future when we complete
    [timeoutFuture completeWith:self];

    //fire the acutal timeout on a default background queue
    //this won't affect the callbacks of the resulting future - those get handled by the callbackrunner
    dispatch_queue_t timeoutQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_source_t timeoutTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, timeoutQueue);
    dispatch_source_set_timer(timeoutTimer, dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(timeoutTimer, ^{
        [timeoutFuture tryFail:[NSError errorWithDomain:kPMFutureErrorDomain
                                                   code:kPMFutureErrorTimeout
                                               userInfo:@{NSLocalizedDescriptionKey : @"The future timed out."}]];
         dispatch_source_cancel(timeoutTimer);
    });
    
    //start the timer
    dispatch_resume(timeoutTimer);
    
    [timeoutFuture onComplete:^(id result, NSError *error) {
        //cancel the timer when we complete
        dispatch_source_cancel(timeoutTimer);
    }];
    
    return timeoutFuture;
}

- (PMFuture *)withQueue:(dispatch_queue_t)queue {
    PMFuture *promise = [[PMFuture alloc] initWithQueue:queue andParent:self];
    [promise completeWith:self];
    return promise;
}

- (PMFuture *)withCallbackRunner:(callback_runner)callbackRunner {
    PMFuture *promise = [[PMFuture alloc] initWithCallbackRunner:callbackRunner andParent:self];
    [promise completeWith:self];
    return promise;
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
    _callbackRunner(block);
}

//internal use only
//this is the 'actual' designated initializer - but INTERNAL USE ONLY
- (instancetype)initWithCallbackRunner:(callback_runner)callbackRunner andParent:(PMFuture *)parent {
    if(self = [super init]) {
        _state = Incomplete;
        _callbacks = [NSMutableArray array];
        _stateLock = [[NSRecursiveLock alloc] init];
        //ensure that we cancel when our dependent future does as well.
        [parent onCancel:^{
            [self cancel];
        }];
        _callbackRunner = callbackRunner;
    }
    return self;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue andParent:(PMFuture *)parent {
    return [self initWithCallbackRunner:^(callback_block callback) {
        dispatch_async(queue, callback);
    } andParent:parent];
}


@end
