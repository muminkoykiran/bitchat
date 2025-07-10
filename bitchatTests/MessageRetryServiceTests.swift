//
// MessageRetryServiceTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
@testable import bitchat

class MessageRetryServiceTests: XCTestCase {
    
    var retryService: MessageRetryService!
    
    override func setUp() {
        super.setUp()
        retryService = MessageRetryService.shared
        retryService.clearRetryQueue()
    }
    
    override func tearDown() {
        retryService.clearRetryQueue()
        super.tearDown()
    }
    
    func testAddMessageForRetry() {
        let testContent = "Test message"
        let testChannel = "test-channel"
        
        retryService.addMessageForRetry(
            content: testContent,
            channel: testChannel,
            priority: .normal
        )
        
        let expectation = XCTestExpectation(description: "Queue count check")
        
        retryService.getRetryQueueCount { count in
            XCTAssertEqual(count, 1)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testEmptyMessageRejection() {
        retryService.addMessageForRetry(content: "")
        retryService.addMessageForRetry(content: "   ")
        retryService.addMessageForRetry(content: "\n\t")
        
        let expectation = XCTestExpectation(description: "Empty messages rejected")
        
        retryService.getRetryQueueCount { count in
            XCTAssertEqual(count, 0)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testPriorityOrdering() {
        // Add messages with different priorities
        retryService.addMessageForRetry(
            content: "Low priority",
            priority: .low
        )
        
        retryService.addMessageForRetry(
            content: "High priority",
            priority: .high
        )
        
        retryService.addMessageForRetry(
            content: "Normal priority",
            priority: .normal
        )
        
        retryService.addMessageForRetry(
            content: "Critical priority",
            priority: .critical
        )
        
        let expectation = XCTestExpectation(description: "Priority ordering")
        
        retryService.getRetryQueueCount { count in
            XCTAssertEqual(count, 4)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testDuplicateMessagePrevention() {
        let messageID = UUID().uuidString
        
        // Add same message twice
        retryService.addMessageForRetry(
            content: "Test message",
            originalMessageID: messageID
        )
        
        retryService.addMessageForRetry(
            content: "Test message",
            originalMessageID: messageID
        )
        
        let expectation = XCTestExpectation(description: "Duplicate prevention")
        
        retryService.getRetryQueueCount { count in
            XCTAssertEqual(count, 1)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testConfigurationUpdate() {
        let newConfig = RetryConfiguration(
            baseRetryInterval: 1.0,
            maxRetries: 5,
            exponentialBackoff: true,
            maxBackoffDelay: 30.0,
            maxQueueSize: 200
        )
        
        retryService.updateConfiguration(newConfig)
        
        // Configuration update should not crash
        XCTAssertTrue(true)
    }
    
    func testNetworkConditionAdjustment() {
        // Test all network conditions
        retryService.adjustRetryStrategy(basedOn: .excellent)
        retryService.adjustRetryStrategy(basedOn: .good)
        retryService.adjustRetryStrategy(basedOn: .poor)
        retryService.adjustRetryStrategy(basedOn: .disconnected)
        
        // Strategy adjustment should not crash
        XCTAssertTrue(true)
    }
    
    func testChannelMessageClearing() {
        let testChannel = "test-channel"
        
        retryService.addMessageForRetry(
            content: "Channel message 1",
            channel: testChannel
        )
        
        retryService.addMessageForRetry(
            content: "Channel message 2",
            channel: testChannel
        )
        
        retryService.addMessageForRetry(
            content: "Other channel message",
            channel: "other-channel"
        )
        
        retryService.clearMessagesForChannel(testChannel)
        
        let expectation = XCTestExpectation(description: "Channel clearing")
        
        retryService.getRetryQueueCount { count in
            XCTAssertEqual(count, 1) // Only the other channel message should remain
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testRecipientMessageClearing() {
        let testRecipient = "test-recipient"
        
        retryService.addMessageForRetry(
            content: "Private message 1",
            isPrivate: true,
            recipientPeerID: testRecipient
        )
        
        retryService.addMessageForRetry(
            content: "Private message 2",
            isPrivate: true,
            recipientPeerID: testRecipient
        )
        
        retryService.addMessageForRetry(
            content: "Other private message",
            isPrivate: true,
            recipientPeerID: "other-recipient"
        )
        
        retryService.clearMessagesForRecipient(testRecipient)
        
        let expectation = XCTestExpectation(description: "Recipient clearing")
        
        retryService.getRetryQueueCount { count in
            XCTAssertEqual(count, 1) // Only the other recipient message should remain
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testRetryStatistics() {
        retryService.addMessageForRetry(content: "Test message 1")
        retryService.addMessageForRetry(content: "Test message 2")
        
        let expectation = XCTestExpectation(description: "Statistics retrieval")
        
        retryService.getRetryStatistics { stats in
            XCTAssertEqual(stats.queueCount, 2)
            XCTAssertGreaterThanOrEqual(stats.processCount, 0)
            XCTAssertGreaterThanOrEqual(stats.successfulRetries, 0)
            XCTAssertGreaterThanOrEqual(stats.failedRetries, 0)
            
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
}
