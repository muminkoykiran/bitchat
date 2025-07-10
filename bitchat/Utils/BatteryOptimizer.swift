//
// BatteryOptimizer.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Combine
#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit.ps
#endif

enum PowerMode {
    case performance    // Max performance, battery drain OK
    case balanced      // Default balanced mode
    case powerSaver    // Aggressive power saving
    case ultraLowPower // Emergency mode
    
    var scanDuration: TimeInterval {
        switch self {
        case .performance: return 3.0
        case .balanced: return 2.0
        case .powerSaver: return 1.0
        case .ultraLowPower: return 0.5
        }
    }
    
    var scanPauseDuration: TimeInterval {
        switch self {
        case .performance: return 2.0
        case .balanced: return 3.0
        case .powerSaver: return 8.0
        case .ultraLowPower: return 20.0
        }
    }
    
    var maxConnections: Int {
        switch self {
        case .performance: return 20
        case .balanced: return 10
        case .powerSaver: return 5
        case .ultraLowPower: return 2
        }
    }
    
    var advertisingInterval: TimeInterval {
        // Note: iOS doesn't let us control this directly, but we can stop/start advertising
        switch self {
        case .performance: return 0.0  // Continuous
        case .balanced: return 5.0     // Advertise every 5 seconds
        case .powerSaver: return 15.0  // Advertise every 15 seconds
        case .ultraLowPower: return 30.0 // Advertise every 30 seconds
        }
    }
    
    var messageAggregationWindow: TimeInterval {
        switch self {
        case .performance: return 0.05  // 50ms
        case .balanced: return 0.1      // 100ms
        case .powerSaver: return 0.3    // 300ms
        case .ultraLowPower: return 0.5 // 500ms
        }
    }
}

class BatteryOptimizer {
    static let shared = BatteryOptimizer()
    
    @Published var currentPowerMode: PowerMode = .balanced
    @Published var isInBackground: Bool = false
    @Published var batteryLevel: Float = 1.0
    @Published var isCharging: Bool = false
    @Published var thermalState: ThermalState = .nominal
    
    private var observers: [NSObjectProtocol] = []
    private let modeChangeCooldown: TimeInterval = 30.0 // Prevent rapid mode switching
    private var lastModeChange: Date = Date.distantPast
    private var powerModeHistory: [(PowerMode, Date)] = []
    private let maxHistorySize = 10
    
    // Performance monitoring
    private var networkActivityLevel: NetworkActivity = .low
    private var cpuUsage: Double = 0.0
    private var lastThermalCheck: Date = Date.distantPast
    private let thermalCheckInterval: TimeInterval = 60.0
    
    enum ThermalState {
        case nominal, fair, serious, critical
        
        var powerModeMultiplier: Double {
            switch self {
            case .nominal: return 1.0
            case .fair: return 0.8
            case .serious: return 0.6
            case .critical: return 0.3
            }
        }
    }
    
    enum NetworkActivity {
        case low, moderate, high, veryHigh
        
        var powerModeAdjustment: PowerMode {
            switch self {
            case .low: return .powerSaver
            case .moderate: return .balanced
            case .high: return .balanced
            case .veryHigh: return .performance
            }
        }
    }
    
    private init() {
        setupObservers()
        updateBatteryStatus()
        updateThermalState()
    }
    
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    
    // MARK: - Public API
    
    func updateNetworkActivity(_ activity: NetworkActivity) {
        guard networkActivityLevel != activity else { return }
        networkActivityLevel = activity
        updatePowerMode()
    }
    
    func reportCPUUsage(_ usage: Double) {
        cpuUsage = max(0.0, min(1.0, usage))
        if usage > 0.8 {
            // High CPU usage detected, consider power saving
            updatePowerMode()
        }
    }
    
    func getOptimalScanParameters() -> (duration: TimeInterval, pause: TimeInterval) {
        let mode = getEffectivePowerMode()
        let thermalMultiplier = thermalState.powerModeMultiplier
        
        return (
            duration: mode.scanDuration * thermalMultiplier,
            pause: mode.scanPauseDuration / thermalMultiplier
        )
    }
    
    func getEffectivePowerMode() -> PowerMode {
        // Apply thermal throttling
        switch thermalState {
        case .critical:
            return .ultraLowPower
        case .serious:
            return .powerSaver
        case .fair:
            // Downgrade by one level
            switch currentPowerMode {
            case .performance: return .balanced
            case .balanced: return .powerSaver
            case .powerSaver, .ultraLowPower: return currentPowerMode
            }
        case .nominal:
            return currentPowerMode
        }
    }
    
    var shouldThrottle: Bool {
        return thermalState == .serious || thermalState == .critical ||
               (batteryLevel < 0.15 && !isCharging) ||
               cpuUsage > 0.9
    }
    
    private func setupObservers() {
        #if os(iOS)
        // Monitor app state
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isInBackground = true
                self?.updatePowerMode()
            }
        )
        
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isInBackground = false
                self?.updatePowerMode()
            }
        )
        
        // Monitor battery
        UIDevice.current.isBatteryMonitoringEnabled = true
        
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIDevice.batteryLevelDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateBatteryStatus()
            }
        )
        
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateBatteryStatus()
            }
        )
        #endif
    }
    
    private func updateBatteryStatus() {
        #if os(iOS)
        batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel < 0 {
            batteryLevel = 1.0 // Unknown battery level
        }
        
        isCharging = UIDevice.current.batteryState == .charging || 
                     UIDevice.current.batteryState == .full
        #elseif os(macOS)
        if let info = getMacOSBatteryInfo() {
            batteryLevel = info.level
            isCharging = info.isCharging
        }
        #endif
        
        updatePowerMode()
    }
    
    #if os(macOS)
    private func getMacOSBatteryInfo() -> (level: Float, isCharging: Bool)? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                if let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
                   let maxCapacity = description[kIOPSMaxCapacityKey] as? Int {
                    let level = Float(currentCapacity) / Float(maxCapacity)
                    let isCharging = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                    return (level, isCharging)
                }
            }
        }
        return nil
    }
    #endif
    
    private func updatePowerMode() {
        // Determine optimal power mode based on:
        // 1. Battery level
        // 2. Charging status
        // 3. Background/foreground state
        
        if isCharging {
            // When charging, use performance mode unless battery is critical
            currentPowerMode = batteryLevel < 0.1 ? .balanced : .performance
        } else if isInBackground {
            // In background, always use power saving
            if batteryLevel < 0.2 {
                currentPowerMode = .ultraLowPower
            } else if batteryLevel < 0.5 {
                currentPowerMode = .powerSaver
            } else {
                currentPowerMode = .balanced
            }
        } else {
            // Foreground, not charging
            if batteryLevel < 0.1 {
                currentPowerMode = .ultraLowPower
            } else if batteryLevel < 0.3 {
                currentPowerMode = .powerSaver
            } else if batteryLevel < 0.6 {
                currentPowerMode = .balanced
            } else {
                currentPowerMode = .performance
            }
        }
    }
    
    // Manual power mode override
    func setPowerMode(_ mode: PowerMode) {
        currentPowerMode = mode
    }
    
    // Get current scan parameters
    var scanParameters: (duration: TimeInterval, pause: TimeInterval) {
        return (currentPowerMode.scanDuration, currentPowerMode.scanPauseDuration)
    }
    
    // Should we skip non-essential operations?
    var shouldSkipNonEssential: Bool {
        return currentPowerMode == .ultraLowPower || 
               (currentPowerMode == .powerSaver && isInBackground)
    }
    
    // Should we reduce message frequency?
    var shouldThrottleMessages: Bool {
        return currentPowerMode == .powerSaver || currentPowerMode == .ultraLowPower
    }
}