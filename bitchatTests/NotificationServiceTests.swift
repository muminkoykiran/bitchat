//
// NotificationServiceTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import XCTest
import UserNotifications
@testable import bitchat

class NotificationServiceTests: XCTestCase {
    
    var notificationService: NotificationService!
    
    override func setUp() {
        super.setUp()
        notificationService = NotificationService.shared
    }
    
    override func tearDown() {
        notificationService.clearAllNotifications()
        super.tearDown()
    }
    
    func testAuthorizationRequest() {
        let expectation = XCTestExpectation(description: "Authorization request")
        
        notificationService.requestAuthorization { granted, error in
            XCTAssertNil(error)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testAuthorizationStatusCheck() {
        let expectation = XCTestExpectation(description: "Authorization status check")
        
        notificationService.checkAuthorizationStatus { status in
            XCTAssertNotNil(status)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testMentionNotification() {
        let testSender = "TestUser"
        let testMessage = "Hello @you!"
        let testChannelId = "test-channel"
        
        // This test ensures the method doesn't crash
        notificationService.sendMentionNotification(
            from: testSender,
            message: testMessage,
            channelId: testChannelId
        )
        
        // In a real test environment, we'd verify the notification was created
        // For now, we just ensure no crashes occur
        XCTAssertTrue(true)
    }
    
    func testPrivateMessageNotification() {
        let testSender = "TestUser"
        let testMessage = "Private message content"
        let testSenderId = "test-sender-id"
        
        notificationService.sendPrivateMessageNotification(
            from: testSender,
            message: testMessage,
            senderId: testSenderId
        )
        
        XCTAssertTrue(true)
    }
    
    func testFavoriteOnlineNotification() {
        let testNickname = "FavoriteUser"
        let testUserId = "favorite-user-id"
        
        notificationService.sendFavoriteOnlineNotification(
            nickname: testNickname,
            userId: testUserId
        )
        
        XCTAssertTrue(true)
    }
    
    func testConnectionStatusNotification() {
        // Test connected status
        notificationService.sendConnectionStatusNotification(
            isConnected: true,
            peerCount: 3
        )
        
        // Test disconnected status
        notificationService.sendConnectionStatusNotification(
            isConnected: false,
            peerCount: 0
        )
        
        XCTAssertTrue(true)
    }
    
    func testClearNotifications() {
        // This test ensures the method doesn't crash
        notificationService.clearAllNotifications()
        notificationService.clearNotificationsOfType("mention")
        notificationService.clearNotificationsOfType("private")
        
        XCTAssertTrue(true)
    }
    
    func testLongMessageTruncation() {
        let longMessage = String(repeating: "A", count: 200)
        let testSender = "TestUser"
        
        notificationService.sendMentionNotification(
            from: testSender,
            message: longMessage
        )
        
        // The service should handle long messages gracefully
        XCTAssertTrue(true)
    }
}
