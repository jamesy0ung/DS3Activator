//
//  DS3ActivatorApp.swift
//  DS3Activator
//
//  Created by James Young on 25/4/2025.
//

import SwiftUI
import IOKit.hid
import UserNotifications
import ServiceManagement
import os.log

// MARK: - Global Constants

/// App constants including identifiers and values
enum AppConstants {
    /// HID constants for device identification
    enum HID {
        static let vendorID = 0x054C  // Sony
        static let productID = 0x0268 // DualShock 3 Controller
        static let deviceName = "DualShock 3"
    }
    
    /// Notification preferences keys
    enum Preferences {
        static let showNotifications = "showNotifications"
        static let verboseNotifications = "verboseNotifications"
    }
    
    /// Logger subsystem and categories
    enum Logging {
        static let subsystem = "org.jamesyoung.DS3Activator"
        
        enum Category {
            static let app = "Application"
            static let hid = "HID"
            static let device = "Device"
            static let activation = "Activation"
            static let notification = "Notification"
            static let settings = "Settings"
            static let launchAtLogin = "LaunchAtLogin"
        }
    }
}

// MARK: - Launch at Login Manager

/// Dedicated manager for handling Launch at Login functionality
final class LaunchAtLoginManager {
    // Singleton instance for app-wide access
    static let shared = LaunchAtLoginManager()
    
    // Logger for improved diagnostics
    private let logger = Logger(subsystem: AppConstants.Logging.subsystem, category: AppConstants.Logging.Category.launchAtLogin)
    
    // Private init for singleton pattern
    private init() {}
    
    /// Current status of Launch at Login
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
    
    /// Set Launch at Login status
    /// - Parameter enabled: Whether to enable Launch at Login
    /// - Returns: Result with void on success or error on failure
    func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        let service = SMAppService.mainApp
        
        logger.info("Setting Launch at Login to \(enabled ? "enabled" : "disabled"), current status: \(service.status.description)")
        
        do {
            if enabled {
                // Only register if not already enabled
                if service.status != .enabled {
                    try service.register()
                    logger.info("Successfully registered for Launch at Login")
                }
            } else {
                // Only unregister if currently enabled
                if service.status == .enabled {
                    try service.unregister()
                    logger.info("Successfully unregistered from Launch at Login")
                }
            }
            return .success(())
        } catch {
            logger.error("Failed to \(enabled ? "register" : "unregister") for Launch at Login: \(error.localizedDescription)")
            return .failure(error)
        }
    }
}

// MARK: - Notification Manager

/// Manages all app notifications
final class NotificationManager {
    static let shared = NotificationManager()
    
    private let logger = Logger(subsystem: AppConstants.Logging.subsystem, category: AppConstants.Logging.Category.notification)
    private let notificationCenter = UNUserNotificationCenter.current()
    
    private init() {}
    
    /// Request notification permissions from the user
    /// - Parameter completion: Called when permission request completes
    func requestPermissions(completion: ((Bool, Error?) -> Void)? = nil) {
        notificationCenter.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.logger.error("Authorization error: \(error.localizedDescription)")
                } else {
                    self?.logger.info("Notification permission \(granted ? "granted" : "denied")")
                }
                completion?(granted, error)
            }
        }
    }
    
    /// Send a notification to the user
    /// - Parameters:
    ///   - title: Notification title
    ///   - body: Notification body text
    ///   - isDebug: Whether this is a debug notification (subject to verbose setting)
    func notify(title: String, body: String, isDebug: Bool = false) {
        // Always log regardless of notification settings
        logger.info("\(isDebug ? "[DEBUG] " : "")\(title): \(body)")
        
        // Only send user notification if enabled
        let shouldShowNotification: Bool
        
        if isDebug {
            shouldShowNotification = UserDefaults.standard.bool(forKey: AppConstants.Preferences.verboseNotifications)
        } else {
            shouldShowNotification = UserDefaults.standard.bool(forKey: AppConstants.Preferences.showNotifications)
        }
        
        guard shouldShowNotification else { return }
        
        let content = UNMutableNotificationContent()
        content.title = isDebug ? "[Debug] \(title)" : title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        notificationCenter.add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }
    
    /// Present a critical alert modal to the user
    /// - Parameters:
    ///   - title: Alert title
    ///   - message: Alert message
    ///   - completion: Called when alert is dismissed
    func presentCriticalAlert(title: String, message: String, completion: (() -> Void)? = nil) {
        logger.error("Critical alert: \(title) - \(message)")
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completion?()
        }
    }
}

// MARK: - HID Controller

/// Manages HID device detection and interaction
final class DS3HIDController {
    private let hidManager: IOHIDManager
    private let logger = Logger(subsystem: AppConstants.Logging.subsystem, category: AppConstants.Logging.Category.hid)
    
    // Callbacks
    var onConnect: ((IOHIDDevice) -> Void)?
    var onDisconnect: ((IOHIDDevice) -> Void)?
    
    init() throws {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        logger.info("IOHIDManager created")
        
        let criteria: [String: Any] = [
            kIOHIDVendorIDKey as String: AppConstants.HID.vendorID,
            kIOHIDProductIDKey as String: AppConstants.HID.productID
        ]
        IOHIDManagerSetDeviceMatching(hidManager, criteria as CFDictionary)
        logger.info("Matching criteria set (Vendor: 0x\(String(format: "%04X", AppConstants.HID.vendorID)), Product: 0x\(String(format: "%04X", AppConstants.HID.productID)))")
        
        // Retain self for C‑callbacks (released in deinit)
        let opaqueSelf = Unmanaged.passRetained(self).toOpaque()
        
        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, { context, _, _, device in
            guard let context else { return }
            let instance = Unmanaged<DS3HIDController>.fromOpaque(context).takeUnretainedValue()
            instance.onConnect?(device)
        }, opaqueSelf)
        
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, { context, _, _, device in
            guard let context else { return }
            let instance = Unmanaged<DS3HIDController>.fromOpaque(context).takeUnretainedValue()
            instance.onDisconnect?(device)
        }, opaqueSelf)
        
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        
        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            let errorMsg = String(format: "IOHIDManagerOpen failed (0x%08X)", result)
            logger.error("\(errorMsg)")
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: errorMsg]
            )
        }
        logger.info("IOHIDManager opened successfully")
    }
    
    deinit {
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        Unmanaged.passUnretained(self).release()
        logger.info("IOHIDManager closed & callbacks released")
    }
    
    /// Get device name from HID device
    /// - Parameter device: The HID device
    /// - Returns: Device name or nil if not available
    func getDeviceName(_ device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
    }
    
    /// Activate the controller for use
    /// - Parameters:
    ///   - device: The HID device to activate
    ///   - deviceName: Name of the device for notifications
    func activateController(_ device: IOHIDDevice, named deviceName: String) {
        NotificationManager.shared.notify(title: "Activation", body: "Starting activation for \(deviceName)", isDebug: true)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            self.logger.info("Beginning activation for \(deviceName)")
            
            // Open device with exclusive access
            let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            guard openResult == kIOReturnSuccess else {
                self.logger.error("Failed to open device: Error 0x\(String(format: "%08X", openResult))")
                NotificationManager.shared.notify(
                    title: "Activation Failed",
                    body: "Could not exclusively access \(deviceName)"
                )
                return
            }
            
            // Ensure device is closed when done
            defer {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                self.logger.info("Device closed after activation attempt")
            }
            
            // Send feature report (0xF4) - activation command
            let feature: [UInt8] = [0x42, 0x0C, 0x00, 0x00]
            let featureResult = feature.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0xF4, $0.baseAddress!, $0.count)
            }
            
            guard featureResult == kIOReturnSuccess else {
                self.logger.error("Feature report failed: Error 0x\(String(format: "%08X", featureResult))")
                NotificationManager.shared.notify(
                    title: "Activation Failed",
                    body: "Could not send activation command to \(deviceName)"
                )
                return
            }
            
            self.logger.info("Feature report sent successfully")
            
            // Give controller time to process
            Thread.sleep(forTimeInterval: 0.1)
            
            // Output report (0x01) – set LED1
            var output = [UInt8](repeating: 0, count: 48)
            output[0] = 0x01  // Report ID
            output[9] = 0x02  // LED1 on
            
            let outputResult = output.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x01, $0.baseAddress!, $0.count)
            }
            
            if outputResult == kIOReturnSuccess {
                self.logger.info("Activation completed successfully")
                NotificationManager.shared.notify(
                    title: "\(deviceName) Ready",
                    body: "Controller activated and ready"
                )
            } else {
                self.logger.error("Output report failed: Error 0x\(String(format: "%08X", outputResult))")
                NotificationManager.shared.notify(
                    title: "Activation Issue",
                    body: "LED setup failed for \(deviceName)"
                )
            }
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var hidController: DS3HIDController?
    private var settingsWindowController: NSWindowController?
    
    private let logger = Logger(subsystem: AppConstants.Logging.subsystem, category: AppConstants.Logging.Category.app)
    
    // Set default values for user preferences if not already set
    private func registerDefaultPreferences() {
        UserDefaults.standard.register(defaults: [
            AppConstants.Preferences.showNotifications: true,
            AppConstants.Preferences.verboseNotifications: false
        ])
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register default preferences first
        registerDefaultPreferences()
        
        // Setup notification handling
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermissions()
        
        // Setup UI and HID controller
        setupMenuBar()
        setupHID()
        
        logger.info("DS3Activator launched successfully")
    }
    
    // MARK: - Permissions
    
    func requestNotificationPermissions() {
        NotificationManager.shared.requestPermissions { [weak self] granted, error in
            if let error = error {
                self?.logger.error("Notification permission error: \(error.localizedDescription)")
                NotificationManager.shared.notify(
                    title: "Permissions",
                    body: "Authorization error: \(error.localizedDescription)",
                    isDebug: true
                )
            } else {
                self?.logger.info("Notification permission \(granted ? "granted" : "denied")")
                NotificationManager.shared.notify(
                    title: "Permissions",
                    body: "Permission \(granted ? "granted" : "denied")",
                    isDebug: true
                )
            }
        }
    }
    
    // MARK: - Menu Bar
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "gamecontroller.fill",
            accessibilityDescription: "DS3 Activator"
        )
        
        let menu = NSMenu()
        
        // Add title item
        let titleItem = NSMenuItem(title: "DualShock 3 Activator", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())
        
        // Add settings item
        menu.addItem(
            NSMenuItem(
                title: "Settings…",
                action: #selector(openSettings),
                keyEquivalent: ","
            )
        )
        menu.addItem(.separator())
        
        // Add quit item
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        
        statusItem.menu = menu
        logger.info("Menu bar setup complete")
    }
    
    @objc private func openSettings() {
        if settingsWindowController == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "DS3 Activator Settings"
            window.contentView = hostingController.view
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Settings window opened")
    }
    
    // MARK: - HID
    
    private func setupHID() {
        do {
            hidController = try DS3HIDController()
            hidController?.onConnect = { [weak self] in self?.deviceConnected($0) }
            hidController?.onDisconnect = { [weak self] in self?.deviceDisconnected($0) }
            NotificationManager.shared.notify(
                title: "HID",
                body: "Controller initialized; awaiting connection…",
                isDebug: true
            )
        } catch {
            logger.error("HID initialization failed: \(error.localizedDescription)")
            NotificationManager.shared.presentCriticalAlert(
                title: "HID Initialization Failed",
                message: "The application cannot detect controllers.\n\nError: \(error.localizedDescription)"
            )
            NotificationManager.shared.notify(
                title: "HID",
                body: "Initialization failed: \(error.localizedDescription)",
                isDebug: true
            )
        }
    }
    
    private func deviceConnected(_ device: IOHIDDevice) {
        let name = hidController?.getDeviceName(device) ?? AppConstants.HID.deviceName
        logger.info("\(name) connected")
        
        NotificationManager.shared.notify(
            title: "Device",
            body: "\(name) connected",
            isDebug: true
        )
        
        NotificationManager.shared.notify(
            title: "\(name) Detected",
            body: "Attempting to activate controller…"
        )
        
        hidController?.activateController(device, named: name)
    }
    
    private func deviceDisconnected(_ device: IOHIDDevice) {
        let name = hidController?.getDeviceName(device) ?? AppConstants.HID.deviceName
        logger.info("\(name) disconnected")
        
        NotificationManager.shared.notify(
            title: "Device",
            body: "\(name) disconnected",
            isDebug: true
        )
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        logger.info("User interacted with notification: \(response.notification.request.content.title)")
        completionHandler()
    }
}

// MARK: - Settings View

struct SettingsView: View {
    // Launch at login state
    @State private var launchAtLogin: Bool = false
    
    // Notification settings
    @AppStorage(AppConstants.Preferences.showNotifications) private var showNotifications = true
    @AppStorage(AppConstants.Preferences.verboseNotifications) private var verboseNotifications = false
    
    @Environment(\.openURL) private var openURL
    
    private let logger = Logger(subsystem: AppConstants.Logging.subsystem, category: AppConstants.Logging.Category.settings)
    
    var body: some View {
        Form {
            // Launch at login toggle
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    handleLaunchAtLoginChange(to: newValue)
                }
            
            // Notification toggles
            Toggle("Show connection/status notifications", isOn: $showNotifications)
                .onChange(of: showNotifications) { _ in requestPermissionsIfNeeded() }
            
            Toggle("Show verbose debug notifications", isOn: $verboseNotifications)
                .help("Detailed technical notifications for troubleshooting")
            
            // System settings links
            GroupBox("System Settings") {
                VStack(alignment: .leading) {
                    Text("Manage notification preferences or Login Items in System Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Button("Open Notification Settings", action: openSystemNotificationSettings)
                            .buttonStyle(.link)
                        Spacer()
                        Button("Open Login Items Settings", action: openLoginItemsSettings)
                            .buttonStyle(.link)
                    }
                }
            }
            
            Spacer()
            
            // Version info at bottom
            HStack { Spacer(); versionLabel; Spacer() }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 280)
        .onAppear {
            // Initialize toggle state from actual system status
            launchAtLogin = LaunchAtLoginManager.shared.isEnabled
            logger.info("Settings view appeared, launch at login status: \(launchAtLogin)")
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var versionLabel: some View {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            Text("DS3 Activator v\(version)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Helper Methods
    
    private func requestPermissionsIfNeeded() {
        guard showNotifications else { return }
        NotificationManager.shared.requestPermissions()
    }
    
    private func handleLaunchAtLoginChange(to enabled: Bool) {
        logger.info("Launch at login toggle changed to: \(enabled)")
        
        // Update the system setting
        let result = LaunchAtLoginManager.shared.setEnabled(enabled)
        
        // Handle the result
        switch result {
        case .success:
            logger.info("Successfully updated launch at login setting")
        case .failure(let error):
            logger.error("Failed to update launch at login: \(error.localizedDescription)")
            
            // Present error and reset toggle state on failure
            presentLaunchAtLoginErrorAlert(error: error)
            
            // Reset toggle to match actual system state (with slight delay to let UI update)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.launchAtLogin = LaunchAtLoginManager.shared.isEnabled
            }
        }
    }
    
    // MARK: - System Settings Links
    
    private func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        openURL(url)
        logger.info("Opened system notification settings")
    }
    
    private func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        openURL(url)
        logger.info("Opened system login items settings")
    }
    
    // MARK: - Error Alert
    
    private func presentLaunchAtLoginErrorAlert(error: Error) {
        logger.error("Presenting launch at login error alert: \(error.localizedDescription)")
        
        let alert = NSAlert()
        alert.messageText = "Launch at Login Error"
        
        // Create a more detailed message based on error type
        var detailedMessage = "Could not change the 'Launch at Login' setting.\n\n"
        
        if let nsError = error as NSError? {
            switch nsError.domain {
            case "com.apple.ServiceManagement":
                if nsError.code == 1 { // Common error for lack of authorization
                    detailedMessage += "This may require system authorization. Please try changing this setting in System Settings > General > Login Items instead."
                } else {
                    detailedMessage += "Error: \(error.localizedDescription)"
                }
            default:
                detailedMessage += "Error: \(error.localizedDescription)"
            }
        } else {
            detailedMessage += "Error: \(error.localizedDescription)"
        }
        
        detailedMessage += "\n\nYou can also manage login items directly in System Settings."
        
        alert.informativeText = detailedMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        
        // Add a button to open System Settings
        alert.addButton(withTitle: "Open System Settings")
        
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            openLoginItemsSettings()
        }
    }
}

// MARK: - SMAppService.Status Extension

extension SMAppService.Status {
    var description: String {
        switch self {
        case .notRegistered: return "Not Registered"
        case .enabled: return "Enabled"
        case .requiresApproval: return "Requires Approval"
        case .notFound: return "Not Found"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - App Entry Point

@main
struct DS3ActivatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    var body: some Scene {
        Settings {
            // An EmptyView is sufficient here since we manage windows manually
            EmptyView()
        }
    }
}
