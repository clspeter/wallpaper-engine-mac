//
//  WebWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Toby on 2023/8/28.
//

import WebKit
import SwiftUI
import Combine

class WebWallpaperViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    var currentWallpaper: WEWallpaper

    /// The WKWebView this VM drives — set by WebWallpaperView once created. Web wallpapers
    /// play audio through WebKit (HTML5 <video>/<audio>, WebAudio, or cross-origin YouTube/
    /// Vimeo iframes), none of which the AVPlayer-based volume control can reach; muting has
    /// to happen at the WebKit page level instead.
    weak var webView: WKWebView?
    private var isMuted = false
    private var cancellables = Set<AnyCancellable>()

    var fileUrl: URL {
        currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file)
    }

    var readAccessURL: URL {
        currentWallpaper.wallpaperDirectory
    }

    init(wallpaper: WEWallpaper) {
        self.currentWallpaper = wallpaper
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)

        // Mirror the shared volume/mute state (menu-bar Mute, per-wallpaper toggle) onto the
        // web page. Web wallpapers only support binary mute, so any volume of 0 == muted.
        self.isMuted = AppDelegate.shared.wallpaperViewModel.playVolume == 0
        AppDelegate.shared.wallpaperViewModel.$playVolume
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume in
                self?.setMuted(volume == 0)
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Mute/unmute the whole page. Uses WebKit's page-level mute (which also silences
    /// cross-origin iframes and WebAudio) when available, falling back to muting same-origin
    /// media elements directly.
    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyMute()
    }

    /// Re-apply the current mute state to the live webView. Call after (re)assigning `webView`
    /// or finishing a navigation, since a freshly loaded page starts unmuted.
    func applyMute() {
        guard let webView else { return }
        let sel = NSSelectorFromString("_setPageMuted:")
        if webView.responds(to: sel) {
            // _WKMediaMutedState bitmask: audio muted = 1 << 0.
            typealias SetPageMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
            let imp = webView.method(for: sel)
            let fn = unsafeBitCast(imp, to: SetPageMuted.self)
            fn(webView, sel, isMuted ? 1 : 0)
        } else {
            // Fallback: reachable (same-origin) media only.
            let js = "document.querySelectorAll('video,audio').forEach(function(e){e.muted=\(isMuted)});"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow navigation to external URLs (e.g. YouTube embeds from URL-based web wallpapers)
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let javascriptStyle = "var css = '*{-webkit-touch-callout:none;-webkit-user-select:none}'; var head = document.head || document.getElementsByTagName('head')[0]; var style = document.createElement('style'); style.type = 'text/css'; style.appendChild(document.createTextNode(css)); head.appendChild(style);"
        webView.evaluateJavaScript(javascriptStyle, completionHandler: nil)

        // A freshly loaded page starts unmuted — re-apply the current mute state.
        applyMute()
        
        if AppDelegate.shared.globalSettingsViewModel.settings.adjustMenuBarTint {
            webView.takeSnapshot(with: nil) { [weak self] nsImage, error in
                guard let self = self else { return }
                if let data = nsImage?.tiffRepresentation {
                    do {
                        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "staticWP_\(self.currentWallpaper.wallpaperDirectory.hashValue).tiff")
                        try data.write(to: url, options: .atomic)
                        try NSWorkspace.shared.setDesktopImageURL(url, for: .main!)
                    } catch {
                        print(error)
                    }
                }
            }
        }
    }
    
    @objc func systemWillSleep(_ notification: Notification) {
        // Handle going to sleep
        print("System is going to sleep")
        // Update your SwiftUI state here if needed
    }
        
    @objc func systemDidWake(_ notification: Notification) {
        // Handle waking up
        print("System woke up from sleep")
        // Update your SwiftUI state here if needed
    }
}
