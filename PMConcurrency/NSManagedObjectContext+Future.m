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
    
    PMFuture *promise = [PMFuture future];
    if(self.concurrencyType == NSConfinementConcurrencyType) {
        //confinement concurrency means the caller is responsible for executing us in the proper thread
        @autoreleasepool {
            [promise tryComplete:block()];
        }
    } else {
        [self performBlock:^{
            if(promise.isCancelled) {
                return;
            }
            [promise tryComplete:block()];
        }];
    }
    
    return promise;
}
@end
