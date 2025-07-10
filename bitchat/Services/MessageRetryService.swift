//
// MessageRetryService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine
import CryptoKit

struct RetryableMessage {
    let id: String
    let originalMessageID: String? 
    let originalTimestamp: Date?
    let content: String
    let mentions: [String]?
    let channel: String?
    let isPrivate: Bool
    let recipientPeerID: String?
    let recipientNickname: String?
    let channelKey: Data?
    let retryCount: Int
    let maxRetries: Int
    let nextRetryTime: Date
    let priority: MessagePriority
    
    enum MessagePriority: Int, Comparable {
        case low = 1
        case normal = 2
        case high = 3
        case critical = 4
        
        static func < (lhs: MessagePriority, rhs: MessagePriority) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }
}

struct RetryConfiguration {
    let baseRetryInterval: TimeInterval
    let maxRetries: Int
    let exponentialBackoff: Bool
    let maxBackoffDelay: TimeInterval
    let maxQueueSize: Int
    
    static let `default` = RetryConfiguration(
        baseRetryInterval: 2.0,
        maxRetries: 3,
        exponentialBackoff: true,
        maxBackoffDelay: 30.0,
        maxQueueSize: 100
    )
    
    static let aggressive = RetryConfiguration(
        baseRetryInterval: 1.0,
        maxRetries: 5,
        exponentialBackoff: true,
        maxBackoffDelay: 15.0,
        maxQueueSize: 150
    )
    
    static let conservative = RetryConfiguration(
        baseRetryInterval: 5.0,
        maxRetries: 2,
        exponentialBackoff: false,
        maxBackoffDelay: 60.0,
        maxQueueSize: 50
    )
}

class MessageRetryService {
    static let shared = MessageRetryService()
    
    private let retryQueue = DispatchQueue(label: "message.retry.queue", qos: .userInitiated)
    private var _retryMessages: [RetryableMessage] = []
    private var retryTimer: Timer?
    private var configuration: RetryConfiguration = .default
    
    // Performance monitoring
    private var lastProcessTime: Date = Date()
    private var processCount: Int = 0
    private var successfulRetries: Int = 0
    private var failedRetries: Int = 0
    
    weak var meshService: BluetoothMeshService?
    
    private init() {
        setupRetryTimer()
        setupMemoryWarningObserver()
    }
    
    deinit {
        retryTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupRetryTimer() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: configuration.baseRetryInterval, repeats: true) { [weak self] _ in
            self?.processRetryQueue()
        }
    }
    
    private func setupMemoryWarningObserver() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        #endif
    }
    
    @objc private func handleMemoryWarning() {
        retryQueue.async { [weak self] in
            guard let self = self else { return }
            // Remove low priority messages when memory is low
            self._retryMessages = self._retryMessages.filter { message in
                message.priority != .low
            }
        }
    }
    
    
    func updateConfiguration(_ newConfig: RetryConfiguration) {
        retryQueue.async { [weak self] in
            self?.configuration = newConfig
            
            // Restart timer with new interval
            DispatchQueue.main.async {
                self?.retryTimer?.invalidate()
                self?.setupRetryTimer()
            }
        }
    }
    
    func addMessageForRetry(
        content: String,
        mentions: [String]? = nil,
        channel: String? = nil,
        isPrivate: Bool = false,
        recipientPeerID: String? = nil,
        recipientNickname: String? = nil,
        channelKey: Data? = nil,
        originalMessageID: String? = nil,
        originalTimestamp: Date? = nil,
        priority: RetryableMessage.MessagePriority = .normal
    ) {
        // Don't queue empty or whitespace-only messages
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        retryQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Don't queue if we're at capacity
            guard self._retryMessages.count < self.configuration.maxQueueSize else {
                return
            }
            
            // Check if this message is already in the queue
            if let messageID = originalMessageID {
                let alreadyQueued = self._retryMessages.contains { msg in
                    msg.originalMessageID == messageID
                }
                if alreadyQueued {
                    return // Don't add duplicate
                }
            }
            
            let retryMessage = RetryableMessage(
                id: UUID().uuidString,
                originalMessageID: originalMessageID,
                originalTimestamp: originalTimestamp,
                content: content,
                mentions: mentions,
                channel: channel,
                isPrivate: isPrivate,
                recipientPeerID: recipientPeerID,
                recipientNickname: recipientNickname,
                channelKey: channelKey,
                retryCount: 0,
                maxRetries: self.configuration.maxRetries,
                nextRetryTime: Date().addingTimeInterval(self.configuration.baseRetryInterval),
                priority: priority
            )
            
            self._retryMessages.append(retryMessage)
            
            // Sort the queue by priority first, then by original timestamp to maintain message order
            self._retryMessages.sort { (msg1, msg2) in
                if msg1.priority != msg2.priority {
                    return msg1.priority > msg2.priority // Higher priority first
                }
                let time1 = msg1.originalTimestamp ?? Date.distantPast
                let time2 = msg2.originalTimestamp ?? Date.distantPast
                return time1 < time2
            }
        }
    }
    
    
    private func calculateNextRetryTime(for message: RetryableMessage) -> Date {
        let baseDelay = configuration.baseRetryInterval
        
        if configuration.exponentialBackoff {
            let exponentialDelay = baseDelay * pow(2.0, Double(message.retryCount))
            let cappedDelay = min(exponentialDelay, configuration.maxBackoffDelay)
            return Date().addingTimeInterval(cappedDelay)
        } else {
            return Date().addingTimeInterval(baseDelay * Double(message.retryCount + 1))
        }
    }
    
    private func processRetryQueue() {
        guard meshService != nil else { return }
        
        retryQueue.async { [weak self] in
            guard let self = self else { return }
            
            let now = Date()
            var messagesToRetry: [RetryableMessage] = []
            var updatedQueue: [RetryableMessage] = []
            
            self.processCount += 1
            self.lastProcessTime = now
            
            for message in self._retryMessages {
                if message.nextRetryTime <= now && message.retryCount < message.maxRetries {
                    messagesToRetry.append(message)
                } else if message.retryCount < message.maxRetries {
                    updatedQueue.append(message)
                }
                // Messages that exceeded max retries are dropped
            }
            
            self._retryMessages = updatedQueue
            
            // Sort messages by priority first, then by original timestamp
            messagesToRetry.sort { (msg1, msg2) in
                if msg1.priority != msg2.priority {
                    return msg1.priority > msg2.priority
                }
                let time1 = msg1.originalTimestamp ?? Date.distantPast
                let time2 = msg2.originalTimestamp ?? Date.distantPast
                return time1 < time2
            }
            
            // Process messages on main queue
            DispatchQueue.main.async {
                self.processMessages(messagesToRetry)
            }
        }
    }
    
    private func processMessages(_ messages: [RetryableMessage]) {
        guard let meshService = meshService else { return }
        
        // Check connectivity before retrying
        let viewModel = meshService.delegate as? ChatViewModel
        let connectedPeers = viewModel?.connectedPeers ?? []
        
        // Send messages with delay to maintain order and avoid overwhelming the network
        for (index, message) in messages.enumerated() {
            let delay = Double(index) * 0.1 // 100ms between messages for better reliability
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.retryMessage(message, connectedPeers: connectedPeers, meshService: meshService)
            }
        }
    }
    
    private func retryMessage(_ message: RetryableMessage, connectedPeers: [String], meshService: BluetoothMeshService) {
        var success = false
        
        if message.isPrivate {
            // For private messages, check if recipient is connected
            if let recipientID = message.recipientPeerID,
               connectedPeers.contains(recipientID) {
                // Retry private message
                meshService.sendPrivateMessage(
                    message.content,
                    to: recipientID,
                    recipientNickname: message.recipientNickname ?? "unknown",
                    messageID: message.originalMessageID
                )
                success = true
            }
        } else if let channel = message.channel, let channelKeyData = message.channelKey {
            // For channel messages, check if we have peers in the channel
            if !connectedPeers.isEmpty {
                // Recreate SymmetricKey from data
                let channelKey = SymmetricKey(data: channelKeyData)
                meshService.sendEncryptedChannelMessage(
                    message.content,
                    mentions: message.mentions ?? [],
                    channel: channel,
                    channelKey: channelKey,
                    messageID: message.originalMessageID,
                    timestamp: message.originalTimestamp
                )
                success = true
            }
        } else {
            // Regular message
            if !connectedPeers.isEmpty {
                meshService.sendMessage(
                    message.content,
                    mentions: message.mentions ?? [],
                    channel: message.channel,
                    to: nil,
                    messageID: message.originalMessageID,
                    timestamp: message.originalTimestamp
                )
                success = true
            }
        }
        
        // Update statistics and handle retry
        if success {
            retryQueue.async { [weak self] in
                self?.successfulRetries += 1
            }
        } else {
            // Add back to queue with updated retry count and time
            retryQueue.async { [weak self] in
                guard let self = self else { return }
                
                self.failedRetries += 1
                
                let updatedMessage = RetryableMessage(
                    id: message.id,
                    originalMessageID: message.originalMessageID,
                    originalTimestamp: message.originalTimestamp,
                    content: message.content,
                    mentions: message.mentions,
                    channel: message.channel,
                    isPrivate: message.isPrivate,
                    recipientPeerID: message.recipientPeerID,
                    recipientNickname: message.recipientNickname,
                    channelKey: message.channelKey,
                    retryCount: message.retryCount + 1,
                    maxRetries: message.maxRetries,
                    nextRetryTime: self.calculateNextRetryTime(for: message),
                    priority: message.priority
                )
                
                if updatedMessage.retryCount < updatedMessage.maxRetries {
                    self._retryMessages.append(updatedMessage)
                }
            }
        }
    }
    
    
    func clearRetryQueue() {
        retryQueue.async { [weak self] in
            self?._retryMessages.removeAll()
        }
    }
    
    func clearMessagesForChannel(_ channel: String) {
        retryQueue.async { [weak self] in
            self?._retryMessages.removeAll { message in
                message.channel == channel
            }
        }
    }
    
    func clearMessagesForRecipient(_ recipientID: String) {
        retryQueue.async { [weak self] in
            self?._retryMessages.removeAll { message in
                message.recipientPeerID == recipientID
            }
        }
    }
    
    func getRetryQueueCount(completion: @escaping (Int) -> Void) {
        retryQueue.async { [weak self] in
            let count = self?._retryMessages.count ?? 0
            DispatchQueue.main.async {
                completion(count)
            }
        }
    }
    
    func getRetryStatistics(completion: @escaping (RetryStatistics) -> Void) {
        retryQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    completion(RetryStatistics())
                }
                return
            }
            
            let stats = RetryStatistics(
                queueCount: self._retryMessages.count,
                processCount: self.processCount,
                successfulRetries: self.successfulRetries,
                failedRetries: self.failedRetries,
                lastProcessTime: self.lastProcessTime
            )
            
            DispatchQueue.main.async {
                completion(stats)
            }
        }
    }
    
    func adjustRetryStrategy(basedOn networkCondition: NetworkCondition) {
        let newConfig: RetryConfiguration
        
        switch networkCondition {
        case .excellent:
            newConfig = .aggressive
        case .good:
            newConfig = .default
        case .poor:
            newConfig = .conservative
        case .disconnected:
            // Use conservative settings when disconnected
            newConfig = RetryConfiguration(
                baseRetryInterval: 10.0,
                maxRetries: 1,
                exponentialBackoff: false,
                maxBackoffDelay: 60.0,
                maxQueueSize: 25
            )
        }
        
        updateConfiguration(newConfig)
    }
}

struct RetryStatistics {
    let queueCount: Int
    let processCount: Int
    let successfulRetries: Int
    let failedRetries: Int
    let lastProcessTime: Date
    
    init(queueCount: Int = 0, processCount: Int = 0, successfulRetries: Int = 0, failedRetries: Int = 0, lastProcessTime: Date = Date()) {
        self.queueCount = queueCount
        self.processCount = processCount
        self.successfulRetries = successfulRetries
        self.failedRetries = failedRetries
        self.lastProcessTime = lastProcessTime
    }
    
    var successRate: Double {
        let total = successfulRetries + failedRetries
        return total > 0 ? Double(successfulRetries) / Double(total) : 0.0
    }
}

enum NetworkCondition {
    case excellent  // Many peers, low latency
    case good       // Some peers, normal latency  
    case poor       // Few peers, high latency
    case disconnected // No peers
}
}
