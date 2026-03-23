import Combine
import Foundation

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var addressBar: String = ""
    @Published var pageTitle: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var estimatedProgress: Double = 0
    @Published var locationDisplay: String = BrowserNavigationSnapshot.blank.locationDisplay

    private let addressResolver: AddressResolving
    private weak var navigationDriver: BrowserNavigationDriver?

    init(addressResolver: AddressResolving = DefaultAddressResolver()) {
        self.addressResolver = addressResolver
    }

    func attachNavigationDriver(_ driver: BrowserNavigationDriver) {
        navigationDriver = driver
    }

    func detachNavigationDriver() {
        navigationDriver = nil
    }

    func submitAddress() {
        let raw = addressBar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = addressResolver.resolvedURL(forUserInput: raw) else { return }
        navigationDriver?.load(url: url)
    }

    func goBack() { navigationDriver?.goBack() }
    func goForward() { navigationDriver?.goForward() }

    func reloadOrStop() {
        if isLoading {
            navigationDriver?.stopLoading()
        } else {
            navigationDriver?.reload()
        }
    }

    func syncAddressBarFromWebIfNeeded(addressFieldFocused: Bool) {
        guard !addressFieldFocused else { return }
        let u = locationDisplay
        guard u != "about:blank", !u.isEmpty else { return }
        addressBar = u
    }

    private func applySnapshot(_ snapshot: BrowserNavigationSnapshot) {
        locationDisplay = snapshot.locationDisplay
        pageTitle = snapshot.pageTitle
        canGoBack = snapshot.canGoBack
        canGoForward = snapshot.canGoForward
    }
}

extension BrowserViewModel: BrowserWebEventSink {
    func handleLoadStarted() {
        isLoading = true
    }

    func handleLoadCommitted(snapshot: BrowserNavigationSnapshot) {
        applySnapshot(snapshot)
    }

    func handleLoadFinished(snapshot: BrowserNavigationSnapshot) {
        isLoading = false
        applySnapshot(snapshot)
    }

    func handleLoadFailed(snapshot: BrowserNavigationSnapshot) {
        isLoading = false
        applySnapshot(snapshot)
    }

    func handleEstimatedProgress(_ value: Double) {
        estimatedProgress = value
    }
}
