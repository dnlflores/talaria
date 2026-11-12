import AuthenticationServices
import HermesKit
import UIKit

/// Signs in to Hermes on the Mac with its native-app sign-in (RFC 8252): the system sign-in sheet
/// opens Hermes' authorization page, which sends the person through the sign-in provider set up on
/// the Mac (their Nous account), and comes back to a one-request listener on 127.0.0.1 with a
/// one-time code. The code and the PKCE verifier are traded for tokens, which `HermesHTTP` keeps.
@MainActor
final class SignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
  /// Where the loopback listener sends the browser once it has the code; it closes the sheet.
  static let returnScheme = "talaria-auth"

  private var session: ASWebAuthenticationSession?

  func run(http: HermesHTTP) async throws {
    let authorization = NativeAuthorization()
    let loopback = try LoopbackRedirect(returnURL: "\(Self.returnScheme)://signed-in")
    let redirect = try await loopback.start()
    let session = ASWebAuthenticationSession(
      url: http.authorizeURL(authorization, redirectURI: redirect), callbackURLScheme: Self.returnScheme
    ) { _, error in
      // Closed before the code came back (or it failed): stop waiting. After the code, a no-op.
      guard let error else { return }
      let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
      loopback.cancel(cancelled ? HermesError.signInCancelled : HermesError.signInFailed(error.localizedDescription))
    }
    session.presentationContextProvider = self
    // Shares Safari's cookies, so a Nous account already signed in there needs no typing.
    session.prefersEphemeralWebBrowserSession = false
    self.session = session
    defer { self.session = nil }
    guard session.start() else {
      loopback.cancel(HermesError.signInFailed("the sign-in sheet did not open"))
      throw HermesError.signInFailed("the sign-in sheet did not open")
    }
    let code: String
    do {
      code = try await loopback.code(expectedState: authorization.state)
    } catch {
      session.cancel()
      throw error
    }
    try await http.completeSignIn(code: code, verifier: authorization.verifier)
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
  }
}
