//
//  CUFuture.h
//
//  Created by David Pratt on 3/14/13.
//  Copyright (c) 2013 David Pratt. All rights reserved.
//

#import <Foundation/Foundation.h>

@class CUFuture;

typedef id (^future_block)(NSError **error);

typedef id (^recover_block)(NSError **error);
typedef CUFuture *(^flat_recover_block)(NSError **);

extern NSString * const kCUFutureErrorDomain;

typedef enum {
    kCUFutureErrorCancelled = 100,
    kCUFutureErrorTimeout = 101,
    kCUFutureErrorUnknown = 102
} CUFutureErrors;

@interface CUFuture : NSObject

/*
 Return a new, uncompleted future.
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
+ (instancetype)futureWithBlock:(future_block)block withQueue:(dispatch_queue_t)queue;

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
+ (id)awaitResult:(CUFuture *)future withTimeout:(NSTimeInterval)timeout andError:(NSError **)error;

@property (nonatomic, readonly, getter = isCompleted) BOOL completed;
@property (nonatomic, readonly, getter = isFailed) BOOL failed;
@property (nonatomic, readonly, getter = isSuccess) BOOL success;
@property (nonatomic, readonly, getter = isCancelled) BOOL cancelled;

- (instancetype)initWithQueue:(dispatch_queue_t)queue;

/*
 Attempt to cancel this Future if it has not yet completed. If the cancellation succeeds, no further 
 action will be taken by this future via callbacks or any other operation.
 
 Note - this method may or may not cause any background processing associated with this future to terminate.
 The only guarantee is that this Future no longer will respond to any callback attempts.
 
 Additionally, this Future has the option of propagating the cancel event to any of it's dependent futures. A
 dependent future is defined as any future that this Future may be waiting or dependent on.
 
 If this future has already completed, this method has no effect.
 */
- (void)cancel;

- (void)onSuccess:(void (^)(id result))successBlock;
- (void)onFailure:(void (^)(NSError *error))failureBlock;
- (void)onComplete:(void (^)(id result, NSError *error))completeBlock;
- (void)onCancel:(void (^)())cancelBlock;

/*
 Return a future with a transformed result. The eventual future will consist of either the value produced by
 this Future and then transformed by the supplied block, or an error.
 */
- (CUFuture *)map:(id (^)(id result))mapper;

/*
 The flattened version of the above. Transform the eventual result of this future using supplied 
 block that produces another future.
 */
- (CUFuture *)flatMap:(CUFuture *(^)(id result))mapper;

/*
 Complete this future with the specified value. Returns NO if this future has already been completed.
 */
- (BOOL)tryComplete:(id)result;

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
- (BOOL)completeWith:(CUFuture *)otherFuture;

/*
 Attempt to recover this future from an error. The passed in block will be executed when this Future is completed
 with an error. The associated error will be passed in as an argument to the block, and this method assumes that
 if the error parameter is still populated (i.e. not nil) after the block executes the error cannot be handled.
 If the error parameter is set to nil, the Future produced by this method will be completed with the value 
 returned from the specified block.
 */
- (CUFuture *)recover:(recover_block)recoverBlock;

/*
 The flattened version of the above - attempt to recover this future with the the future returned by recoverBlock.
 */
- (CUFuture *)recoverWith:(flat_recover_block)recoverBlock;

/*
 Set a time bound on this future - if it does not complete or fail inside of the specified interval, the returned
 future will be completed with a timeout error.
 */
- (CUFuture *)withTimeout:(NSTimeInterval)timeout;

/*
 Return a Future that will execute it's callbacks on the specified queue.
 */
- (CUFuture *)withQueue:(dispatch_queue_t)queue;

@end
