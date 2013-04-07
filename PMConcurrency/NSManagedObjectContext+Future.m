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
    //set the queue on the promise to nil to make sure its callbacks execute on the thread that the
    //supplied block executes on (which should be the designated thread for the context)
    PMFuture *promise = [PMFuture futureWithQueue:nil];
    void (^callback)(void) = ^{
        NSError *error = nil;
        id value = block(&error);
        if(error != nil) {
            [promise tryFail:error];
        } else {
            [promise tryComplete:value];
        }
    };
    if(self.concurrencyType == NSConfinementConcurrencyType) {
        //confinement concurrency means the caller is responsible for executing us in the proper thread
        callback();
    } else {
        [self performBlock:^{
            callback();
        }];
    }
    return promise;
}
@end