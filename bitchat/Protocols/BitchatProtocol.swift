//
// BitchatProtocol.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

// Privacy-preserving padding utilities with enhanced security
struct MessagePadding {
    // Standard block sizes for padding
    static let blockSizes = [256, 512, 1024, 2048, 4096]
    
    // Secure random number generator
    private static let secureRandom = SystemRandomNumberGenerator()
    
    // Add cryptographically secure padding to reach target size
    static func pad(_ data: Data, toSize targetSize: Int) -> Result<Data, PaddingError> {
        guard !data.isEmpty else {
            return .failure(.emptyData)
        }
        
        guard data.count < targetSize else {
            return .success(data) // No padding needed
        }
        
        let paddingNeeded = targetSize - data.count
        
        // Validate padding requirements
        guard paddingNeeded > 0 && paddingNeeded <= 4096 else {
            return .failure(.invalidPaddingSize(requested: paddingNeeded))
        }
        
        var padded = data
        
        // Generate cryptographically secure random padding
        if paddingNeeded > 1 {
            var randomBytes = Data(count: paddingNeeded - 1)
            let result = randomBytes.withUnsafeMutableBytes { ptr in
                SecRandomCopyBytes(kSecRandomDefault, paddingNeeded - 1, ptr.bindMemory(to: UInt8.self).baseAddress!)
            }
            
            guard result == errSecSuccess else {
                return .failure(.randomGenerationFailed)
            }
            
            padded.append(randomBytes)
        }
        
        // Add padding length as last byte
        padded.append(UInt8(paddingNeeded))
        
        return .success(padded)
    }
    
    // Remove padding from data with validation
    static func unpad(_ data: Data) -> Result<Data, PaddingError> {
        guard !data.isEmpty else {
            return .failure(.emptyData)
        }
        
        // Last byte tells us how much padding to remove
        let paddingLength = Int(data[data.count - 1])
        
        // Validate padding length
        guard paddingLength > 0 && paddingLength <= data.count else {
            return .failure(.invalidPaddingLength(found: paddingLength, dataSize: data.count))
        }
        
        let unpaddedData = data.prefix(data.count - paddingLength)
        
        // Verify we have meaningful data after unpadding
        guard !unpaddedData.isEmpty else {
            return .failure(.nothingLeftAfterUnpadding)
        }
        
        return .success(unpaddedData)
    }
    
    // Find optimal block size for data with security considerations
    static func optimalBlockSize(for dataSize: Int, securityLevel: SecurityLevel = .standard) -> Int {
        // Account for encryption overhead (~28 bytes for AES-GCM tag + nonce)
        let encryptionOverhead = 28
        let totalSize = dataSize + encryptionOverhead
        
        // Apply security level multiplier
        let blockSizes = getBlockSizes(for: securityLevel)
        
        // Find smallest block that fits
        for blockSize in blockSizes {
            if totalSize <= blockSize {
                return blockSize
            }
        }
        
        // For very large messages, round up to nearest power of 2
        var nextPowerOf2 = 1
        while nextPowerOf2 < totalSize {
            nextPowerOf2 *= 2
        }
        
        return min(nextPowerOf2, 65536) // Cap at 64KB
    }
    
    private static func getBlockSizes(for securityLevel: SecurityLevel) -> [Int] {
        switch securityLevel {
        case .minimal:
            return [256, 512, 1024]
        case .standard:
            return blockSizes
        case .enhanced:
            return [512, 1024, 2048, 4096, 8192]
        case .maximum:
            return [1024, 2048, 4096, 8192, 16384]
        }
    }
}

// MARK: - Error Types

enum PaddingError: Error, LocalizedError {
    case emptyData
    case invalidPaddingSize(requested: Int)
    case randomGenerationFailed
    case invalidPaddingLength(found: Int, dataSize: Int)
    case nothingLeftAfterUnpadding
    
    var errorDescription: String? {
        switch self {
        case .emptyData:
            return "Cannot pad empty data"
        case .invalidPaddingSize(let requested):
            return "Invalid padding size requested: \(requested)"
        case .randomGenerationFailed:
            return "Failed to generate secure random padding"
        case .invalidPaddingLength(let found, let dataSize):
            return "Invalid padding length \(found) for data size \(dataSize)"
        case .nothingLeftAfterUnpadding:
            return "No data remaining after removing padding"
        }
    }
}

enum SecurityLevel: Int, CaseIterable {
    case minimal = 1    // Fastest, least secure
    case standard = 2   // Balanced
    case enhanced = 3   // More secure, slower
    case maximum = 4    // Most secure, slowest
    
    var description: String {
        switch self {
        case .minimal:
            return "Minimal Security"
        case .standard:
            return "Standard Security"
        case .enhanced:
            return "Enhanced Security"
        case .maximum:
            return "Maximum Security"
        }
    }
}
}

enum MessageType: UInt8, CaseIterable {
    case announce = 0x01
    case keyExchange = 0x02
    case leave = 0x03
    case message = 0x04  // All user messages (private and broadcast)
    case fragmentStart = 0x05
    case fragmentContinue = 0x06
    case fragmentEnd = 0x07
    case channelAnnounce = 0x08  // Announce password-protected channel status
    case channelRetention = 0x09  // Announce channel retention status
    case deliveryAck = 0x0A  // Acknowledge message received
    case deliveryStatusRequest = 0x0B  // Request delivery status update
    case readReceipt = 0x0C  // Message has been read/viewed
    case heartbeat = 0x0D    // Keep-alive message
    case peerInfo = 0x0E     // Peer capability information
    case error = 0xFF        // Error message
    
    var description: String {
        switch self {
        case .announce: return "Announce"
        case .keyExchange: return "Key Exchange"
        case .leave: return "Leave"
        case .message: return "Message"
        case .fragmentStart: return "Fragment Start"
        case .fragmentContinue: return "Fragment Continue"
        case .fragmentEnd: return "Fragment End"
        case .channelAnnounce: return "Channel Announce"
        case .channelRetention: return "Channel Retention"
        case .deliveryAck: return "Delivery ACK"
        case .deliveryStatusRequest: return "Delivery Status Request"
        case .readReceipt: return "Read Receipt"
        case .heartbeat: return "Heartbeat"
        case .peerInfo: return "Peer Info"
        case .error: return "Error"
        }
    }
    
    var requiresEncryption: Bool {
        switch self {
        case .message, .deliveryAck, .readReceipt:
            return true
        default:
            return false
        }
    }
    
    var requiresSignature: Bool {
        switch self {
        case .keyExchange, .channelAnnounce, .announce:
            return true
        default:
            return false
        }
    }
}

// Special recipient ID for broadcast messages
struct SpecialRecipients {
    static let broadcast = Data(repeating: 0xFF, count: 8)  // All 0xFF = broadcast
}

struct BitchatPacket: Codable {
    let version: UInt8
    let type: UInt8
    let senderID: Data
    let recipientID: Data?
    let timestamp: UInt64
    let payload: Data
    let signature: Data?
    var ttl: UInt8
    
    init(type: UInt8, senderID: Data, recipientID: Data?, timestamp: UInt64, payload: Data, signature: Data?, ttl: UInt8) {
        self.version = 1
        self.type = type
        self.senderID = senderID
        self.recipientID = recipientID
        self.timestamp = timestamp
        self.payload = payload
        self.signature = signature
        self.ttl = ttl
    }
    
    // Convenience initializer for new binary format
    init(type: UInt8, ttl: UInt8, senderID: String, payload: Data) {
        self.version = 1
        self.type = type
        self.senderID = senderID.data(using: .utf8)!
        self.recipientID = nil
        self.timestamp = UInt64(Date().timeIntervalSince1970 * 1000) // milliseconds
        self.payload = payload
        self.signature = nil
        self.ttl = ttl
    }
    
    var data: Data? {
        BinaryProtocol.encode(self)
    }
    
    func toBinaryData() -> Data? {
        BinaryProtocol.encode(self)
    }
    
    static func from(_ data: Data) -> BitchatPacket? {
        BinaryProtocol.decode(data)
    }
}

// Delivery acknowledgment structure
struct DeliveryAck: Codable {
    let originalMessageID: String
    let ackID: String
    let recipientID: String  // Who received it
    let recipientNickname: String
    let timestamp: Date
    let hopCount: UInt8  // How many hops to reach recipient
    
    init(originalMessageID: String, recipientID: String, recipientNickname: String, hopCount: UInt8) {
        self.originalMessageID = originalMessageID
        self.ackID = UUID().uuidString
        self.recipientID = recipientID
        self.recipientNickname = recipientNickname
        self.timestamp = Date()
        self.hopCount = hopCount
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> DeliveryAck? {
        try? JSONDecoder().decode(DeliveryAck.self, from: data)
    }
}

// Read receipt structure
struct ReadReceipt: Codable {
    let originalMessageID: String
    let receiptID: String
    let readerID: String  // Who read it
    let readerNickname: String
    let timestamp: Date
    
    init(originalMessageID: String, readerID: String, readerNickname: String) {
        self.originalMessageID = originalMessageID
        self.receiptID = UUID().uuidString
        self.readerID = readerID
        self.readerNickname = readerNickname
        self.timestamp = Date()
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> ReadReceipt? {
        try? JSONDecoder().decode(ReadReceipt.self, from: data)
    }
}

// Delivery status for messages
enum DeliveryStatus: Codable, Equatable {
    case sending
    case sent  // Left our device
    case delivered(to: String, at: Date)  // Confirmed by recipient
    case read(by: String, at: Date)  // Seen by recipient
    case failed(reason: String)
    case partiallyDelivered(reached: Int, total: Int)  // For rooms
    
    var displayText: String {
        switch self {
        case .sending:
            return "Sending..."
        case .sent:
            return "Sent"
        case .delivered(let nickname, _):
            return "Delivered to \(nickname)"
        case .read(let nickname, _):
            return "Read by \(nickname)"
        case .failed(let reason):
            return "Failed: \(reason)"
        case .partiallyDelivered(let reached, let total):
            return "Delivered to \(reached)/\(total)"
        }
    }
}

struct BitchatMessage: Codable, Equatable {
    let id: String
    let sender: String
    let content: String
    let timestamp: Date
    let isRelay: Bool
    let originalSender: String?
    let isPrivate: Bool
    let recipientNickname: String?
    let senderPeerID: String?
    let mentions: [String]?  // Array of mentioned nicknames
    let channel: String?  // Channel hashtag (e.g., "#general")
    let encryptedContent: Data?  // For password-protected rooms
    let isEncrypted: Bool  // Flag to indicate if content is encrypted
    var deliveryStatus: DeliveryStatus? // Delivery tracking
    
    init(id: String? = nil, sender: String, content: String, timestamp: Date, isRelay: Bool, originalSender: String? = nil, isPrivate: Bool = false, recipientNickname: String? = nil, senderPeerID: String? = nil, mentions: [String]? = nil, channel: String? = nil, encryptedContent: Data? = nil, isEncrypted: Bool = false, deliveryStatus: DeliveryStatus? = nil) {
        self.id = id ?? UUID().uuidString
        self.sender = sender
        self.content = content
        self.timestamp = timestamp
        self.isRelay = isRelay
        self.originalSender = originalSender
        self.isPrivate = isPrivate
        self.recipientNickname = recipientNickname
        self.senderPeerID = senderPeerID
        self.mentions = mentions
        self.channel = channel
        self.encryptedContent = encryptedContent
        self.isEncrypted = isEncrypted
        self.deliveryStatus = deliveryStatus ?? (isPrivate ? .sending : nil)
    }
}

protocol BitchatDelegate: AnyObject {
    func didReceiveMessage(_ message: BitchatMessage)
    func didConnectToPeer(_ peerID: String)
    func didDisconnectFromPeer(_ peerID: String)
    func didUpdatePeerList(_ peers: [String])
    func didReceiveChannelLeave(_ channel: String, from peerID: String)
    func didReceivePasswordProtectedChannelAnnouncement(_ channel: String, isProtected: Bool, creatorID: String?, keyCommitment: String?)
    func didReceiveChannelRetentionAnnouncement(_ channel: String, enabled: Bool, creatorID: String?)
    func decryptChannelMessage(_ encryptedContent: Data, channel: String) -> String?
    
    // Optional method to check if a fingerprint belongs to a favorite peer
    func isFavorite(fingerprint: String) -> Bool
    
    // Delivery confirmation methods
    func didReceiveDeliveryAck(_ ack: DeliveryAck)
    func didReceiveReadReceipt(_ receipt: ReadReceipt)
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus)
}

// Provide default implementation to make it effectively optional
extension BitchatDelegate {
    func isFavorite(fingerprint: String) -> Bool {
        return false
    }
    
    func didReceiveChannelLeave(_ channel: String, from peerID: String) {
        // Default empty implementation
    }
    
    func didReceivePasswordProtectedChannelAnnouncement(_ channel: String, isProtected: Bool, creatorID: String?, keyCommitment: String?) {
        // Default empty implementation
    }
    
    func didReceiveChannelRetentionAnnouncement(_ channel: String, enabled: Bool, creatorID: String?) {
        // Default empty implementation
    }
    
    func decryptChannelMessage(_ encryptedContent: Data, channel: String) -> String? {
        // Default returns nil (unable to decrypt)
        return nil
    }
    
    func didReceiveDeliveryAck(_ ack: DeliveryAck) {
        // Default empty implementation
    }
    
    func didReceiveReadReceipt(_ receipt: ReadReceipt) {
        // Default empty implementation
    }
    
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        // Default empty implementation
    }
}