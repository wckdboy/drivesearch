import AuthenticationServices
import Foundation
import ProviderKit
import UIKit

@MainActor
final class OAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthCoordinator()

    func signIn(kind: ProviderKind, clients: OAuthClientConfig, http: HTTPSending) async throws -> Credentials {
        let pkce = PKCEPair.generate()
        let state = UUID().uuidString
        let provider = Providers.make(kind)
        let url = try provider.authorizationURL(config: clients, challenge: pkce.challenge, state: state)
        let scheme = kind == .googleDrive ? clients.googleURLScheme : "drivesearch"
        let callback = try await authenticate(url: url, scheme: scheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let returnedState = items.first { $0.name == "state" }?.value
        if returnedState != state {
            throw ProviderError.transport("The sign-in response did not match this request.")
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw ProviderError.transport(error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw ProviderError.transport("The provider did not return an authorization code.")
        }
        return try await provider.exchange(code: code, config: clients, verifier: pkce.verifier, http: http)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.flatMap(\.windows).first
        return window ?? ASPresentationAnchor()
    }

    private var session: ASWebAuthenticationSession?

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        let gate = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    gate.resume(continuation, with: .success(callback))
                } else {
                    gate.resume(continuation, with: .failure(error ?? ProviderError.transport("Sign-in was cancelled.")))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                gate.resume(continuation, with: .failure(ProviderError.transport("Could not open the sign-in browser.")))
            }
        }
    }
}

/// ASWebAuthenticationSession can call its handler more than once. Resume the continuation a single time.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<URL, Error>, with result: Result<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(with: result)
    }
}
