//
//  PMFuture.h
//
//  Created by David Pratt on 3/14/13.
//  Copyright (c) 2013 David Pratt. All rights reserved.
//

#import <Foundation/Foundation.h>

@class PMFuture;

typedef id (^future_block)(void);

extern NSString * const kPMFutureErrorDomain;

typedef enum {
    kPMFutureErrorCancelled = 100,
    kPMFutureErrorTimeout = 101,
    kPMFutureErrorUnknown = 102
} PMFutureErrors;

typedef enum {
    Incomplete = 0,
    Success   = 1,
    Failure   = 2,
    Cancelled = 3
} FutureState;

typedef void (^callback_block)(FutureState state, id internalResult, NSError *internalError);
typedef void (^callback_runner)(FutureState state, id internalResult, NSError *internalError, callback_block callback);


/*
 A class that models a value that may or may not be immediately available. A PMFuture offers the ability to compose with
 either operations that transform it's output or with other PMFutures entirely.
 
 This class also offers the ability to cancel the computation, and have that cancellation propogate down to any child 
 Futures generated by this Future.
 
 Note: Unless otherwise noted, any method that returns a new PMFuture computed from an existing instance will use the
 same callback execution method that the parent context does.
 */
@interface PMFuture : NSObject

/*
 Return a new, uncompleted future who's callbacks will execute on an unspecified background queue.
 */
+ (instancetype)future;

/*
 Return a new uncompleted future who's callbacks will execute on the specified queue.
 */
+ (instancetype)futureWithQueue:(dispatch_queue_t)queue;

/*
 Return a future that will be completed with the result of executing the supplied block on an unspecified background queue.
 */
+ (instancetype)futureWithBlock:(future_block)block;

/*
 Return a future that will be completed with the result of executing the supplied block on the specified queue.
 */
+ (instancetype)futureWithBlock:(future_block)block andQueue:(dispatch_queue_t)queue;

/*
 Return a future that will execute it's callbacks with the supplied runner.
 */
+ (instancetype)futureWithExecutor:(callback_runner)callbackRunner;

/*
 Return a new future that will be completed with the result of executing the supplied block on the supplied NSOperationQueue.
 Note - the callbacks from this Future will *not* execute on the NSOperationQueue, but rather an unspecified background dispatch queue.
 This is in order to guarantee that the callbacks are not abandoned in case the NSOperationQueue cancels all it's operations.
 */
//+ (instancetype)futureWithBlock:(future_block)block operationQueue:(NSOperationQueue *)queue andPriority:(NSOperationQueuePriority)priority;

/*
 Return a Future that is instantly completed with the supplied value.
 */
+ (instancetype)futureWithResult:(id)result;

/*
 Return a Future that is instantly completed with the supplied error.
 */
+ (instancetype)futureWithError:(NSError *)error;

/*
 Transform an array of futures into a future of an array of the results.
 */
+ (instancetype)sequenceFutures:(NSArray *)futures;

/*
 Await the result of the supplied future. THIS METHOD BLOCKS THE CURRENT THREAD.
 */
+ (id)awaitResult:(PMFuture *)future withTimeout:(NSTimeInterval)timeout andError:(NSError **)error;

@property (nonatomic, readonly, getter = isCompleted) BOOL completed;
@property (nonatomic, readonly, getter = isFailed) BOOL failed;
@property (nonatomic, readonly, getter = isSuccess) BOOL success;
@property (nonatomic, readonly, getter = isCancelled) BOOL cancelled;

/*
 If this Future has completed successfully, this is the value of the future. If this is still uncompleted or 
 completed with an error, the value of this property is undefined.
 */
@property (nonatomic, strong, readonly) id value;

/*
 If this Future completed with an error, the value of the error. If this is still uncompleted or
 completed successfully, the value of this property is undefined.
 */
@property (nonatomic, strong, readonly) NSError *error;

/*
 The designated initializer for PMFuture.
 */
- (instancetype)initWithQueue:(dispatch_queue_t)queue;

/*
 Attempt to cancel this Future if it has not yet completed. If the cancellation succeeds, no further 
 action will be taken by this future via callbacks or any other operation.
 
 Note - this method may or may not cause any background processing associated with this future to terminate.
 The only guarantee is that this Future no longer will respond to any callback attempts.
 
 Additionally, this Future has the option of propagating the cancel event to any of it's dependent futures. A
 dependent future is defined as any future that may be waiting for the result of this Future.
 
 If this future has already completed, this method has no effect.
 */
- (void)cancel;

/*
 Add a callback to execute when this Future completes successfully.
 */
- (void)onSuccess:(void (^)(id result))successBlock;

/*
 Add a callback that will execute when this Future completes with an error.
 */
- (void)onFailure:(void (^)(NSError *error))failureBlock;

/*
 Add a callback that will execute when this future completes with any value. Note - this will not be triggered
 if the Future is cancelled.
 */
- (void)onComplete:(void (^)(id result, NSError *error))completeBlock;

/*
 Add a callback that will execute only with this Future is cancelled.
 */
- (void)onCancel:(void (^)())cancelBlock;

/*
 Return a future with a transformed result. The eventual future will consist of either the value produced by
 this Future and then transformed by the supplied block, or an error. The resulting Future is populated by the following rules -
   - If the result of the mapper is an NSError*, the resulting future is failed with the same error.
   - If the result of the mapper is a PMFuture*, the resulting future will be completed with the eventual value (or error) of the mapped result PMFuture.
   - If the result is any other type, the resulting Future will be completed with this value.
 */
- (PMFuture *)map:(id (^)(id value))mapper;

/*
 Attempt to recover this future from an error. The passed in block will be executed when this Future is completed
 with an error. This method is similar to the 'map' function, but instead for errors.
 - If the result of the recover block is an NSError*, the resulting future is failed with the same error.
 - If the result of the recover block is a PMFuture*, the resulting future will be completed with the eventual value (or error) of the mapped result PMFuture.
 - If the result is any other type, the resulting Future will be completed with this value.
 */
- (PMFuture *)recover:(id (^)(NSError *error))recoverBlock;

/*
 Attempt to complete this future with the supplied value, according to the following rules:
 - If the value is an NSError*, this future will be failed with the error - this is the same as calling tryFail:
 - If the value is a PMFuture*, this future will be completed with the eventual value of this future - this is the same as calling completeWith:
 - If the value is any other type, this future will completed with the value - this is the same as calling trySuccess
 */
- (BOOL)tryComplete:(id)result;

/*
 Complete this future with the specified value. Returns NO if this future has already been completed. 
 Note - this method does not examine the type of the value - if this method is used directly, it's possible 
 to successfully complete with an NSError or PMFuture, which is likely not what you want.
 */
- (BOOL)trySuccess:(id)value;

/*
 Complete this future with the specified failure. Return NO if this future has already been completed.
 */
- (BOOL)tryFail:(NSError *)error;

/*
 Complete this future with the value provided by the other future. If this future completes before the other,
 no error will be generated, but the status of the other future will be ignored. This method produces a future
 with a dependency on the supplied future. If the resultant future is cancelled, a cancellation message will
 be sent to the parent future as well.
 
 Returns NO if this future has already been completed or associated with another parent future.
 */
- (BOOL)completeWith:(PMFuture *)otherFuture;

/*
 Set a time bound on this future - if it does not complete or fail inside of the specified interval, the returned
 future will be completed with a timeout error.
 */
- (PMFuture *)withTimeout:(NSTimeInterval)timeout;

/*
 Return a copy of this Future that will execute it's callbacks on the specified queue. The new Future will complete
 with the same result as the original (and at the same time) but any callbacks added to this future will execute
 in the new queue.
 */
- (PMFuture *)withQueue:(dispatch_queue_t)queue;

/*
 Return a copy of this future that will execute it's callbacks on the main thread.
 */
- (PMFuture *)onMainThread;

@end
