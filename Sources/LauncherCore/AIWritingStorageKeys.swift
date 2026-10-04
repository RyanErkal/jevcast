import Foundation

/// Stored names for AI writing. The feature was called "Luna", then "Quill", and these strings keep
/// those old names on purpose: settings, keys, tasks, history, favourites, and pending notifications
/// written by earlier versions keep working with no migration. Do not rename them.
public enum AIWritingStorageKeys {
    // UserDefaults keys.
    public static let enabled = "lunaEnabled"
    public static let effort = "lunaEffort"
    public static let sendsSelection = "lunaSendsSelection"
    public static let sendsMail = "lunaSendsMail"
    public static let sendsCalendar = "lunaSendsCalendar"
    public static let sendsUnreadMail = "lunaSendsUnreadMail"
    public static let sendsDictation = "lunaSendsDictation"
    public static let activity = "lunaActivity"
    public static let tasks = "lunaTasks"
    public static let taskRuns = "lunaTaskRuns"
    /// Settings added while the feature was called "Quill". Stored names; do not rename.
    public static let model = "quillModel"
    public static let fast = "quillFast"

    /// Keychain account for AI writing's own OpenRouter key.
    public static let keychainAccount = "openrouter-luna-key"
    /// Folder in Application Support that holds task results.
    public static let tasksFolder = "Luna Tasks"

    // Launcher row IDs. Favourites, recents, and ranking store them.
    public static let askRowID = "luna:ask"
    public static let selectionRowPrefix = "this:luna:"
    public static let taskRowPrefix = "lunatask:"
    public static let runRowPrefix = "lunarun:"

    // Notification identifiers and user info, so notifications from earlier versions still open.
    public static let notificationThreadPrefix = "luna-task."
    public static let notificationRunPrefix = "luna-run."
    public static let notificationRunKey = "lunaRun"

    /// Suffix on a stored transcript's engine name when AI writing cleaned the text.
    public static let transcriptEngineSuffix = "+luna"
}
