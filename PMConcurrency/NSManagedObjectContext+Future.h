//
//  NSManagedObjectContext+Future.h
//  ConcurrencyUtils
//
//  Created by David Pratt on 3/17/13.
//  Copyright (c) 2013 David Pratt. All rights reserved.
//

#import <CoreData/CoreData.h>

#import "PMFuture.h"

@interface NSManagedObjectContext (Future)

- (PMFuture *)performFuture:(future_block)block;

@end
