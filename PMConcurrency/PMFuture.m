//
//  PMFuture.m
//
//  Created by David Pratt on 3/14/13.
//  Copyright (c) 2013 David Pratt. All rights reserved.
//

#import "PMFuture.h"
#import "PMFutureOperation.h"

NSString * const kPMFutureErrorDomain = @"PMFutureErrorDomain";

typedef enum {
    Incomplete = 0,
    Success   = 1,
    Failure   = 2,
    Cancelled = 3
} FutureState;

//internal details
typedef void (^callback_block)(FutureState state, id internalResult, NSError *internalError);
typedef void (^callback_runner)(FutureState state, id internalResult, NSError *internalError, callback_block callback);

@interface PMFuture () {
    NSMutableArray *_callbacks;
    
    NSRecursiveLock *_stateLock;
    FutureState _state;
    
    callback_runner _callbackRunner;
}

@end

@implementation PMFuture

+ (instancetype)future {
    return [[PMFuture alloc] init];
}

+ (instancetype)futureWithQueue:(dispatch_queue_t)queue {
    return [[PMFuture alloc] initWithQueue:queue];
}

+ (instancetype)futureWithBlock:(future_block)block {
    return [self futureWithBlock:block andQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
}

+ (instancetype)futureWithBlock:(future_block)block andQueue:(dispatch_queue_t)queue {
    if(block == nil) {
        @throw [NSException exceptionWithName:@"NSInvalidArgumentException"
                                       reason:@"The block supplied to futureWithBlock must not be nil."
                                     userInfo:nil];
    }
    
    PMFuture *retval = [[PMFuture alloc] initWithQueue:queue];
    dispatch_async(queue, ^{
        //checking if it's complete avoids running the block if the future has been cancelled or completed externally
        if(!retval.isCompleted) {
            [retval tryComplete:block()];
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
        promise = [promise map:^PMFuture *(NSMutableArray *promiseResult) {
            PMFuture *futureOfResultArray = [future map:^id(id result) {
                if(result != nil) {
                    [promiseResult addObject:result];
                } else {
                    NSLog(@"Future sequenced with nil result.");
                    [promiseResult addObject:[NSNull null]];
                }
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
    //this violates the contract slightly - we actually want this callback to execute even if it's cancelled
    [future invokeOrAddCallback:^(FutureState state, id result, NSError *internalError) {
        if(internalError != nil) {
            *error = internalError;
        } else {
            futureResult = result;
        }
        dispatch_semaphore_signal(sem);
    }];
    
    long result = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, timeout * NSEC_PER_SEC));
    if(result != 0) {
        //timed out!
        if(error != NULL) {
            *error = [NSError errorWithDomain:kPMFutureErrorDomain
                                         code:kPMFutureErrorTimeout
                                     userInfo:@{NSLocalizedDescriptionKey : @"Timed out waiting for result of future."}];
        }
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
    if([value isKindOfClass:[NSError class]]) {
        return [self tryFail:value];
    } else if([value isKindOfClass:[PMFuture class]]) {
        return [self completeWith:value];
    } else {
        return [self trySuccess:value];
    }
}

- (BOOL)trySuccess:(id)value {
    BOOL didComplete = NO;
    [_stateLock lock];
    if(!self.isCompleted) {
#ifdef DEBUG
        if([value isKindOfClass:[PMFuture class]]) {
            [NSException raise:@"PMFutureException" format:@"Cannot complete a PMFuture with another Future - use tryComplete or completeWith instead.", nil];
        }
#endif
        _value = value;
        didComplete = [self complete:Success];
    }
    [_stateLock unlock];
    return didComplete;    
}

- (BOOL)tryFail:(NSError *)error {
    BOOL didComplete = NO;
    [_stateLock lock];
    if(!self.isCompleted) {
        if(error == nil) {
            //we're being marked as a failure, but with no error.
            _error = [NSError errorWithDomain:kPMFutureErrorDomain
                                         code:kPMFutureErrorUnknown
                                     userInfo:@{NSLocalizedDescriptionKey : @"Future marked as failed, but with no supplied error."}];
        } else {
            _error = error;
        }
        didComplete = [self complete:Failure];
    }
    [_stateLock unlock];
    return didComplete;
}

- (BOOL)completeWith:(PMFuture *)otherFuture {
    BOOL didComplete = NO;
    [_stateLock lock];
    if(!self.isCompleted) {
        didComplete = YES;
        [otherFuture onComplete:^(id result, NSError *error) {
            if(error != nil) {
                [self tryFail:error];
            } else {
                [self trySuccess:result];
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
    [self onComplete:^(id myResult, NSError *error) {
        __strong PMFuture *strongSelf = weakSelf;
        if(strongSelf.isSuccess) {
            successBlock(myResult);
        }
    }];
}

- (void)onFailure:(void (^)(NSError *error))failureBlock {
    if(failureBlock == nil) return;
    __weak PMFuture *weakSelf = self;
    [self onComplete:^(id result, NSError *myError) {
        __strong PMFuture *strongSelf = weakSelf;
        if(!strongSelf.isSuccess) {
            failureBlock(myError);
        }
    }];
}

- (void)onComplete:(void (^)(id result, NSError *error))completeBlock {
    if(completeBlock == nil) return;
    
    [self invokeOrAddCallback:^(FutureState state, id internalResult, NSError *internalError) {
        if(state != Incomplete && state != Cancelled) {
            completeBlock(internalResult, internalError);
        }
    }];
}

- (void)onCancel:(void (^)())cancelBlock {
    if(cancelBlock == nil) return;
    [self invokeOrAddCallback:^(FutureState state, id internalResult, NSError *internalError) {
        if(state == Cancelled) {
            cancelBlock();
        }
    }];
}

- (PMFuture *)map:(id (^)(id value))mapper {
    if(mapper == nil) return self;
    
    PMFuture *promise = [[PMFuture alloc] initWithCallbackRunner:_callbackRunner andParent:self];
    
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

- (PMFuture *)recover:(id (^)(NSError *error))recoverBlock {
    if(recoverBlock == nil) return self;
    
    PMFuture *other = [[PMFuture alloc] initWithCallbackRunner:_callbackRunner andParent:self];
    [self onComplete:^(id result, NSError *error) {
        if(error != nil) {            
            id recoverVal = recoverBlock(error);
            if([recoverVal isKindOfClass:[NSError class]]) {
                [other tryFail:recoverVal];
            } else if([recoverVal isKindOfClass:[PMFuture class]]) {
                [other completeWith:recoverVal];
            } else {
                [other tryComplete:recoverVal];
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

- (PMFuture *)onMainThread {
    return [self withQueue:dispatch_get_main_queue()];
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
        //it's important that we clear out the callbacks here - these blocks
        //can hold long reference chains that we no longer will need once they've been executed.
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
    _callbackRunner(_state, _value, _error, block);
}

//internal use only
//this is the 'actual' designated initializer - but INTERNAL USE ONLY
- (instancetype)initWithCallbackRunner:(callback_runner)callbackRunner andParent:(PMFuture *)parent {
    if(self = [super init]) {
        _state = Incomplete;
        _callbacks = [NSMutableArray array];
        _stateLock = [[NSRecursiveLock alloc] init];
        __weak PMFuture *weakSelf = self;
        //ensure that we cancel when our dependent future does as well.
        [parent onCancel:^{
            __strong PMFuture *strongSelf = weakSelf;
            [strongSelf cancel];
        }];
        _callbackRunner = callbackRunner;
    }
    return self;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue andParent:(PMFuture *)parent {
    return [self initWithCallbackRunner:^(FutureState state, id internalResult, NSError *internalError, callback_block callback) {
        dispatch_async(queue, ^{
            callback(state, internalResult, internalError);
        });
    } andParent:parent];
}


@end
