//
// EncryptionService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

class EncryptionService {
    // Key agreement keys for encryption
    private var privateKey: Curve25519.KeyAgreement.PrivateKey
    public let publicKey: Curve25519.KeyAgreement.PublicKey
    
    // Signing keys for authentication
    private var signingPrivateKey: Curve25519.Signing.PrivateKey
    public let signingPublicKey: Curve25519.Signing.PublicKey
    
    // Storage for peer keys - protected by concurrent queue with barriers
    private var peerPublicKeys: [String: Curve25519.KeyAgreement.PublicKey] = [:]
    private var peerSigningKeys: [String: Curve25519.Signing.PublicKey] = [:]
    private var peerIdentityKeys: [String: Curve25519.Signing.PublicKey] = [:]
    private var sharedSecrets: [String: SymmetricKey] = [:]
    
    // Persistent identity for favorites (separate from ephemeral keys)
    private let identityKey: Curve25519.Signing.PrivateKey
    public let identityPublicKey: Curve25519.Signing.PublicKey
    
    // Thread safety
    private let cryptoQueue = DispatchQueue(label: "chat.bitchat.crypto", attributes: .concurrent)
    
    // Key rotation parameters
    private let keyRotationInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    private var lastKeyRotation: Date
    private var keyGenerationCounter: UInt64 = 0
    
    init() {
        // Initialize key rotation timestamp
        self.lastKeyRotation = Date()
        
        // Generate ephemeral key pairs for this session
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.publicKey = privateKey.publicKey
        
        self.signingPrivateKey = Curve25519.Signing.PrivateKey()
        self.signingPublicKey = signingPrivateKey.publicKey
        
        // Load or create persistent identity key from secure keychain
        if let identityData = KeychainManager.shared.retrieveData(key: "bitchat.identityKey"),
           let loadedKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: identityData) {
            self.identityKey = loadedKey
        } else {
            // First run - create and save identity key to keychain
            self.identityKey = Curve25519.Signing.PrivateKey()
            let _ = KeychainManager.shared.storeData(identityKey.rawRepresentation, key: "bitchat.identityKey")
        }
        self.identityPublicKey = identityKey.publicKey
        
        // Increment key generation counter
        self.keyGenerationCounter += 1
    }
    
    deinit {
        // Clear sensitive data from memory
        clearEphemeralKeys()
    }
    
    // MARK: - Key Management
    
    /// Rotates ephemeral keys for forward secrecy
    func rotateEphemeralKeys() {
        cryptoQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // Generate new ephemeral key pairs
            self.privateKey = Curve25519.KeyAgreement.PrivateKey()
            self.signingPrivateKey = Curve25519.Signing.PrivateKey()
            
            // Clear old shared secrets to force renegotiation
            self.sharedSecrets.removeAll()
            
            // Update timestamp and counter
            self.lastKeyRotation = Date()
            self.keyGenerationCounter += 1
        }
    }
    
    /// Checks if key rotation is needed and performs it
    func checkAndRotateKeys() {
        if Date().timeIntervalSince(lastKeyRotation) > keyRotationInterval {
            rotateEphemeralKeys()
        }
    }
    
    /// Clears ephemeral cryptographic material from memory
    private func clearEphemeralKeys() {
        cryptoQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.sharedSecrets.removeAll()
            self.peerPublicKeys.removeAll()
            self.peerSigningKeys.removeAll()
            // Note: Identity keys are persistent and not cleared
        }
    }
    
    // Create combined public key data for exchange
    func getCombinedPublicKeyData() -> Data {
        var data = Data()
        data.append(publicKey.rawRepresentation)  // 32 bytes - ephemeral encryption key
        data.append(signingPublicKey.rawRepresentation)  // 32 bytes - ephemeral signing key
        data.append(identityPublicKey.rawRepresentation)  // 32 bytes - persistent identity key
        return data  // Total: 96 bytes
    }
    
    // Add peer's combined public keys with enhanced validation
    func addPeerPublicKey(_ peerID: String, publicKeyData: Data) throws {
        // Validate peer ID
        guard !peerID.isEmpty && peerID.count <= 64 else {
            throw EncryptionError.invalidPeerID
        }
        
        try cryptoQueue.sync(flags: .barrier) {
            // Convert to array for safe access
            let keyBytes = [UInt8](publicKeyData)
            
            guard keyBytes.count == 96 else {
                throw EncryptionError.invalidPublicKey
            }
            
            // Validate key data is not all zeros (weak key detection)
            let zeroKey = Data(repeating: 0, count: 32)
            let keyAgreementData = Data(keyBytes[0..<32])
            let signingKeyData = Data(keyBytes[32..<64])
            let identityKeyData = Data(keyBytes[64..<96])
            
            guard keyAgreementData != zeroKey && 
                  signingKeyData != zeroKey && 
                  identityKeyData != zeroKey else {
                throw EncryptionError.weakKey
            }
            
            // Extract and validate all three keys
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyAgreementData)
            let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: signingKeyData)
            let identityKey = try Curve25519.Signing.PublicKey(rawRepresentation: identityKeyData)
            
            // Store keys
            peerPublicKeys[peerID] = publicKey
            peerSigningKeys[peerID] = signingKey
            peerIdentityKeys[peerID] = identityKey
            
            // Generate shared secret for encryption with enhanced HKDF
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data("bitchat-v1-salt".utf8),
                sharedInfo: Data("\(keyGenerationCounter)".utf8), // Include generation counter
                outputByteCount: 32
            )
            sharedSecrets[peerID] = symmetricKey
        }
    }
    
    // Get peer's persistent identity key for favorites
    func getPeerIdentityKey(_ peerID: String) -> Data? {
        return cryptoQueue.sync {
            return peerIdentityKeys[peerID]?.rawRepresentation
        }
    }
    
    // Clear persistent identity (for panic mode)
    func clearPersistentIdentity() {
        let _ = KeychainManager.shared.deleteData(key: "bitchat.identityKey")
    }
    
    // MARK: - Encryption/Decryption
    
    func encrypt(_ data: Data, for peerID: String) throws -> Data {
        // Validate input
        guard !data.isEmpty && data.count <= 1024 * 1024 else { // 1MB limit
            throw EncryptionError.invalidDataSize
        }
        
        let symmetricKey = try cryptoQueue.sync {
            guard let key = sharedSecrets[peerID] else {
                throw EncryptionError.noSharedSecret
            }
            return key
        }
        
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        guard let combined = sealedBox.combined else {
            throw EncryptionError.encryptionFailed
        }
        return combined
    }
    
    func decrypt(_ data: Data, from peerID: String) throws -> Data {
        // Validate input
        guard !data.isEmpty && data.count >= 28 else { // Minimum size for AES-GCM
            throw EncryptionError.invalidDataSize
        }
        
        let symmetricKey = try cryptoQueue.sync {
            guard let key = sharedSecrets[peerID] else {
                throw EncryptionError.noSharedSecret
            }
            return key
        }
        
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw EncryptionError.decryptionFailed
        }
    }
    
    // MARK: - Digital Signatures
    
    func sign(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw EncryptionError.invalidDataSize
        }
        
        // Create a local copy of the key to avoid concurrent access
        let key = signingPrivateKey
        do {
            return try key.signature(for: data)
        } catch {
            throw EncryptionError.signingFailed
        }
    }
    
    func verify(_ signature: Data, for data: Data, from peerID: String) throws -> Bool {
        guard !data.isEmpty && !signature.isEmpty else {
            throw EncryptionError.invalidDataSize
        }
        
        let verifyingKey = try cryptoQueue.sync {
            guard let key = peerSigningKeys[peerID] else {
                throw EncryptionError.noPeerKey
            }
            return key
        }
        
        do {
            return verifyingKey.isValidSignature(signature, for: data)
        } catch {
            throw EncryptionError.verificationFailed
        }
    }
    
    // MARK: - Utility Methods
    
    /// Remove a peer's keys (for cleanup)
    func removePeer(_ peerID: String) {
        cryptoQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.peerPublicKeys.removeValue(forKey: peerID)
            self.peerSigningKeys.removeValue(forKey: peerID)
            self.peerIdentityKeys.removeValue(forKey: peerID)
            self.sharedSecrets.removeValue(forKey: peerID)
        }
    }
    
    /// Get current key generation counter for debugging
    var currentKeyGeneration: UInt64 {
        return keyGenerationCounter
    }
    
}

enum EncryptionError: Error {
    case noSharedSecret
    case noPeerKey
    case invalidPeerID
    case invalidPublicKey
    case weakKey
    case invalidDataSize
    case encryptionFailed
    case decryptionFailed
    case signingFailed
    case verificationFailed
}