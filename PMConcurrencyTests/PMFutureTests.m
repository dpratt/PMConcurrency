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

    id value = [PMFuture awaitResult:result withTimeout:10.0 andError:nil];
    
    STAssertTrue(result.isSuccess, @"Future is not successful.");
    //STAssertNil(error, @"Error is not nil - %@", error);
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
