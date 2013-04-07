//
//  PMFutureOperation.h
//
//  Created by David Pratt on 2/28/13.
//
//

#import <Foundation/Foundation.h>
#import "PMFuture.h"

@interface PMFutureOperation : NSOperation

/**
 The result of this operation.
 */
@property (readonly, nonatomic, strong) PMFuture *future;

+ (instancetype)futureOperationWithBlock:(future_block)block;

- (instancetype)initWithBlock:(future_block)block;

@end
