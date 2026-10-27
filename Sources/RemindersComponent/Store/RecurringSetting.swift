import AppCore
import Foundation

extension AppSettings {
    static let allowCompletingRecurringKey = "AllowCompletingRecurringReminders"

    /// Whether tools may check off a repeating reminder (Reminders then keeps a completed copy and
    /// moves the reminder to its next date). On unless the user turned it off.
    static var allowCompletingRecurring: Bool {
        // Another process (the settings window) may have changed it since this one started.
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        return UserDefaults.standard.object(forKey: allowCompletingRecurringKey) as? Bool ?? true
    }

    static func setAllowCompletingRecurring(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: allowCompletingRecurringKey)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }
}
