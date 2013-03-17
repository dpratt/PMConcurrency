//
//  NSManagedObjectContext+Future.h
//  ConcurrencyUtils
//
//  Created by David Pratt on 3/17/13.
//  Copyright (c) 2013 David Pratt. All rights reserved.
//

#import <CoreData/CoreData.h>

#import "CUFuture.h"

@interface NSManagedObjectContext (Future)

- (CUFuture *)performFuture:(future_block)block;

@end
