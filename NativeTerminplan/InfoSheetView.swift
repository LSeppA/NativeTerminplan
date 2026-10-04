import SwiftUI
import WebKit

struct InfoSheetView: View {
    @State var hasAccepted: Bool = false
    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            HTMLWebView(
                resourceName: "Info",
                fileExtension: "html",
                hasAccepted: hasAccepted,
                onAccept: {
                    onAccept?()
                    dismiss()
                },
                onDecline: {
                    onDecline?()
                    dismiss()
                },
                onClose: {
                    dismiss()
                }
            )
                .navigationTitle("Info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if hasAccepted {
                            Button("Fertig") { dismiss() }
                        }
                    }
                }
        }
    }
}

private struct HTMLWebView: UIViewRepresentable {
    let resourceName: String
    let fileExtension: String
    var hasAccepted: Bool = false
    var onAccept: (() -> Void)? = nil
    var onDecline: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onAccept: onAccept, onDecline: onDecline, onClose: onClose) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "accept")
        controller.add(context.coordinator, name: "decline")
        controller.add(context.coordinator, name: "close")
        controller.add(context.coordinator, name: "terms")
        
        if hasAccepted {
            let js = "document.addEventListener('DOMContentLoaded', function(){ var bar=document.getElementById('acceptBar'); if(bar){ bar.style.display='none'; } var lead=document.getElementById('acceptLead'); if(lead){ lead.style.display='none'; } var banner=document.getElementById('infoBanner'); if(banner){ banner.hidden=true; banner.style.display='none'; } });"
            let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            controller.addUserScript(script)
        }
        
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        
        let acceptedJS = "try{ localStorage.setItem('hasAccepted', '" + String(hasAccepted) + "'); }catch(e){}"
        webView.evaluateJavaScript(acceptedJS, completionHandler: nil)
        
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: fileExtension) {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            
            if hasAccepted {
                webView.evaluateJavaScript("(function(){ var bar=document.getElementById('acceptBar'); if(bar){ bar.style.display='none'; } var lead=document.getElementById('acceptLead'); if(lead){ lead.style.display='none'; } var banner=document.getElementById('infoBanner'); if(banner){ banner.hidden=true; banner.style.display='none'; } })();") { _, _ in }
            }
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onAccept: (() -> Void)?
        let onDecline: (() -> Void)?
        let onClose: (() -> Void)?

        init(onAccept: (() -> Void)?, onDecline: (() -> Void)?, onClose: (() -> Void)?) {
            self.onAccept = onAccept
            self.onDecline = onDecline
            self.onClose = onClose
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "accept":
                UserDefaults.standard.set(true, forKey: "hasAcceptedInfo")
                onAccept?()
                onClose?()
            case "decline":
                onDecline?()
                onClose?()
            case "close":
                onClose?()
            case "terms":
                if let decision = message.body as? String {
                    if decision == "accepted" {
                        UserDefaults.standard.set(true, forKey: "hasAcceptedInfo")
                        onAccept?()
                        onClose?()
                    }
                    else if decision == "declined" {
                        onDecline?()
                        onClose?()
                    }
                } else if let dict = message.body as? [String: Any], let decision = dict["decision"] as? String {
                    if decision == "accepted" {
                        UserDefaults.standard.set(true, forKey: "hasAcceptedInfo")
                        onAccept?()
                        onClose?()
                    }
                    else if decision == "declined" {
                        onDecline?()
                        onClose?()
                    }
                }
            default:
                break
            }
        }
    }
}
