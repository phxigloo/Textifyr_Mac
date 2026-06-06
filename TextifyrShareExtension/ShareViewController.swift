import Cocoa
import SwiftUI

final class ShareViewController: NSViewController {

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let item = extensionContext?.inputItems.first as? NSExtensionItem else {
            extensionContext?.cancelRequest(withError: NSError(
                domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            return
        }

        let picker = SharePickerView(extensionItem: item) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }

        let host = NSHostingController(rootView: picker)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        preferredContentSize = NSSize(width: 400, height: 340)
    }
}
