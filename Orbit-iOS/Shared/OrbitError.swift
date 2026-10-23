import Foundation

/// The error every Orbit network call throws: a sentence the UI can show as is.
///
/// Compiled into the iPhone/iPad app and its extensions (Share, Notification Service) so they can
/// share `OrbitAPIClient`. The Mac and Apple TV apps keep identical copies in `OrbitMacModels.swift`
/// and `OrbitTVViewModel.swift` and do not compile this file.
/// The Swift checks in `Tests/` compile this file next to `OrbitAPIClient.swift`, so keep it free of
/// other app types.
struct OrbitError: LocalizedError {
    let message: String
    /// HTTP status from the PC when the error is a reply (409 = name taken, 401 = token rejected…).
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}
