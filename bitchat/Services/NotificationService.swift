//
// NotificationService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

class NotificationService {
    static let shared = NotificationService()
    
    // Notification queue for rate limiting
    private let notificationQueue = DispatchQueue(label: "notification.queue", qos: .userInitiated)
    private var lastNotificationTime: [String: Date] = [:]
    private let notificationThrottleInterval: TimeInterval = 5.0 // 5 seconds between similar notifications
    private let maxPendingNotifications = 10
    private var pendingNotificationIds = Set<String>()
    
    // Notification categories for user interaction
    private let messageCategory = "MESSAGE_CATEGORY"
    private let mentionCategory = "MENTION_CATEGORY"
    
    private init() {
        setupNotificationCategories()
    }
    
    private func setupNotificationCategories() {
        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY_ACTION",
            title: "Reply",
            options: [.authenticationRequired]
        )
        
        let markReadAction = UNNotificationAction(
            identifier: "MARK_READ_ACTION",
            title: "Mark as Read",
            options: []
        )
        
        let messageCategory = UNNotificationCategory(
            identifier: self.messageCategory,
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            options: [.allowInCarPlay]
        )
        
        let mentionCategory = UNNotificationCategory(
            identifier: self.mentionCategory,
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            options: [.allowInCarPlay]
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([messageCategory, mentionCategory])
    }
    
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void = { _, _ in }) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .carPlay]) { granted, error in
            DispatchQueue.main.async {
                completion(granted, error)
            }
        }
    }
    
    func checkAuthorizationStatus(completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                completion(settings.authorizationStatus)
            }
        }
    }
    
    
    private func shouldSendNotification(type: String) -> Bool {
        notificationQueue.sync {
            let now = Date()
            if let lastTime = lastNotificationTime[type],
               now.timeIntervalSince(lastTime) < notificationThrottleInterval {
                return false
            }
            lastNotificationTime[type] = now
            return pendingNotificationIds.count < maxPendingNotifications
        }
    }
    
    private func isAppInForeground() -> Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #elseif os(macOS)
        return NSApplication.shared.isActive
        #endif
    }
    
    func sendLocalNotification(title: String, body: String, identifier: String, category: String? = nil, userInfo: [AnyHashable: Any]? = nil, sound: UNNotificationSound? = .default) {
        // Check authorization status first
        checkAuthorizationStatus { status in
            guard status == .authorized else { return }
            
            // Skip if app is in foreground
            guard !self.isAppInForeground() else { return }
            
            // Apply rate limiting
            guard self.shouldSendNotification(type: category ?? "default") else { return }
            
            self.notificationQueue.async {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = sound
                
                if let category = category {
                    content.categoryIdentifier = category
                }
                
                if let userInfo = userInfo {
                    content.userInfo = userInfo
                }
                
                // Add badge increment
                #if os(iOS)
                content.badge = NSNumber(value: UIApplication.shared.applicationIconBadgeNumber + 1)
                #endif
                
                let request = UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: nil // Deliver immediately
                )
                
                // Track pending notification
                self.pendingNotificationIds.insert(identifier)
                
                UNUserNotificationCenter.current().add(request) { [weak self] error in
                    if let error = error {
                        print("Failed to send notification: \(error)")
                    }
                    // Remove from pending set
                    self?.notificationQueue.async {
                        self?.pendingNotificationIds.remove(identifier)
                    }
                }
            }
        }
    }
    
    
    func sendMentionNotification(from sender: String, message: String, channelId: String? = nil) {
        let title = "＠🫵 you were mentioned by \(sender)"
        let body = String(message.prefix(100)) // Truncate long messages
        let identifier = "mention-\(UUID().uuidString)"
        
        var userInfo: [AnyHashable: Any] = [
            "type": "mention",
            "sender": sender,
            "message": message
        ]
        
        if let channelId = channelId {
            userInfo["channelId"] = channelId
        }
        
        sendLocalNotification(
            title: title,
            body: body,
            identifier: identifier,
            category: mentionCategory,
            userInfo: userInfo,
            sound: .default
        )
    }
    
    func sendPrivateMessageNotification(from sender: String, message: String, senderId: String? = nil) {
        let title = "🔒 private message from \(sender)"
        let body = String(message.prefix(100)) // Truncate long messages
        let identifier = "private-\(UUID().uuidString)"
        
        var userInfo: [AnyHashable: Any] = [
            "type": "private",
            "sender": sender,
            "message": message
        ]
        
        if let senderId = senderId {
            userInfo["senderId"] = senderId
        }
        
        sendLocalNotification(
            title: title,
            body: body,
            identifier: identifier,
            category: messageCategory,
            userInfo: userInfo,
            sound: .default
        )
    }
    
    func sendFavoriteOnlineNotification(nickname: String, userId: String? = nil) {
        let title = "⭐ \(nickname) is online"
        let body = "wanna get in there?"
        let identifier = "favorite-online-\(UUID().uuidString)"
        
        var userInfo: [AnyHashable: Any] = [
            "type": "favorite_online",
            "nickname": nickname
        ]
        
        if let userId = userId {
            userInfo["userId"] = userId
        }
        
        sendLocalNotification(
            title: title,
            body: body,
            identifier: identifier,
            userInfo: userInfo,
            sound: UNNotificationSound(named: UNNotificationSoundName("notification_gentle.wav"))
        )
    }
    
    func sendConnectionStatusNotification(isConnected: Bool, peerCount: Int) {
        let title = isConnected ? "🌐 BitChat Network Connected" : "❌ BitChat Network Disconnected"
        let body = isConnected ? "Connected to \(peerCount) peer(s)" : "Lost connection to mesh network"
        let identifier = "connection-\(UUID().uuidString)"
        
        let userInfo: [AnyHashable: Any] = [
            "type": "connection_status",
            "isConnected": isConnected,
            "peerCount": peerCount
        ]
        
        sendLocalNotification(
            title: title,
            body: body,
            identifier: identifier,
            userInfo: userInfo,
            sound: isConnected ? .default : UNNotificationSound(named: UNNotificationSoundName("notification_alert.wav"))
        )
    }
    
    func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        
        notificationQueue.async {
            self.pendingNotificationIds.removeAll()
            self.lastNotificationTime.removeAll()
        }
        
        // Clear badge count
        #if os(iOS)
        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
        #endif
    }
    
    func clearNotificationsOfType(_ type: String) {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let identifiersToRemove = requests
                .filter { request in
                    guard let userInfo = request.content.userInfo as? [String: Any],
                          let notificationType = userInfo["type"] as? String else {
                        return false
                    }
                    return notificationType == type
                }
                .map { $0.identifier }
            
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiersToRemove)
        }
        
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let identifiersToRemove = notifications
                .filter { notification in
                    guard let userInfo = notification.request.content.userInfo as? [String: Any],
                          let notificationType = userInfo["type"] as? String else {
                        return false
                    }
                    return notificationType == type
                }
                .map { $0.request.identifier }
            
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiersToRemove)
        }
    }
}
