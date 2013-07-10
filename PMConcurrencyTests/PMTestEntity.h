//
//  PMTestEntity.h
//  PMConcurrency
//
//  Created by David Pratt on 7/10/13.
//  Copyright (c) 2013 David Pratt. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>


@interface PMTestEntity : NSManagedObject

@property (nonatomic, retain) NSString * name;
@property (nonatomic, retain) NSNumber * entityId;

@end
