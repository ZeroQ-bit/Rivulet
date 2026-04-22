//
//  PreviewContainerViewController.swift
//  Rivulet
//
//  UIViewController wrapper for the preview carousel overlay.
//  Intercepts Menu button to support custom back navigation
//  (expanded → carousel → dismiss) and blocks sidebar access
//  via .overFullScreen modal presentation.
//

import SwiftUI
import UIKit

class PreviewContainerViewController: UIViewController {

    private var hostingController: UIHostingController<AnyView>?
    private var menuHandler: (() -> Void)?
    private var isHandlingMenuPress = false

    /// Callback when the preview is fully dismissed
    var onDismiss: (() -> Void)?

    init<Content: View>(content: Content, menuHandler: @escaping () -> Void) {
        self.menuHandler = menuHandler
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .overFullScreen

        let hosting = UIHostingController(rootView: AnyView(content))
        hosting.view.backgroundColor = .clear
        self.hostingController = hosting
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        if let hosting = hostingController {
            addChild(hosting)
            view.addSubview(hosting.view)
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            hosting.didMove(toParent: self)
        }
    }

    // MARK: - Menu Button Interception

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu {
                isHandlingMenuPress = true
                menuHandler?()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu && isHandlingMenuPress {
                isHandlingMenuPress = false
                return
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if press.type == .menu && isHandlingMenuPress {
                isHandlingMenuPress = false
                return
            }
        }
        super.pressesCancelled(presses, with: event)
    }

    /// Block system-initiated dismissals (Menu button propagation).
    /// Only dismissPreview() should actually dismiss — unless a child VC
    /// (e.g. the player) is presented on top and needs to dismiss itself.
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        if presentedViewController != nil {
            // A child VC (player) is presented on top — let it dismiss normally
            super.dismiss(animated: flag, completion: completion)
        }
        // Otherwise block — we handle our own dismissal via dismissPreview()
    }

    /// Explicitly dismiss the preview overlay
    func dismissPreview() {
        super.dismiss(animated: false) { [weak self] in
            self?.onDismiss?()
        }
    }
}
