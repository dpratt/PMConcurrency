//
//  PMFutureOperation.h
//
//  Created by David Pratt on 2/28/13.
//
//

#import <Foundation/Foundation.h>
#import "PMFuture.h"

/**
 This class essentially wraps the execution of a PMFuture instance inside an NSOperation. It's useful when you have 
 flows of computation that are modeled with PMFutures, but you have existing APIs that expect result values to be NSOperations.
 */
@interface PMFutureOperation : NSOperation

/*
 A block that will be the source of this operation's computation. This is a block that returns a PMFuture. When this returned future completes,
 this operation completes.
 */
@property (nonatomic, strong) future_block operationBody;

/**
 The result of this operation. Accessing this value before 'isFinished' is true will throw an exception. If there was an error
 executing this operation, the value will be nil.
 */
@property (readonly, nonatomic, strong) id result;

/**
 The error, if any, that occurred while executing the operation. This value is undefined and invalid if 'isFinished' is false.
 */
@property (readonly, nonatomic, strong) NSError *error;

/**
 Create a new operation with the supplied block, which will be run on the NSOperationQueue that this operation is submitted to.
 If the resulting value from this block is a PMFuture, the future returned from this operation will be completed with it. If 
 it is of any other type, the resulting future from this operation will be completed with the raw value.
 */
+ (instancetype)futureOperationWithBlock:(future_block)block;

+ (instancetype)futureOperation;

- (instancetype)initWithBlock:(future_block)body;

@end
