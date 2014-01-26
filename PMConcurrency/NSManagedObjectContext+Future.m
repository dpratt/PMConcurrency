//
//  NSManagedObjectContext+Future.m
//  ConcurrencyUtils
//
//  Created by David Pratt on 3/17/13.
//  Copyright (c) 2013 David Pratt. All rights reserved.
//

#import "NSManagedObjectContext+Future.h"

@implementation NSManagedObjectContext (Future)

- (PMFuture *)performFuture:(future_block)block {
    if(block == nil) {
        //this is bad
        @throw [NSException exceptionWithName:@"NSInvalidArgumentException" reason:@"the block passed to performFuture must not be nil." userInfo:nil];
    }
    
    PMFuture *promise = [PMFuture futureWithExecutor:^(FutureState state, id internalResult, NSError *internalError, callback_block callback) {
        [self performBlock:^{
            callback(state, internalResult, internalError);
        }];
    }];
    if(self.concurrencyType == NSConfinementConcurrencyType) {
        @throw [NSException exceptionWithName:@"NSInvalidArgumentException" reason:@"performFuture cannot be used with confinement concurrency." userInfo:nil];
    } else {
        //prevent deadlocks
        if(self.concurrencyType == NSMainQueueConcurrencyType && [NSThread isMainThread]) {
            [promise tryComplete:block()];
        } else {
            [self performBlock:^{
                if(promise.isCancelled) {
                    return;
                }
                [promise tryComplete:block()];
            }];
        }
    }
    
    return promise;
}
@end
