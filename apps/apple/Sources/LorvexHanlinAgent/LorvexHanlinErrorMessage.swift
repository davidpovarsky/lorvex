import Foundation
import HanlinChatCore

/// Localized presentation of the shared SDK's typed failures. Diagnostic fields
/// are bounded identifiers; response bodies and credentials never enter this text.
public enum LorvexHanlinErrorMessage {
  public static func description(for error: Error) -> String {
    if let error = error as? HanlinChatGPTPlanError {
      switch error {
      case .invalidRedirect, .invalidToken, .invalidIdentity:
        return String(localized: "Secure ChatGPT sign-in could not be verified. Please try again.")
      case .denied:
        return String(localized: "ChatGPT sign-in was declined.")
      case .invalidAuthorization:
        return String(localized: "ChatGPT authorization is incomplete or expired. Sign in again.")
      case .unavailable:
        return String(localized: "Connect ChatGPT and choose an available model.")
      case .server(let status):
        return response(status: status, code: nil, requestID: nil)
      case .oauth(let status, let code, let requestID):
        return response(status: status, code: code, requestID: requestID)
      @unknown default:
        return String(localized: "ChatGPT could not complete the request. Please try again.")
      }
    }
    if let error = error as? HanlinChatGPTPlanTransportError {
      switch error {
      case .invalidRoute, .invalidBody:
        return String(localized: "ChatGPT could not process this request. Please try again.")
      case .unsupportedTool:
        return String(localized: "This action is unavailable with this ChatGPT model.")
      case .response(let failure):
        return response(status: failure.status, code: failure.code, requestID: failure.requestID)
      case .incompleteStream:
        return String(localized: "The ChatGPT response was interrupted. Please try again.")
      @unknown default:
        return String(localized: "ChatGPT could not complete the request. Please try again.")
      }
    }
    if let error = error as? URLError {
      switch error.code {
      case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
           .cannotConnectToHost, .dnsLookupFailed:
        return String(localized: "Unable to connect. Check your internet connection and try again.")
      case .timedOut:
        return String(localized: "The request timed out. Please try again.")
      default: break
      }
    }
    if (error as NSError).domain == NSOSStatusErrorDomain {
      return String(localized: "Secure storage is unavailable. Unlock the device and try again.")
    }
    return String(localized: String.LocalizationValue(error.localizedDescription))
  }

  private static func response(status: Int, code: String?, requestID: String?) -> String {
    let message: String
    switch status {
    case 401:
      message = String(localized: "ChatGPT authorization is incomplete or expired. Sign in again.")
    case 403:
      message = String(localized: "This ChatGPT account has not granted access. Check its plan permissions.")
    case 429:
      message = String(localized: "ChatGPT is temporarily limiting requests. Try again shortly.")
    default:
      message = String(localized: "ChatGPT could not complete the request. Please try again.")
    }
    var diagnostics = ["HTTP " + String(status)]
    if let code = identifier(code) {
      diagnostics.append(String(localized: "Error code") + ": " + code)
    }
    if let requestID = identifier(requestID) {
      diagnostics.append(String(localized: "Request ID") + ": " + requestID)
    }
    return message + " (" + diagnostics.joined(separator: "; ") + ")"
  }

  private static func identifier(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.count <= 128,
          value.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)
          }) else { return nil }
    return value
  }
}
