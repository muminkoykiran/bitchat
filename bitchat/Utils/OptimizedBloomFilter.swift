//
// OptimizedBloomFilter.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CryptoKit

/// Optimized Bloom filter using bit-packed storage and better hash functions
struct OptimizedBloomFilter {
    private var bitArray: [UInt64]
    private let bitCount: Int
    private let hashCount: Int
    
    // Statistics
    private(set) var insertCount: Int = 0
    private var lastResetTime: Date = Date()
    
    // Thread safety
    private let lock = NSLock()
    
    // Performance optimization - cache hash computation
    private var hashCache: [String: [Int]] = [:]
    private let maxCacheSize = 1000
    
    init(expectedItems: Int = 1000, falsePositiveRate: Double = 0.01) {
        // Validate input parameters
        guard expectedItems > 0 && falsePositiveRate > 0 && falsePositiveRate < 1 else {
            // Use safe defaults for invalid input
            self.bitCount = 9600 // For 1000 items, 0.01 FPR
            self.hashCount = 7
            self.bitArray = Array(repeating: 0, count: 150) // (9600 + 63) / 64
            return
        }
        
        // Calculate optimal bit count and hash count
        let m = Double(expectedItems) * abs(log(falsePositiveRate)) / (log(2) * log(2))
        self.bitCount = Int(max(64, m.rounded()))
        
        let k = Double(bitCount) / Double(expectedItems) * log(2)
        self.hashCount = Int(max(1, min(20, k.rounded()))) // Increased max to 20
        
        // Initialize bit array (64 bits per UInt64)
        let arraySize = (bitCount + 63) / 64
        self.bitArray = Array(repeating: 0, count: arraySize)
    }
    
    mutating func insert(_ item: String) {
        // Validate input
        guard !item.isEmpty else { return }
        
        lock.lock()
        defer { lock.unlock() }
        
        let hashes = getCachedHashes(item)
        
        for i in 0..<hashCount {
            let bitIndex = hashes[i] % bitCount
            let arrayIndex = bitIndex / 64
            let bitOffset = bitIndex % 64
            
            bitArray[arrayIndex] |= (1 << bitOffset)
        }
        
        insertCount += 1
        
        // Trigger cache cleanup if needed
        if hashCache.count > maxCacheSize {
            cleanupHashCache()
        }
    }
    
    func contains(_ item: String) -> Bool {
        // Validate input
        guard !item.isEmpty else { return false }
        
        lock.lock()
        defer { lock.unlock() }
        
        let hashes = getCachedHashes(item)
        
        for i in 0..<hashCount {
            let bitIndex = hashes[i] % bitCount
            let arrayIndex = bitIndex / 64
            let bitOffset = bitIndex % 64
            
            if (bitArray[arrayIndex] & (1 << bitOffset)) == 0 {
                return false
            }
        }
        
        return true
    }
    
    mutating func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        for i in 0..<bitArray.count {
            bitArray[i] = 0
        }
        insertCount = 0
        lastResetTime = Date()
        hashCache.removeAll()
    }
    
    // MARK: - Hash Management
    
    private mutating func getCachedHashes(_ item: String) -> [Int] {
        if let cached = hashCache[item] {
            return cached
        }
        
        let hashes = generateHashes(item)
        hashCache[item] = hashes
        return hashes
    }
    
    private mutating func cleanupHashCache() {
        // Remove random 50% of cache entries to manage memory
        let keysToRemove = hashCache.keys.shuffled().prefix(hashCache.count / 2)
        for key in keysToRemove {
            hashCache.removeValue(forKey: key)
        }
    }
    
    // Generate multiple hash values using double hashing technique
    private func generateHashes(_ item: String) -> [Int] {
        guard let data = item.data(using: .utf8) else {
            return Array(repeating: 0, count: hashCount)
        }
        
        // Use SHA256 for high-quality hash values
        let hash = SHA256.hash(data: data)
        let hashBytes = Array(hash)
        
        var hashes = [Int]()
        
        // Use double hashing for better distribution
        let hash1 = extractHashValue(from: hashBytes, offset: 0)
        let hash2 = extractHashValue(from: hashBytes, offset: 8)
        
        for i in 0..<hashCount {
            // Double hashing: h(k,i) = (h1(k) + i * h2(k)) mod m
            let combinedHash = hash1.addingReportingOverflow(i.multipliedReportingOverflow(by: hash2).partialValue)
            hashes.append(abs(combinedHash.partialValue))
        }
        
        return hashes
    }
    
    private func extractHashValue(from bytes: [UInt8], offset: Int) -> Int {
        guard offset + 3 < bytes.count else {
            // Fallback for edge case
            return Int(bytes[0]) | (Int(bytes[1 % bytes.count]) << 8)
        }
        
        return Int(bytes[offset]) |
               (Int(bytes[offset + 1]) << 8) |
               (Int(bytes[offset + 2]) << 16) |
               (Int(bytes[offset + 3]) << 24)
    }
    
    // MARK: - Statistics and Monitoring
    
    // Calculate current false positive probability
    var estimatedFalsePositiveRate: Double {
        lock.lock()
        defer { lock.unlock() }
        
        guard insertCount > 0 else { return 0 }
        
        // Count set bits efficiently
        var setBits = 0
        for value in bitArray {
            setBits += value.nonzeroBitCount
        }
        
        // Calculate probability: (1 - e^(-kn/m))^k
        let ratio = Double(hashCount * insertCount) / Double(bitCount)
        return pow(1 - exp(-ratio), Double(hashCount))
    }
    
    // Get memory usage in bytes
    var memorySizeBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        
        return bitArray.count * 8 + hashCache.count * 50 // Approximate cache overhead
    }
    
    // Get saturation level (percentage of bits set)
    var saturationLevel: Double {
        lock.lock()
        defer { lock.unlock() }
        
        var setBits = 0
        for value in bitArray {
            setBits += value.nonzeroBitCount
        }
        return Double(setBits) / Double(bitCount)
    }
    
    // Check if filter needs reset due to high saturation
    var needsReset: Bool {
        return saturationLevel > 0.8 || estimatedFalsePositiveRate > 0.1
    }
    
    // Get performance metrics
    var performanceMetrics: (insertCount: Int, estimatedFPR: Double, saturation: Double, cacheHitRatio: Double) {
        lock.lock()
        defer { lock.unlock() }
        
        let cacheHitRatio = hashCache.isEmpty ? 0.0 : min(1.0, Double(hashCache.count) / Double(insertCount))
        return (insertCount, estimatedFalsePositiveRate, saturationLevel, cacheHitRatio)
    }
}

// Extension for adaptive Bloom filter that adjusts based on network size
extension OptimizedBloomFilter {
    static func adaptive(for networkSize: Int) -> OptimizedBloomFilter {
        // Adjust parameters based on network size with more granular scaling
        let expectedItems: Int
        let falsePositiveRate: Double
        
        switch networkSize {
        case 0..<10:
            expectedItems = 100
            falsePositiveRate = 0.005 // Lower FPR for small networks
        case 10..<50:
            expectedItems = 500
            falsePositiveRate = 0.01
        case 50..<100:
            expectedItems = 1000
            falsePositiveRate = 0.015
        case 100..<200:
            expectedItems = 2000
            falsePositiveRate = 0.02
        case 200..<500:
            expectedItems = 5000
            falsePositiveRate = 0.03
        case 500..<1000:
            expectedItems = 10000
            falsePositiveRate = 0.04
        default:
            expectedItems = 20000
            falsePositiveRate = 0.05
        }
        
        return OptimizedBloomFilter(expectedItems: expectedItems, falsePositiveRate: falsePositiveRate)
    }
    
    // Create a bloom filter optimized for message deduplication
    static func forMessageDeduplication(messageRate: Int = 100) -> OptimizedBloomFilter {
        // Estimate messages per hour and create appropriate filter
        let expectedMessages = messageRate * 60 // Messages per hour
        return OptimizedBloomFilter(expectedItems: expectedMessages, falsePositiveRate: 0.001)
    }
    
    // Create a bloom filter for peer tracking
    static func forPeerTracking(maxPeers: Int = 1000) -> OptimizedBloomFilter {
        return OptimizedBloomFilter(expectedItems: maxPeers, falsePositiveRate: 0.01)
    }
}