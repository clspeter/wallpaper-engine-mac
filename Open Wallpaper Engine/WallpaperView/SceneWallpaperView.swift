//
//  SceneWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import Cocoa
import SwiftUI
import SpriteKit

struct SceneWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject var viewModel: SceneWallpaperViewModel
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        self._viewModel = StateObject(wrappedValue: SceneWallpaperViewModel(wallpaper: wallpaperViewModel.wallpaper(for: screenId)))
    }

    func makeNSView(context: Context) -> SKView {
        let skView = SKView(frame: .zero)
        skView.ignoresSiblingOrder = true
        skView.allowsTransparency = false
        skView.preferredFramesPerSecond = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)

        if let scene = viewModel.skScene {
            skView.presentScene(scene)
        }

        // Test hook: when OWE_DUMP_SCENE is set to a file path, offscreen-render
        // the presented scene to a PNG there via the view's own Metal context.
        // This lets a headless/CI/background session visually verify scene
        // rendering without Screen Recording (TCC) permission, which screencapture
        // requires and which such sessions can't grant. Unset in normal use → no-op.
        // OWE_DUMP_SCENE_DELAY (seconds, default 4) tunes warm-up before capture.
        if let dumpPath = ProcessInfo.processInfo.environment["OWE_DUMP_SCENE"] {
            let delay = Double(ProcessInfo.processInfo.environment["OWE_DUMP_SCENE_DELAY"] ?? "") ?? 4.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let scene = skView.scene else { NSLog("[DUMP] no scene presented"); return }
                guard let tex = skView.texture(from: scene) else { NSLog("[DUMP] texture(from:) returned nil"); return }
                let rep = NSBitmapImageRep(cgImage: tex.cgImage())
                guard let png = rep.representation(using: .png, properties: [:]) else { NSLog("[DUMP] PNG encode failed"); return }
                do {
                    try png.write(to: URL(fileURLWithPath: dumpPath))
                    NSLog("[DUMP] wrote %@ (%dx%d)", dumpPath, rep.pixelsWide, rep.pixelsHigh)
                } catch {
                    NSLog("[DUMP] write failed: %@", error.localizedDescription)
                }
            }
        }

        return skView
    }

    func updateNSView(_ skView: SKView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let currentWallpaper = viewModel.currentWallpaper

        // Update scene if wallpaper changed
        if selectedWallpaper.wallpaperDirectory.appending(path: selectedWallpaper.project.file)
            != currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file) {
            viewModel.currentWallpaper = selectedWallpaper
        }

        // Present scene if available and not already presented
        if let scene = viewModel.skScene, skView.scene !== scene {
            skView.presentScene(scene)
        }

        // Update FPS
        skView.preferredFramesPerSecond = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)

        // Pause/resume based on play rate
        skView.isPaused = wallpaperViewModel.playRate == 0
    }
}
