import AppKit
import OSLog
import SwiftUI

private let overlayLogger = Logger(
  subsystem: "com.zachsents.betterflow",
  category: "Overlay"
)

@MainActor
final class OverlayController {
  private let panel: NSPanel

  init(coordinator: RecognitionCoordinator) {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 604, height: 108),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.contentView = NSHostingView(rootView: DictationOverlayView(coordinator: coordinator))
  }

  func show() {
    let started = ContinuousClock.now
    position()
    panel.contentView?.layoutSubtreeIfNeeded()
    panel.orderFrontRegardless()
    panel.displayIfNeeded()
    overlayLogger.info("Overlay shown elapsedMs=\(started.duration(to: .now).milliseconds)")
  }

  func hide() {
    panel.orderOut(nil)
  }

  private func position() {
    let mouseLocation = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
      ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    let size = panel.frame.size
    panel.setFrameOrigin(
      NSPoint(
        x: frame.midX - size.width / 2,
        y: frame.minY + 72
      )
    )
  }
}

private struct DictationOverlayView: View {
  @ObservedObject var coordinator: RecognitionCoordinator

  var body: some View {
    HStack(spacing: 11) {
      levelIndicator
      transcript
      if coordinator.cleanupEnabled {
        Color.clear.frame(width: 16)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(width: 560)
    .frame(minHeight: 64)
    .background {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(.ultraThinMaterial)
        .opacity(0.66)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(.white.opacity(0.12), lineWidth: 1)
    }
    .overlay(alignment: .bottomTrailing) {
      if coordinator.cleanupEnabled {
        Image(systemName: "wand.and.stars")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.purple)
          .padding(.trailing, 14)
          .padding(.bottom, 10)
          .accessibilityLabel("Transcript cleanup enabled")
      }
    }
    .shadow(color: .black.opacity(0.2), radius: 14, y: 4)
    .padding(22)
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 0) {
          Text(coordinator.transcript)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .leading)

          Color.clear
            .frame(height: 0)
            .id(TranscriptAnchor.bottom)
        }
      }
      .scrollIndicators(.never)
      .frame(height: 36)
      .onAppear {
        proxy.scrollTo(TranscriptAnchor.bottom, anchor: .bottom)
      }
      .onChange(of: coordinator.transcript) {
        proxy.scrollTo(TranscriptAnchor.bottom, anchor: .bottom)
      }
    }
  }

  private var levelIndicator: some View {
    AudioLevelIndicator(meter: coordinator.audioMeter, color: statusColor)
  }

  private var statusColor: Color {
    switch coordinator.state {
    case .listening: .green
    case .preparing: .cyan
    case .finalizing: .indigo
    case .error: .red
    case .idle: .blue
    }
  }

  private enum TranscriptAnchor {
    case bottom
  }
}

private struct AudioLevelIndicator: View {
  @ObservedObject var meter: AudioMeterState
  let color: Color

  var body: some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(0..<4, id: \.self) { index in
        let weight = [0.62, 1.0, 0.82, 0.56][index]
        Capsule()
          .fill(color.gradient)
          .frame(
            width: 3,
            height: 6 + meter.level * 24 * weight
          )
      }
    }
    .frame(width: 20, height: 36)
  }
}
