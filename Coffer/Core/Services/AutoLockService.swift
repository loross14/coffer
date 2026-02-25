import Foundation
import AppKit
import os

/// Monitors system events and auto-locks vaults on sleep, screen lock, or idle timer.
@MainActor @Observable
public final class AutoLockService {

    private var sleepObserver: NSObjectProtocol?
    private var screenLockObserver: NSObjectProtocol?
    private var idleTimer: Timer?

    public private(set) var isMonitoring = false

    public init() {}

    /// Starts monitoring system events. Call once at app launch.
    public func startMonitoring(onAutoLock: @escaping @MainActor () -> Void) {
        guard !isMonitoring else { return }
        isMonitoring = true

        let settings = VaultManager.shared.settings
        let center = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        // Sleep notification
        if settings.autoLockOnSleep {
            sleepObserver = center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    Log.autoLock.info("System going to sleep — auto-locking vaults")
                    onAutoLock()
                }
            }
        }

        // Screen lock notification
        if settings.autoLockOnScreenLock {
            screenLockObserver = dnc.addObserver(
                forName: NSNotification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    Log.autoLock.info("Screen locked — auto-locking vaults")
                    onAutoLock()
                }
            }
        }

        // Idle timer
        let idleMinutes = settings.defaultAutoLockMinutes
        if idleMinutes > 0 {
            idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { @MainActor in
                    let idleTime = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
                    let threshold = Double(idleMinutes * 60)
                    if idleTime >= threshold {
                        Log.autoLock.info("Idle for \(Int(idleTime))s — auto-locking vaults")
                        onAutoLock()
                    }
                }
            }
        }

        Log.autoLock.info("AutoLockService started (sleep: \(settings.autoLockOnSleep), screenLock: \(settings.autoLockOnScreenLock), idle: \(idleMinutes)min)")
    }

    /// Stops all monitoring. Call before reconfiguring or on app quit.
    public func stopMonitoring() {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let screenLockObserver {
            DistributedNotificationCenter.default().removeObserver(screenLockObserver)
        }
        idleTimer?.invalidate()

        sleepObserver = nil
        screenLockObserver = nil
        idleTimer = nil
        isMonitoring = false

        Log.autoLock.info("AutoLockService stopped")
    }

    /// Restarts monitoring with current settings. Call after settings change.
    public func reconfigure(onAutoLock: @escaping @MainActor () -> Void) {
        stopMonitoring()
        startMonitoring(onAutoLock: onAutoLock)
    }
}
