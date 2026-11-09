import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// iOS-only modifiers, wrapped so that the views also compile for macOS
// (used to type-check the app with the command-line tools).
extension View {
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Text field for a web address: no capitalization or autocorrection.
    func domainInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .submitLabel(.done)
        #else
        autocorrectionDisabled()
        #endif
    }

    /// Text editor for filter rules.
    func codeInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
        #else
        autocorrectionDisabled()
        #endif
    }
}

/// Opens Safari's extension settings (iOS 26.2+) or, on older versions,
/// the Settings app.
struct OpenSettingsButton: View {
    @Environment(\.openURL) private var openURL

    private var title: String {
        #if os(iOS)
        if #available(iOS 26.2, *) {
            return "Apri le impostazioni di Safari"
        }
        return "Apri Impostazioni"
        #else
        return "Apri le impostazioni di Safari"
        #endif
    }

    var body: some View {
        Button {
            Task {
                guard await !SafariBridge.openExtensionSettings() else { return }
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
                #endif
            }
        } label: {
            Label(title, systemImage: "gearshape")
        }
    }
}
