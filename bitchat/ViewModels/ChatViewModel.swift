//
// ChatViewModel.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import SwiftUI
import Combine
import CryptoKit
import CommonCrypto
#if os(iOS)
import UIKit
#endif

class ChatViewModel: ObservableObject, BitchatDelegate {
    @Published var messages: [BitchatMessage] = []
    @Published var connectedPeers: [String] = []
    @Published var nickname: String = "" {
        didSet {
            nicknameSaveTimer?.invalidate()
            nicknameSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.saveNickname()
            }
        }
    }
    @Published var isConnected = false
    @Published var privateChats: [String: [BitchatMessage]] = [:] // peerID -> messages
    @Published var selectedPrivateChatPeer: String? = nil
    @Published var unreadPrivateMessages: Set<String> = []
    @Published var autocompleteSuggestions: [String] = []
    @Published var showAutocomplete: Bool = false
    @Published var autocompleteRange: NSRange? = nil
    @Published var selectedAutocompleteIndex: Int = 0
    
    // Channel support
    @Published var joinedChannels: Set<String> = []  // Set of channel hashtags
    @Published var currentChannel: String? = nil  // Currently selected channel
    @Published var channelMessages: [String: [BitchatMessage]] = [:]  // channel -> messages
    @Published var unreadChannelMessages: [String: Int] = [:]  // channel -> unread count
    @Published var channelMembers: [String: Set<String>] = [:]  // channel -> set of peer IDs who have sent messages
    @Published var channelPasswords: [String: String] = [:]  // channel -> password (stored locally only)
    @Published var channelKeys: [String: SymmetricKey] = [:]  // channel -> derived encryption key
    @Published var passwordProtectedChannels: Set<String> = []  // Set of channels that require passwords
    @Published var channelCreators: [String: String] = [:]  // channel -> creator peerID
    @Published var channelKeyCommitments: [String: String] = [:]  // channel -> SHA256(derivedKey) for verification
    @Published var showPasswordPrompt: Bool = false
    @Published var passwordPromptChannel: String? = nil
    @Published var savedChannels: Set<String> = []  // Channels saved for message retention
    @Published var retentionEnabledChannels: Set<String> = []  // Channels where owner enabled retention for all members
    
    let meshService = BluetoothMeshService()
    private let userDefaults = UserDefaults.standard
    private let nicknameKey = "bitchat.nickname"
    private let favoritesKey = "bitchat.favorites"
    private let joinedChannelsKey = "bitchat.joinedChannels"
    private let passwordProtectedChannelsKey = "bitchat.passwordProtectedChannels"
    private let channelCreatorsKey = "bitchat.channelCreators"
    // private let channelPasswordsKey = "bitchat.channelPasswords" // Now using Keychain
    private let channelKeyCommitmentsKey = "bitchat.channelKeyCommitments"
    private let retentionEnabledChannelsKey = "bitchat.retentionEnabledChannels"
    private let blockedUsersKey = "bitchat.blockedUsers"
    private var nicknameSaveTimer: Timer?
    
    @Published var favoritePeers: Set<String> = []  // Now stores public key fingerprints instead of peer IDs
    private var peerIDToPublicKeyFingerprint: [String: String] = [:]  // Maps ephemeral peer IDs to persistent fingerprints
    private var blockedUsers: Set<String> = []  // Stores public key fingerprints of blocked users
    
    // Performance optimization properties
    private let maxMessagesPerChannel = 500 // Limit messages in memory per channel
    private let maxPrivateMessages = 200 // Limit private messages in memory per peer
    private let messageCleanupInterval: TimeInterval = 300 // 5 minutes
    private var messageCleanupTimer: Timer?
    
    // Thread safety
    private let messageQueue = DispatchQueue(label: "chat.bitchat.messages", attributes: .concurrent)
    private let channelQueue = DispatchQueue(label: "chat.bitchat.channels", attributes: .concurrent)
    
    // Messages are naturally ephemeral - no persistent storage
    
    // Delivery tracking
    private var deliveryTrackerCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        loadNickname()
        loadFavorites()
        loadJoinedChannels()
        loadChannelData()
        loadBlockedUsers()
        // Load saved channels state
        savedChannels = MessageRetentionService.shared.getFavoriteChannels()
        meshService.delegate = self
        
        // Log startup info
        
        // Start mesh service immediately
        meshService.startServices()
        
        // Set up message retry service
        MessageRetryService.shared.meshService = meshService
        
        // Request notification permission
        NotificationService.shared.requestAuthorization()
        
        // Subscribe to delivery status updates
        deliveryTrackerCancellable = DeliveryTracker.shared.deliveryStatusUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (messageID, status) in
                self?.updateMessageDeliveryStatus(messageID: messageID, status: status)
            }
            .store(in: &cancellables)
        
        // Start periodic message cleanup
        startMessageCleanupTimer()
        
        // Show welcome message after delay if still no peers
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if self.connectedPeers.isEmpty && self.messages.isEmpty {
                let welcomeMessage = BitchatMessage(
                    sender: "system",
                    content: "get people around you to download bitchat…and chat with them here!",
                    timestamp: Date(),
                    isRelay: false
                )
                self.messages.append(welcomeMessage)
            }
        }
        
        // When app becomes active, send read receipts for visible messages
        #if os(macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        #else
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // Add screenshot detection for iOS
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDidTakeScreenshot),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )
        #endif
    }
    
    deinit {
        // Clean up timers and subscriptions
        nicknameSaveTimer?.invalidate()
        messageCleanupTimer?.invalidate()
        deliveryTrackerCancellable?.cancel()
        cancellables.removeAll()
    }
    
    // MARK: - Memory Management
    
    private func startMessageCleanupTimer() {
        messageCleanupTimer = Timer.scheduledTimer(withTimeInterval: messageCleanupInterval, repeats: true) { [weak self] _ in
            self?.cleanupOldMessages()
        }
    }
    
    private func cleanupOldMessages() {
        messageQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                // Clean up channel messages
                for (channel, messages) in self.channelMessages {
                    if messages.count > self.maxMessagesPerChannel {
                        let sortedMessages = messages.sorted { $0.timestamp > $1.timestamp }
                        self.channelMessages[channel] = Array(sortedMessages.prefix(self.maxMessagesPerChannel))
                    }
                }
                
                // Clean up private messages
                for (peerID, messages) in self.privateChats {
                    if messages.count > self.maxPrivateMessages {
                        let sortedMessages = messages.sorted { $0.timestamp > $1.timestamp }
                        self.privateChats[peerID] = Array(sortedMessages.prefix(self.maxPrivateMessages))
                    }
                }
                
                // Clean up main messages (general channel)
                if self.messages.count > self.maxMessagesPerChannel {
                    let sortedMessages = self.messages.sorted { $0.timestamp > $1.timestamp }
                    self.messages = Array(sortedMessages.prefix(self.maxMessagesPerChannel))
                }
            }
        }
    }
    
    private func loadNickname() {
        if let savedNickname = userDefaults.string(forKey: nicknameKey) {
            nickname = savedNickname
        } else {
            nickname = "anon\(Int.random(in: 1000...9999))"
            saveNickname()
        }
    }
    
    func saveNickname() {
        userDefaults.set(nickname, forKey: nicknameKey)
        userDefaults.synchronize() // Force immediate save
        
        // Send announce with new nickname to all peers
        meshService.sendBroadcastAnnounce()
    }
    
    private func loadFavorites() {
        if let savedFavorites = userDefaults.stringArray(forKey: favoritesKey) {
            favoritePeers = Set(savedFavorites)
        }
    }
    
    private func saveFavorites() {
        userDefaults.set(Array(favoritePeers), forKey: favoritesKey)
        userDefaults.synchronize()
    }
    
    private func loadBlockedUsers() {
        if let savedBlockedUsers = userDefaults.stringArray(forKey: blockedUsersKey) {
            blockedUsers = Set(savedBlockedUsers)
        }
    }
    
    private func saveBlockedUsers() {
        userDefaults.set(Array(blockedUsers), forKey: blockedUsersKey)
        userDefaults.synchronize()
    }
    
    private func loadJoinedChannels() {
        if let savedChannelsList = userDefaults.stringArray(forKey: joinedChannelsKey) {
            joinedChannels = Set(savedChannelsList)
            // Initialize empty data structures for joined channels
            for channel in joinedChannels {
                if channelMessages[channel] == nil {
                    channelMessages[channel] = []
                }
                if channelMembers[channel] == nil {
                    channelMembers[channel] = Set()
                }
                
                // Load saved messages if this channel has retention enabled
                if retentionEnabledChannels.contains(channel) {
                    let savedMessages = MessageRetentionService.shared.loadMessagesForChannel(channel)
                    if !savedMessages.isEmpty {
                        channelMessages[channel] = savedMessages
                    }
                }
            }
        }
    }
    
    private func saveJoinedChannels() {
        userDefaults.set(Array(joinedChannels), forKey: joinedChannelsKey)
        userDefaults.synchronize()
    }
    
    private func loadChannelData() {
        // Load password protected channels
        if let savedProtectedChannels = userDefaults.stringArray(forKey: passwordProtectedChannelsKey) {
            passwordProtectedChannels = Set(savedProtectedChannels)
        }
        
        // Load channel creators
        if let savedCreators = userDefaults.dictionary(forKey: channelCreatorsKey) as? [String: String] {
            channelCreators = savedCreators
        }
        
        // Load channel key commitments
        if let savedCommitments = userDefaults.dictionary(forKey: channelKeyCommitmentsKey) as? [String: String] {
            channelKeyCommitments = savedCommitments
        }
        
        // Load retention-enabled channels
        if let savedRetentionChannels = userDefaults.stringArray(forKey: retentionEnabledChannelsKey) {
            retentionEnabledChannels = Set(savedRetentionChannels)
        }
        
        // Load channel passwords from Keychain
        let savedPasswords = KeychainManager.shared.getAllChannelPasswords()
        channelPasswords = savedPasswords
        // Derive keys for all saved passwords
        for (channel, password) in savedPasswords {
            channelKeys[channel] = deriveChannelKey(from: password, channelName: channel)
        }
    }
    
    private func saveChannelData() {
        userDefaults.set(Array(passwordProtectedChannels), forKey: passwordProtectedChannelsKey)
        userDefaults.set(channelCreators, forKey: channelCreatorsKey)
        // Save passwords to Keychain instead of UserDefaults
        for (channel, password) in channelPasswords {
            _ = KeychainManager.shared.saveChannelPassword(password, for: channel)
        }
        userDefaults.set(channelKeyCommitments, forKey: channelKeyCommitmentsKey)
        userDefaults.set(Array(retentionEnabledChannels), forKey: retentionEnabledChannelsKey)
        userDefaults.synchronize()
    }
    
    func joinChannel(_ channel: String, password: String? = nil) -> Bool {
        // Ensure channel starts with #
        let channelTag = channel.hasPrefix("#") ? channel : "#\(channel)"
        
        
        // Check if channel is already joined and we can access it
        if joinedChannels.contains(channelTag) {
            // Already joined, check if we need password verification
            if passwordProtectedChannels.contains(channelTag) && channelKeys[channelTag] == nil {
                if let password = password {
                    // User provided password for already-joined channel - verify it
                    
                    // Derive key and try to verify
                    let key = deriveChannelKey(from: password, channelName: channelTag)
                    
                    // First, check if we have a key commitment to verify against
                    if let expectedCommitment = channelKeyCommitments[channelTag] {
                        let actualCommitment = computeKeyCommitment(for: key)
                        if actualCommitment != expectedCommitment {
                            return false
                        }
                    }
                    
                    // Check if we have messages to verify against
                    if let channelMsgs = channelMessages[channelTag], !channelMsgs.isEmpty {
                        let encryptedMessages = channelMsgs.filter { $0.isEncrypted && $0.encryptedContent != nil }
                        if let encryptedMsg = encryptedMessages.first,
                           let encryptedData = encryptedMsg.encryptedContent {
                            let testDecrypted = decryptChannelMessage(encryptedData, channel: channelTag, testKey: key)
                            if testDecrypted == nil {
                                return false
                            }
                        }
                    }
                    
                    // Store the verified key
                    channelKeys[channelTag] = key
                    channelPasswords[channelTag] = password
                    
                    // Now switch to the channel
                    switchToChannel(channelTag)
                    return true
                } else {
                    // Need password to access
                    passwordPromptChannel = channelTag
                    showPasswordPrompt = true
                    return false
                }
            }
            // Switch to the channel (no password needed)
            switchToChannel(channelTag)
            return true
        }
        
        // If channel is password protected and we don't have the key yet
        if passwordProtectedChannels.contains(channelTag) && channelKeys[channelTag] == nil {
            // Allow channel creator to bypass password check
            if channelCreators[channelTag] == meshService.myPeerID {
                // Channel creator should already have the key set when they created the password
                // This is a failsafe - just proceed without password
            } else if let password = password {
                // Derive key from password
                let key = deriveChannelKey(from: password, channelName: channelTag)
                
                // First, check if we have a key commitment to verify against
                if let expectedCommitment = channelKeyCommitments[channelTag] {
                    let actualCommitment = computeKeyCommitment(for: key)
                    if actualCommitment != expectedCommitment {
                        return false
                    }
                }
                
                // Try to verify password if there are existing encrypted messages
                var passwordVerified = false
                var shouldProceed = true
                
                if let channelMsgs = channelMessages[channelTag], !channelMsgs.isEmpty {
                    // Look for encrypted messages to verify against
                    let encryptedMessages = channelMsgs.filter { $0.isEncrypted && $0.encryptedContent != nil }
                    
                    if let encryptedMsg = encryptedMessages.first,
                       let encryptedData = encryptedMsg.encryptedContent {
                        // Test decryption with the derived key
                        let testDecrypted = decryptChannelMessage(encryptedData, channel: channelTag, testKey: key)
                        if testDecrypted == nil {
                            // Password is wrong, can't decrypt
                            shouldProceed = false
                        } else {
                            passwordVerified = true
                        }
                    } else {
                        // No encrypted messages yet - accept tentatively
                        
                        // Add warning message
                        let warningMsg = BitchatMessage(
                            sender: "system",
                            content: "joined channel \(channelTag). password will be verified when encrypted messages arrive.",
                            timestamp: Date(),
                            isRelay: false
                        )
                        messages.append(warningMsg)
                    }
                } else {
                    // Empty channel - accept tentatively
                    
                    // Add info message
                    let infoMsg = BitchatMessage(
                        sender: "system",
                        content: "joined empty channel \(channelTag). waiting for encrypted messages to verify password.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(infoMsg)
                }
                
                // Only proceed if password verification didn't fail
                if !shouldProceed {
                    return false
                }
                
                // Store the key (tentatively if not verified)
                channelKeys[channelTag] = key
                channelPasswords[channelTag] = password
                // Save password to Keychain
                _ = KeychainManager.shared.saveChannelPassword(password, for: channelTag)
                
                if passwordVerified {
                } else {
                }
            } else {
                // Show password prompt and return early - don't join the channel yet
                passwordPromptChannel = channelTag
                showPasswordPrompt = true
                return false
            }
        }
        
        // At this point, channel is either not password protected or we don't know yet
        
        joinedChannels.insert(channelTag)
        saveJoinedChannels()
        
        // Only claim creator role if this is a brand new channel (no one has announced it as protected)
        // If it's password protected, someone else already created it
        if channelCreators[channelTag] == nil && !passwordProtectedChannels.contains(channelTag) {
            channelCreators[channelTag] = meshService.myPeerID
            saveChannelData()
        }
        
        // Add ourselves as a member
        if channelMembers[channelTag] == nil {
            channelMembers[channelTag] = Set()
        }
        channelMembers[channelTag]?.insert(meshService.myPeerID)
        
        // Switch to the channel
        currentChannel = channelTag
        selectedPrivateChatPeer = nil  // Exit private chat if in one
        
        // Clear unread count for this channel
        unreadChannelMessages[channelTag] = 0
        
        // Initialize channel messages if needed
        if channelMessages[channelTag] == nil {
            channelMessages[channelTag] = []
        }
        
        // Load saved messages if this is a favorite channel
        if MessageRetentionService.shared.getFavoriteChannels().contains(channelTag) {
            let savedMessages = MessageRetentionService.shared.loadMessagesForChannel(channelTag)
            if !savedMessages.isEmpty {
                // Merge saved messages with current messages, avoiding duplicates
                var existingMessageIDs = Set(channelMessages[channelTag]?.map { $0.id } ?? [])
                for savedMessage in savedMessages {
                    if !existingMessageIDs.contains(savedMessage.id) {
                        channelMessages[channelTag]?.append(savedMessage)
                        existingMessageIDs.insert(savedMessage.id)
                    }
                }
                // Sort by timestamp
                channelMessages[channelTag]?.sort { $0.timestamp < $1.timestamp }
            }
        }
        
        // Hide password prompt if it was showing
        showPasswordPrompt = false
        passwordPromptChannel = nil
        
        return true
    }
    
    func leaveChannel(_ channel: String) {
        joinedChannels.remove(channel)
        saveJoinedChannels()
        
        // Send leave notification to other peers
        meshService.sendChannelLeaveNotification(channel)
        
        // If we're currently in this channel, exit to main chat
        if currentChannel == channel {
            currentChannel = nil
        }
        
        // Clean up channel data
        unreadChannelMessages.removeValue(forKey: channel)
        channelMessages.removeValue(forKey: channel)
        channelMembers.removeValue(forKey: channel)
        channelKeys.removeValue(forKey: channel)
        channelPasswords.removeValue(forKey: channel)
        // Delete password from Keychain
        _ = KeychainManager.shared.deleteChannelPassword(for: channel)
    }
    
    // Password management
    func setChannelPassword(_ password: String, for channel: String) {
        guard joinedChannels.contains(channel) else { return }
        
        // Check if channel already has a creator
        if let existingCreator = channelCreators[channel], existingCreator != meshService.myPeerID {
            return
        }
        
        // If channel is already password protected by someone else, we can't claim it
        if passwordProtectedChannels.contains(channel) && channelCreators[channel] != meshService.myPeerID {
            return
        }
        
        // Claim creator role if not set and channel is not already protected
        if channelCreators[channel] == nil && !passwordProtectedChannels.contains(channel) {
            channelCreators[channel] = meshService.myPeerID
            saveChannelData()
        }
        
        // Derive encryption key from password
        let key = deriveChannelKey(from: password, channelName: channel)
        channelKeys[channel] = key
        channelPasswords[channel] = password
        passwordProtectedChannels.insert(channel)
        // Save password to Keychain
        _ = KeychainManager.shared.saveChannelPassword(password, for: channel)
        
        // Compute and store key commitment for verification
        let commitment = computeKeyCommitment(for: key)
        channelKeyCommitments[channel] = commitment
        
        // Save channel data
        saveChannelData()
        
        // Announce that this channel is now password protected with commitment
        meshService.announcePasswordProtectedChannel(channel, creatorID: meshService.myPeerID, keyCommitment: commitment)
        
        // Send an encrypted initialization message with metadata
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let metadata = [
            "type": "channel_init",
            "channel": channel,
            "creator": nickname,
            "creatorID": meshService.myPeerID,
            "timestamp": timestamp,
            "version": "1.0"
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: metadata)
        let metadataStr = jsonData?.base64EncodedString() ?? ""
        
        let initMessage = "🔐 Channel \(channel) initialized | Protected channel created by \(nickname) | Metadata: \(metadataStr)"
        meshService.sendEncryptedChannelMessage(initMessage, mentions: [], channel: channel, channelKey: key)
        
    }
    
    func removeChannelPassword(for channel: String) {
        // Only channel creator can remove password
        guard channelCreators[channel] == meshService.myPeerID else {
            return
        }
        
        channelKeys.removeValue(forKey: channel)
        channelPasswords.removeValue(forKey: channel)
        channelKeyCommitments.removeValue(forKey: channel)
        passwordProtectedChannels.remove(channel)
        // Delete password from Keychain
        _ = KeychainManager.shared.deleteChannelPassword(for: channel)
        
        // Save channel data
        saveChannelData()
        
        // Announce that this channel is no longer password protected
        meshService.announcePasswordProtectedChannel(channel, isProtected: false, creatorID: meshService.myPeerID)
        
    }
    
    // Transfer channel ownership to another user
    func transferChannelOwnership(to nickname: String) {
        guard let currentChannel = currentChannel else {
            let msg = BitchatMessage(
                sender: "system",
                content: "you must be in a channel to transfer ownership.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Check if current user is the owner
        guard channelCreators[currentChannel] == meshService.myPeerID else {
            let msg = BitchatMessage(
                sender: "system",
                content: "only the channel owner can transfer ownership.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Remove @ prefix if present
        let targetNick = nickname.hasPrefix("@") ? String(nickname.dropFirst()) : nickname
        
        // Find peer ID for the nickname
        guard let targetPeerID = getPeerIDForNickname(targetNick) else {
            let msg = BitchatMessage(
                sender: "system",
                content: "user \(targetNick) not found. they must be online to receive ownership.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Update ownership
        channelCreators[currentChannel] = targetPeerID
        saveChannelData()
        
        // Announce the ownership transfer
        if passwordProtectedChannels.contains(currentChannel) {
            let commitment = channelKeyCommitments[currentChannel]
            meshService.announcePasswordProtectedChannel(currentChannel, creatorID: targetPeerID, keyCommitment: commitment)
        }
        
        // Send notification message
        let transferMsg = BitchatMessage(
            sender: "system",
            content: "channel ownership transferred from \(self.nickname) to \(targetNick).",
            timestamp: Date(),
            isRelay: false,
            channel: currentChannel
        )
        messages.append(transferMsg)
        
        // Send encrypted notification if channel is protected
        if let channelKey = channelKeys[currentChannel] {
            let notifyMsg = "🔑 Channel ownership transferred to \(targetNick) by \(self.nickname)"
            meshService.sendEncryptedChannelMessage(notifyMsg, mentions: [targetNick], channel: currentChannel, channelKey: channelKey)
        } else {
            meshService.sendMessage(transferMsg.content, mentions: [targetNick])
        }
        
    }
    
    // Change password for current channel
    func changeChannelPassword(to newPassword: String) {
        guard let currentChannel = currentChannel else {
            let msg = BitchatMessage(
                sender: "system",
                content: "you must be in a channel to change its password.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Check if current user is the owner
        guard channelCreators[currentChannel] == meshService.myPeerID else {
            let msg = BitchatMessage(
                sender: "system",
                content: "only the channel owner can change the password.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Check if channel is currently password protected
        guard passwordProtectedChannels.contains(currentChannel) else {
            let msg = BitchatMessage(
                sender: "system",
                content: "channel is not password protected. use the lock button to set a password.",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(msg)
            return
        }
        
        // Store old key for re-encryption
        let oldKey = channelKeys[currentChannel]
        
        // Derive new encryption key from new password
        let newKey = deriveChannelKey(from: newPassword, channelName: currentChannel)
        channelKeys[currentChannel] = newKey
        channelPasswords[currentChannel] = newPassword
        // Update password in Keychain
        _ = KeychainManager.shared.saveChannelPassword(newPassword, for: currentChannel)
        
        // Compute new key commitment
        let newCommitment = computeKeyCommitment(for: newKey)
        channelKeyCommitments[currentChannel] = newCommitment
        
        // Save channel data
        saveChannelData()
        
        // Send password change notification with old key
        if let oldKey = oldKey {
            let changeNotice = "🔐 Password changed by channel owner. Please update your password."
            meshService.sendEncryptedChannelMessage(changeNotice, mentions: [], channel: currentChannel, channelKey: oldKey)
        }
        
        // Send new initialization message with new key
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let metadata = [
            "type": "password_change",
            "channel": currentChannel,
            "changer": nickname,
            "changerID": meshService.myPeerID,
            "timestamp": timestamp,
            "version": "1.0"
        ]
        let jsonData = try? JSONSerialization.data(withJSONObject: metadata)
        let metadataStr = jsonData?.base64EncodedString() ?? ""
        
        let initMessage = "🔑 Password changed | Channel \(currentChannel) password updated by \(nickname) | Metadata: \(metadataStr)"
        meshService.sendEncryptedChannelMessage(initMessage, mentions: [], channel: currentChannel, channelKey: newKey)
        
        // Announce the new commitment
        meshService.announcePasswordProtectedChannel(currentChannel, creatorID: meshService.myPeerID, keyCommitment: newCommitment)
        
        // Add local success message
        let successMsg = BitchatMessage(
            sender: "system",
            content: "password changed successfully. other users will need to re-enter the new password.",
            timestamp: Date(),
            isRelay: false
        )
        messages.append(successMsg)
        
    }
    
    // MARK: - Channel Management
    
    func switchToChannel(_ channel: String) {
        currentChannel = channel
        selectedPrivateChatPeer = nil
        unreadChannelMessages[channel] = 0
        
        // Send read receipts for messages in this channel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.markChannelMessagesAsRead(for: channel)
        }
    }
    
    func switchToChannel(_ channel: String?) {
        if let channel = channel {
            switchToChannel(channel)
        } else {
            // Switch to general/main channel
            currentChannel = nil
            selectedPrivateChatPeer = nil
            
            // Send read receipts for main messages
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.markMainMessagesAsRead()
            }
        }
    }
    
    private func deriveChannelKey(from password: String, channelName: String) -> SymmetricKey {
        let saltData = "bitchat-channel-\(channelName)".data(using: .utf8)!
        let passwordData = password.data(using: .utf8)!
        
        // Use PBKDF2 for key derivation
        var derivedKey = Data(repeating: 0, count: 32)
        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            saltData.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress, passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        100000, // iterations
                        derivedKeyBytes.bindMemory(to: UInt8.self).baseAddress, 32
                    )
                }
            }
        }
        
        guard result == kCCSuccess else {
            // Fallback to simple HKDF if PBKDF2 fails
            let inputKeyMaterial = SymmetricKey(data: passwordData)
            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKeyMaterial,
                salt: saltData,
                info: Data(),
                outputByteCount: 32
            )
        }
        
        return SymmetricKey(data: derivedKey)
    }
    
    private func computeKeyCommitment(for key: SymmetricKey) -> String {
        let keyData = key.withUnsafeBytes { Data($0) }
        let hash = SHA256.hash(data: keyData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Channel Encryption
    
    func decryptChannelMessage(_ encryptedContent: Data, channel: String, testKey: SymmetricKey? = nil) -> String? {
        let key = testKey ?? channelKeys[channel]
        guard let key = key else { return nil }
        
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedContent)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            return String(data: decryptedData, encoding: .utf8)
        } catch {
            return nil
        }
    }
    
    // MARK: - Command Handling
    
    private func handleCommand(_ command: String) {
        let parts = command.split(separator: " ")
        guard let cmd = parts.first else { return }
        
        switch cmd {
        case "/j", "/join":
            if parts.count > 1 {
                let channelName = String(parts[1])
                // Ensure channel name starts with #
                let channel = channelName.hasPrefix("#") ? channelName : "#\(channelName)"
                
                // Validate channel name
                let cleanedName = channel.dropFirst()
                let isValidName = !cleanedName.isEmpty && cleanedName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
                
                if !isValidName {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "invalid channel name. use only letters, numbers, and underscores.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                } else {
                    let success = joinChannel(channel)
                    if success {
                        let systemMessage = BitchatMessage(
                            sender: "system",
                            content: "joined channel \(channel)",
                            timestamp: Date(),
                            isRelay: false
                        )
                        messages.append(systemMessage)
                    }
                }
            } else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /j #channelname",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
            
        case "/m", "/msg":
            if parts.count > 1 {
                let targetName = String(parts[1])
                let nickname = targetName.hasPrefix("@") ? String(targetName.dropFirst()) : targetName
                
                if let peerID = getPeerIDForNickname(nickname) {
                    startPrivateChat(with: peerID)
                    
                    if parts.count > 2 {
                        let messageContent = parts.dropFirst(2).joined(separator: " ")
                        sendPrivateMessage(messageContent, to: peerID)
                    }
                } else {
                    let systemMessage = BitchatMessage(
                        sender: "system",
                        content: "user \(nickname) not found or not connected.",
                        timestamp: Date(),
                        isRelay: false
                    )
                    messages.append(systemMessage)
                }
            } else {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "usage: /m @nickname [message]",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
            
            
            if allChannels.isEmpty {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "no channels discovered yet.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            } else {
                let channelList = allChannels.sorted().map { channel in
                    var status = ""
                    if joinedChannels.contains(channel) { status += " ✓" }
                    if passwordProtectedChannels.contains(channel) { status += " 🔒" }
                    if retentionEnabledChannels.contains(channel) { status += " 📌" }
                    return "\(channel)\(status)"
                }.joined(separator: "\n")
                
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "discovered channels:\n\(channelList)\n\n✓ = joined, 🔒 = password protected, 📌 = retention enabled",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
            
        case "/w":
            let peerNicknames = meshService.getPeerNicknames()
            if connectedPeers.isEmpty {
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "no one else is online right now.",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            } else {
                let onlineList = connectedPeers.compactMap { peerID in
                    peerNicknames[peerID]
                }.sorted().joined(separator: ", ")
                
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "online users: \(onlineList)",
                    timestamp: Date(),
                    isRelay: false
                )
                messages.append(systemMessage)
            }
            
        case "/clear":
            if let channel = currentChannel {
                channelMessages[channel]?.removeAll()
            } else if let peerID = selectedPrivateChatPeer {
                privateChats[peerID]?.removeAll()
            } else {
                messages.removeAll()
            }
            
        default:
            let systemMessage = BitchatMessage(
                sender: "system",
                content: "unknown command: \(cmd). try /j, /m, /channels, /w, /clear",
                timestamp: Date(),
                isRelay: false
            )
            messages.append(systemMessage)
        }
    }
    
    // MARK: - Missing Methods
    
    func updateMessageDeliveryStatus(messageID: String, status: DeliveryStatus) {
        // Update delivery status for messages
        DispatchQueue.main.async {
            // Check main messages
            if let index = self.messages.firstIndex(where: { $0.id == messageID }) {
                self.messages[index].deliveryStatus = status
            }
            
            // Check channel messages
            for (channel, messages) in self.channelMessages {
                if let index = messages.firstIndex(where: { $0.id == messageID }) {
                    self.channelMessages[channel]![index].deliveryStatus = status
                }
            }
            
            // Check private messages
            for (peerID, messages) in self.privateChats {
                if let index = messages.firstIndex(where: { $0.id == messageID }) {
                    self.privateChats[peerID]![index].deliveryStatus = status
                }
            }
        }
    }
    
    func parseMentions(from content: String) -> [String] {
        let pattern = "@([a-zA-Z0-9_]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        return matches.compactMap { match in
            if let range = Range(match.range(at: 1), in: content) {
                return String(content[range])
            }
            return nil
        }
    }
    
    func parseChannels(from content: String) -> [String] {
        let pattern = "#([a-zA-Z0-9_]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        return matches.compactMap { match in
            if let range = Range(match.range(at: 1), in: content) {
                return String(content[range])
            }
            return nil
        }
    }
    
    @objc func appDidBecomeActive() {
        // Send read receipts for visible messages when app becomes active
        if let currentChannel = currentChannel {
            markChannelMessagesAsRead(for: currentChannel)
        } else {
            markMainMessagesAsRead()
        }
    }
    
    @objc func userDidTakeScreenshot() {
        // Handle screenshot detection for security
        #if os(iOS)
        print("[SECURITY] Screenshot detected")
        // Could implement security measures here if needed
        #endif
    }
    
    func getPeerIDForNickname(_ nickname: String) -> String? {
        let peerNicknames = meshService.getPeerNicknames()
        return peerNicknames.first { $0.value == nickname }?.key
    }
    
    // MARK: - BitchatDelegate Methods
    
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        updateMessageDeliveryStatus(messageID: messageID, status: status)
    }
}
