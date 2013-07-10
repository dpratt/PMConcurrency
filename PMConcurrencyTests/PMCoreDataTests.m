//
//  PMCoreDataTests.m
//  PMConcurrency
//
//  Created by David Pratt on 7/10/13.
//  Copyright (c) 2013 David Pratt. All rights reserved.
//

#import "PMCoreDataTests.h"
#import <CoreData/CoreData.h>

#import "NSManagedObjectContext+Future.h"
#import "PMTestEntity.h"

@implementation PMCoreDataTests

- (void)testCoreData {
    
    NSPersistentStoreCoordinator *psc = [self createManagedObjectContextForModel:@"TestModel"];
    NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];
    [moc setPersistentStoreCoordinator:psc];
    
    PMFuture *entityFuture = [moc performFuture:^id(NSError *__autoreleasing *error) {
        PMTestEntity *ent = [NSEntityDescription insertNewObjectForEntityForName:@"PMTestEntity" inManagedObjectContext:moc];
        ent.name = @"Sample Entity";
        ent.entityId = @2;
        [moc save:error];
        return ent;
    }];
    
    [entityFuture onComplete:^(id result, NSError *error) {
        STAssertNotNil(result, @"Expected a result.");
        STAssertNil(error, @"Expected no error.");
    }];
    
    NSError *blockingError = nil;
    [PMFuture awaitResult:entityFuture withTimeout:1.0 andError:&blockingError];
    STAssertNil(blockingError, @"Expected no error.");

}

- (void)testComplexInteraction {
    NSPersistentStoreCoordinator *psc = [self createManagedObjectContextForModel:@"TestModel"];
    NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [moc setPersistentStoreCoordinator:psc];

    PMFuture *entityFuture = [moc performFuture:^id(NSError *__autoreleasing *error) {
        PMTestEntity *ent = [NSEntityDescription insertNewObjectForEntityForName:@"PMTestEntity" inManagedObjectContext:moc];
        ent.name = @"Sample Entity";
        ent.entityId = @2;
        [moc save:error];
        return ent;
    }];

    [entityFuture map:^id(PMTestEntity *testEntity, NSError **error) {
        testEntity.entityId = @3;
        return testEntity;
    }];
    NSError *blockingError = nil;
    PMTestEntity *ent = [PMFuture awaitResult:entityFuture withTimeout:1.0 andError:&blockingError];
    STAssertNil(blockingError, @"Expected no error.");
    STAssertNotNil(ent, @"Expected entity to be not-nil.");

}

- (NSPersistentStoreCoordinator *)createManagedObjectContextForModel:(NSString *)modelName {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    
    NSManagedObjectModel *objectModel = [NSManagedObjectModel mergedModelFromBundles:@[bundle]];
    
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:objectModel];
    
    NSError *error;
    
    [coordinator addPersistentStoreWithType:NSInMemoryStoreType
                              configuration:nil
                                        URL:nil
                                    options:nil
                                      error:&error];
    
    return coordinator;
}


@end
