import Foundation
import ScudoShared

/// Hands Safari the rules prepared by the app.
///
/// The same source is compiled into the four content blocker extensions;
/// each one learns which rules file to serve from its Info.plist
/// (`ScudoBlockerKind`). Deliberately tiny: content blocker extensions run
/// with a very small memory budget, so nothing is parsed here — Safari
/// receives the file as is.
final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        guard let url = BlockerListLocator.rulesURL(bundle: .main),
              let attachment = NSItemProvider(contentsOf: url)
        else {
            context.cancelRequest(withError: NSError(
                domain: "Scudo.ContentBlocker",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Regole non trovate"]
            ))
            return
        }
        let item = NSExtensionItem()
        item.attachments = [attachment]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
