//
//  PMFutureTests.m
//  PMConcurrencyTests
//
//  Created by David Pratt on 3/17/13.
//  Copyright (c) 2013 David Pratt. All rights reserved.
//

#import "PMFutureTests.h"

#import "PMFuture.h"

@implementation PMFutureTests

- (void)setUp {
    [super setUp];
}

- (void)tearDown {
    [super tearDown];
}

- (void)testSuccess {
    PMFuture *future = [PMFuture future];
    [future tryComplete:@1];
    
    STAssertTrue(future.isCompleted, @"Future is not completed.");
    STAssertTrue(future.isSuccess, @"Future is not successful.");
    STAssertFalse(future.isCancelled, @"Future cancelled.");
    STAssertFalse(future.isFailed, @"Future has failed.");
}

- (void)testFailure {
    PMFuture *future = [PMFuture future];
    [future tryFail:[NSError errorWithDomain:@"DummyDomain" code:100 userInfo:nil]];
    
    STAssertTrue(future.isCompleted, @"Future is not completed.");
    STAssertFalse(future.isSuccess, @"Future is successful.");
    STAssertFalse(future.isCancelled, @"Future cancelled.");
    STAssertTrue(future.isFailed, @"Future has not failed.");
}

- (void)testCompleteWith {
    PMFuture *future = [PMFuture future];
    [future completeWith:[PMFuture futureWithBlock:^id(NSError *__autoreleasing *error) {
        return @"Hi there.";
    }]];
    
    NSError *blockingError = nil;
    id value = [PMFuture awaitResult:future withTimeout:0.1 andError:&blockingError];
    STAssertNil(blockingError, @"Got an error - %@", blockingError);
    STAssertNotNil(value, @"Expected a non-nil value.");
    STAssertEqualObjects(value, @"Hi there.", @"Expected value to be \"Hi there.\" got %@", value);
}

- (void)testMap {
    PMFuture *future = [[PMFuture futureWithResult:@1] map:^id(id result, NSError **error) {
        return [NSNumber numberWithInt:[result intValue] + 1];
    }];

    id value = [PMFuture awaitResult:future withTimeout:10.0 andError:nil];
    
    STAssertTrue(future.isSuccess, @"Future is not successful.");
    STAssertEqualObjects(value, @2, @"Expected result of future to be 2.");
}

- (void)testMapFailure {
    PMFuture *future = [[PMFuture futureWithResult:@1] map:^id(id result, NSError **error) {
        *error = [NSError errorWithDomain:@"TestDomain" code:100 userInfo:@{NSLocalizedDescriptionKey : @"Hi there."}];
        //return a value and ensure that it gets discarded
        return @"Hi there.";
    }];
    
    NSError *futureError = nil;
    id value = [PMFuture awaitResult:future withTimeout:10.0 andError:&futureError];
    
    STAssertTrue(future.isFailed, @"Future should have failed.");
    STAssertNil(value, @"Expected result of future to be nil.");
    STAssertNotNil(futureError, @"Expected error to be non-nil.");
    STAssertEquals(futureError.code, 100, @"Expected error code to be 100.");
    STAssertEqualObjects(futureError.domain, @"TestDomain", @"Expected error code to be 100.");
}

- (void)testFlatMap {
    
    PMFuture *future = [[PMFuture futureWithResult:@1] flatMap:^PMFuture *(id value, NSError *__autoreleasing *error) {
        return [PMFuture futureWithBlock:^id(NSError *__autoreleasing *error) {
            return [NSNumber numberWithInt:[value intValue] + 1];
        }];
    }];
    id value = [PMFuture awaitResult:future withTimeout:10.0 andError:nil];
    
    STAssertTrue(future.isSuccess, @"Future is not successful.");
    STAssertEqualObjects(value, @2, @"Expected result of future to be 2.");

}

- (void)testFlatMapFailure {
    
    PMFuture *future = [[PMFuture futureWithResult:@1] flatMap:^PMFuture *(id value, NSError *__autoreleasing *error) {
        return [PMFuture futureWithBlock:^id(NSError *__autoreleasing *error) {
            *error = [NSError errorWithDomain:@"TestDomain" code:100 userInfo:@{NSLocalizedDescriptionKey : @"Hi there."}];
            //return a value and ensure that it gets discarded
            return @"Hi there.";
        }];
    }];
    
    NSError *futureError = nil;
    id value = [PMFuture awaitResult:future withTimeout:10.0 andError:&futureError];
    
    STAssertTrue(future.isFailed, @"Future should have failed.");
    STAssertNil(value, @"Expected result of future to be nil.");
    STAssertNotNil(futureError, @"Expected error to be non-nil.");
    STAssertEquals(futureError.code, 100, @"Expected error code to be 100.");
    STAssertEqualObjects(futureError.domain, @"TestDomain", @"Expected error code to be 100.");
    
}



- (void)testSequence {
    
    NSArray *futures = @[
                         [PMFuture futureWithBlock:^id(NSError *__autoreleasing *error) {
                             return @1;
                         }],
                         [PMFuture futureWithBlock:^id(NSError *__autoreleasing *error) {
                             return @2;
                         }],
                         [PMFuture futureWithBlock:^id(NSError *__autoreleasing *error) {
                             return @3;
                         }]
                         ];
    
    PMFuture *result = [PMFuture sequenceFutures:futures];

    NSError *futureError = nil;
    id value = [PMFuture awaitResult:result withTimeout:10.0 andError:&futureError];
    
    STAssertTrue(result.isSuccess, @"Future is not successful.");
    STAssertNil(futureError, @"Error is not nil - %@", futureError);
    STAssertNotNil(value, @"Expected result to be not nil.");
    STAssertTrue([value isKindOfClass:[NSArray class]], @"Expected an NSArray back from sequence.");
    
    for(id num in value) {
        STAssertTrue([num isKindOfClass:[NSNumber class]], @"Expected element to be of type NSNumber, got %@ instead.", NSStringFromClass([num class]));
    }
    STAssertEqualObjects(@6, [value valueForKeyPath:@"@sum.self"], @"Expected result to be 6.");

}

- (void)testSequenceFailed {
    
    NSArray *futures = @[
                         [PMFuture futureWithBlock:^id(NSError *__autoreleasing *error) {
                             return @1;
                         }],
                         [PMFuture futureWithBlock:^id(NSError *__autoreleasing *error) {
                             //fail this single future
                             *error = [NSError errorWithDomain:@"TestDomain" code:100 userInfo:@{NSLocalizedDescriptionKey : @"Hi there."}];
                             return @"Foo";
                         }],
                         [PMFuture futureWithBlock:^id(NSError *__autoreleasing *error) {
                             return @3;
                         }]
                         ];
    
    PMFuture *result = [PMFuture sequenceFutures:futures];
    
    NSError *futureError = nil;
    id value = [PMFuture awaitResult:result withTimeout:10.0 andError:&futureError];
    
    STAssertTrue(result.isFailed, @"Future is not failed.");
    STAssertNotNil(futureError, @"Error is not nil - %@", futureError);
    STAssertNil(value, @"Expected result to be nil.");
    STAssertEquals(futureError.code, 100, @"Expected error code to be 100.");
    STAssertEqualObjects(futureError.domain, @"TestDomain", @"Expected error code to be 100.");

}

- (void)testQueues {
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t firstQueue = dispatch_queue_create("first", DISPATCH_QUEUE_CONCURRENT);
    dispatch_queue_t secondQueue = dispatch_queue_create("second", DISPATCH_QUEUE_CONCURRENT);
    
    PMFuture *firstFuture = [PMFuture futureWithQueue:firstQueue];

    PMFuture *secondFuture = [firstFuture withQueue:secondQueue];
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    dispatch_group_enter(group);
    [firstFuture onComplete:^(id result, NSError *error) {
        STAssertEquals(dispatch_get_current_queue(), firstQueue, @"First callback executed in incorrect queue!");
        dispatch_group_leave(group);
    }];

    dispatch_group_enter(group);
    [secondFuture onComplete:^(id result, NSError *error) {
        STAssertEquals(dispatch_get_current_queue(), secondQueue, @"Second callback executed in incorrect queue!");
        dispatch_group_leave(group);
    }];
#pragma clang diagnostic pop
    
    [firstFuture tryComplete:@"Hi there!"];
    NSError *futureError = nil;
    [PMFuture awaitResult:secondFuture withTimeout:10.0 andError:&futureError];
    
    STAssertTrue(firstFuture.isSuccess, @"First future was not successful.");
    STAssertTrue(secondFuture.isSuccess, @"Second future was not successful.");

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

}

- (void)testCancel {
    PMFuture *firstFuture = [PMFuture future];
    PMFuture *secondFuture = [PMFuture future];
    [secondFuture completeWith:firstFuture];
    
    [firstFuture cancel];
    NSError *futureError = nil;
    [PMFuture awaitResult:firstFuture withTimeout:1.0 andError:&futureError];
    STAssertTrue(futureError.code != kPMFutureErrorTimeout, @"First future timed out! - %@", futureError);
    STAssertTrue(firstFuture.isCancelled, @"First future was not cancelled!");

    futureError = nil;
    [PMFuture awaitResult:secondFuture withTimeout:1.0 andError:&futureError];
    STAssertTrue(futureError.code != kPMFutureErrorTimeout, @"Second future timed out! - %@", futureError);
    
    STAssertTrue(firstFuture.isCancelled, @"First future was not cancelled!");
    STAssertTrue(secondFuture.isCancelled, @"Second future was not cancelled!");
}

- (void)testCancelChild {
    PMFuture *firstFuture = [PMFuture future];
    PMFuture *secondFuture = [PMFuture future];
    [secondFuture completeWith:firstFuture];
    
    [secondFuture cancel];
    NSError *futureError = nil;
    [PMFuture awaitResult:secondFuture withTimeout:1.0 andError:&futureError];
    STAssertTrue(futureError.code != kPMFutureErrorTimeout, @"Second future timed out! - %@", futureError);
    STAssertTrue(secondFuture.isCancelled, @"Second future was not cancelled!");

    futureError = nil;
    [firstFuture tryComplete:@"Hi there."];
    NSString *result = [PMFuture awaitResult:firstFuture withTimeout:1.0 andError:&futureError];
    STAssertTrue(futureError.code != kPMFutureErrorTimeout, @"First future timed out! - %@", futureError);
    STAssertTrue(firstFuture.isSuccess, @"First future was not successful!");
    STAssertEqualObjects(result, @"Hi there.", @"Unexpected result from first future.");    
}


- (void)testBlockingTimeout {
    
    PMFuture *future = [PMFuture futureWithBlock:^id(NSError *__autoreleasing *error) {
        [NSThread sleepForTimeInterval:0.5];
        return @"Hi there.";
    }];

    NSError *timeoutError = nil;
    [PMFuture awaitResult:future withTimeout:0.1 andError:&timeoutError];
    STAssertNotNil(timeoutError, @"Expected a timeout error.");
    
}
@end
