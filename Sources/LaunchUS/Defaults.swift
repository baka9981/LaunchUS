import Foundation

extension UserDefaults {
    /// LaunchUS's own settings. Demo runs (LAUNCHUS_DEMO=1, for website pictures) get a scratch
    /// set, emptied at launch, so their stock-apps-only list never reaches the real one: real
    /// settings would otherwise count every other app as newly installed. CFFIXED_USER_HOME
    /// doesn't help here, since cfprefsd keeps preferences outside the app's home folder.
    static let app: UserDefaults = {
        guard ProcessInfo.processInfo.environment["LAUNCHUS_DEMO"] != nil else { return .standard }
        let name = "local.launchus.LaunchUS.demo"
        let scratch = UserDefaults(suiteName: name) ?? .standard
        scratch.removePersistentDomain(forName: name)
        return scratch
    }()
}
