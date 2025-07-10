//
// MessageRetentionService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

// MARK: - Data Extension for SHA256
extension Data {
    var sha256: Data {
        return Data(SHA256.hash(data: self))
    }
}

struct StoredMessage: Codable {
    let id: String
    let sender: String
    let senderPeerID: String?
    let content: String
    let timestamp: Date
    let channelTag: String?
    let isPrivate: Bool
    let recipientPeerID: String?
}

class MessageRetentionService {
    static let shared = MessageRetentionService()
    
    private let documentsDirectory: URL
    private let messagesDirectory: URL
    private let favoriteChannelsKey = "bitchat.favoriteChannels"
    private let retentionDays = 7 // Messages retained for 7 days
    private let maxStoredMessages = 10000 // Maximum stored messages to prevent storage abuse
    private let encryptionKey: SymmetricKey
    
    // Thread safety
    private let fileQueue = DispatchQueue(label: "chat.bitchat.retention", attributes: .concurrent)
    private let lock = NSLock()
    
    // Performance caching
    private var cachedFavoriteChannels: Set<String>?
    private var lastFavoritesCheck: Date = Date.distantPast
    
    private init() {
        // Get documents directory
        guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Unable to access documents directory")
        }
        documentsDirectory = docsDir
        messagesDirectory = documentsDirectory.appendingPathComponent("Messages", isDirectory: true)
        
        // Create messages directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: messagesDirectory, 
                                                  withIntermediateDirectories: true, 
                                                  attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        } catch {
            // Handle directory creation failure gracefully
            print("Failed to create messages directory: \(error)")
        }
        
        // Generate or retrieve encryption key from keychain
        if let keyData = KeychainManager.shared.getIdentityKey(forKey: "messageRetentionKey") {
            encryptionKey = SymmetricKey(data: keyData)
        } else {
            // Generate new key and store it
            encryptionKey = SymmetricKey(size: .bits256)
            _ = KeychainManager.shared.saveIdentityKey(encryptionKey.withUnsafeBytes { Data($0) }, forKey: "messageRetentionKey")
        }
        
        // Clean up old messages on init (background queue)
        fileQueue.async { [weak self] in
            self?.cleanupOldMessages()
            self?.enforceStorageLimit()
        }
    }
    
    deinit {
        // Clear sensitive data
        lock.lock()
        cachedFavoriteChannels = nil
        lock.unlock()
    }
    
    // MARK: - Favorite Channels Management
    
    func getFavoriteChannels() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        
        // Use cache if available and recent
        if let cached = cachedFavoriteChannels, 
           Date().timeIntervalSince(lastFavoritesCheck) < 30 { // 30 second cache
            return cached
        }
        
        let channels = UserDefaults.standard.stringArray(forKey: favoriteChannelsKey) ?? []
        let result = Set(channels)
        
        cachedFavoriteChannels = result
        lastFavoritesCheck = Date()
        
        return result
    }
    
    func toggleFavoriteChannel(_ channel: String) -> Bool {
        // Validate channel name
        guard isValidChannelName(channel) else { return false }
        
        lock.lock()
        var favorites = getFavoriteChannels()
        let wasAdded: Bool
        
        if favorites.contains(channel) {
            favorites.remove(channel)
            wasAdded = false
            // Clean up messages for this channel (background)
            fileQueue.async { [weak self] in
                self?.deleteMessagesForChannel(channel)
            }
        } else {
            favorites.insert(channel)
            wasAdded = true
        }
        
        // Update cache and storage
        cachedFavoriteChannels = favorites
        lastFavoritesCheck = Date()
        UserDefaults.standard.set(Array(favorites), forKey: favoriteChannelsKey)
        lock.unlock()
        
        return wasAdded
    }
    
    private func isValidChannelName(_ channel: String) -> Bool {
        return !channel.isEmpty && 
               channel.count <= 100 &&
               !channel.contains("..") && // Prevent path traversal
               !channel.hasPrefix("/") &&
               !channel.hasPrefix("\\")
    }
    
    // MARK: - Message Storage
    
    func saveMessage(_ message: BitchatMessage, forChannel channel: String?) {
        // Only save messages for favorite channels
        guard let channel = channel ?? message.channel,
              getFavoriteChannels().contains(channel) else {
            return
        }
        
        // Validate message content
        guard isValidMessage(message) else { return }
        
        fileQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Convert to StoredMessage
            let storedMessage = StoredMessage(
                id: message.id,
                sender: message.sender,
                senderPeerID: message.senderPeerID,
                content: message.content,
                timestamp: message.timestamp,
                channelTag: message.channel,
                isPrivate: message.isPrivate,
                recipientPeerID: message.senderPeerID
            )
            
            // Encode message
            guard let messageData = try? JSONEncoder().encode(storedMessage) else { return }
            
            // Encrypt message
            guard let encryptedData = self.encrypt(messageData) else { return }
            
            // Save to file with secure naming
            let fileName = self.generateSecureFileName(for: channel, message: message)
            let fileURL = self.messagesDirectory.appendingPathComponent(fileName)
            
            do {
                try encryptedData.write(to: fileURL, options: [.atomic, .completeFileProtection])
            } catch {
                // Handle write failure
                print("Failed to save message: \(error)")
            }
            
            // Enforce storage limits
            self.enforceStorageLimit()
        }
    }
    
    private func isValidMessage(_ message: BitchatMessage) -> Bool {
        return !message.content.isEmpty &&
               message.content.count <= 10000 && // Reasonable message size limit
               !message.sender.isEmpty &&
               message.sender.count <= 100
    }
    
    private func generateSecureFileName(for channel: String, message: BitchatMessage) -> String {
        // Use timestamp and message ID for uniqueness, avoid exposing content
        let channelHash = channel.data(using: .utf8)?.sha256.prefix(8).map { String(format: "%02x", $0) }.joined() ?? "unknown"
        let timestamp = String(format: "%.0f", message.timestamp.timeIntervalSince1970)
        let messageIDHash = message.id.data(using: .utf8)?.sha256.prefix(8).map { String(format: "%02x", $0) }.joined() ?? "unknown"
        return "\(channelHash)_\(timestamp)_\(messageIDHash).enc"
    }
    func loadMessagesForChannel(_ channel: String) -> [BitchatMessage] {
        guard getFavoriteChannels().contains(channel) else { return [] }
        
        return fileQueue.sync {
            var messages: [BitchatMessage] = []
            
            do {
                let files = try FileManager.default.contentsOfDirectory(at: messagesDirectory, includingPropertiesForKeys: [.creationDateKey])
                let channelHash = channel.data(using: .utf8)?.sha256.prefix(8).map { String(format: "%02x", $0) }.joined() ?? "unknown"
                let channelFiles = files.filter { $0.lastPathComponent.hasPrefix("\(channelHash)_") }
                
                for fileURL in channelFiles {
                    if let encryptedData = try? Data(contentsOf: fileURL),
                       let decryptedData = decrypt(encryptedData),
                       let storedMessage = try? JSONDecoder().decode(StoredMessage.self, from: decryptedData) {
                        
                        let message = BitchatMessage(
                            sender: storedMessage.sender,
                            content: storedMessage.content,
                            timestamp: storedMessage.timestamp,
                            isRelay: false,
                            originalSender: nil,
                            isPrivate: storedMessage.isPrivate,
                            recipientNickname: nil,
                            senderPeerID: storedMessage.senderPeerID,
                            mentions: nil,
                            channel: storedMessage.channelTag
                        )
                        
                        messages.append(message)
                    }
                }
            } catch {
                print("Failed to load messages for channel \(channel): \(error)")
            }
            
            return messages.sorted { $0.timestamp < $1.timestamp }
        }
    }
    
    // MARK: - Encryption
    
    private func encrypt(_ data: Data) -> Data? {
        do {
            let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
            return sealedBox.combined
        } catch {
            return nil
        }
    }
    
    private func decrypt(_ data: Data) -> Data? {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: encryptionKey)
        } catch {
            return nil
        }
    }
    
    // MARK: - Cleanup and Maintenance
    
    private func cleanupOldMessages() {
        let cutoffDate = Date().addingTimeInterval(-TimeInterval(retentionDays * 24 * 60 * 60))
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: messagesDirectory, includingPropertiesForKeys: [.creationDateKey])
            
            for fileURL in files {
                if let attributes = try? fileURL.resourceValues(forKeys: [.creationDateKey]),
                   let creationDate = attributes.creationDate,
                   creationDate < cutoffDate {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        } catch {
            print("Failed to cleanup old messages: \(error)")
        }
    }
    
    private func enforceStorageLimit() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: messagesDirectory, includingPropertiesForKeys: [.creationDateKey])
            
            if files.count > maxStoredMessages {
                // Sort by creation date and remove oldest files
                let sortedFiles = files.sorted { file1, file2 in
                    let date1 = (try? file1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    let date2 = (try? file2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                    return date1 < date2
                }
                
                let filesToRemove = sortedFiles.prefix(files.count - maxStoredMessages)
                for fileURL in filesToRemove {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        } catch {
            print("Failed to enforce storage limit: \(error)")
        }
    }
    
    func deleteMessagesForChannel(_ channel: String) {
        fileQueue.async { [weak self] in
            guard let self = self else { return }
            
            do {
                let files = try FileManager.default.contentsOfDirectory(at: self.messagesDirectory, includingPropertiesForKeys: nil)
                let channelHash = channel.data(using: .utf8)?.sha256.prefix(8).map { String(format: "%02x", $0) }.joined() ?? "unknown"
                let channelFiles = files.filter { $0.lastPathComponent.hasPrefix("\(channelHash)_") }
                
                for fileURL in channelFiles {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                print("Failed to delete messages for channel \(channel): \(error)")
            }
        }
    }
    
    func deleteAllStoredMessages() {
        fileQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            do {
                let files = try FileManager.default.contentsOfDirectory(at: self.messagesDirectory, includingPropertiesForKeys: nil)
                for fileURL in files {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                print("Failed to delete all stored messages: \(error)")
            }
            
            // Clear favorite channels and cache
            self.lock.lock()
            self.cachedFavoriteChannels = nil
            UserDefaults.standard.removeObject(forKey: self.favoriteChannelsKey)
            self.lock.unlock()
        }
    }
    
    // MARK: - Storage Statistics
    
    func getStorageStatistics() -> (totalMessages: Int, totalSize: Int64, oldestMessage: Date?) {
        return fileQueue.sync {
            do {
                let files = try FileManager.default.contentsOfDirectory(at: messagesDirectory, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])
                
                let totalSize = files.compactMap { file in
                    try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
                }.reduce(0, +)
                
                let oldestDate = files.compactMap { file in
                    try? file.resourceValues(forKeys: [.creationDateKey]).creationDate
                }.min()
                
                return (files.count, Int64(totalSize), oldestDate)
            } catch {
                return (0, 0, nil)
            }
        }
    }
}
