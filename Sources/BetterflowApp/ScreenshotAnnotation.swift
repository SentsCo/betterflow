import AppKit
@preconcurrency import ScreenCaptureKit

private enum ScreenshotTool: Int {
  case pen
  case arrow
  case rectangle
}

private struct ScreenshotAnnotation {
  let tool: ScreenshotTool
  let color: NSColor
  let lineWidth: CGFloat
  var points: [CGPoint]
}

private struct CapturedDisplay {
  let screen: NSScreen
  let image: CGImage
}

@MainActor
private protocol ScreenshotCanvasDelegate: AnyObject {
  var annotationTool: ScreenshotTool { get }
  var annotationColor: NSColor { get }
  func canvasDidBecomeActive(_ canvas: ScreenshotCanvasView)
  func canvasDidFinishSelection(_ canvas: ScreenshotCanvasView, rect: CGRect)
  func cancelScreenshot()
  func undoAnnotation()
  func beginAreaSelection()
  func copyFullDisplay()
  func selectAnnotationTool(_ tool: ScreenshotTool)
}

@MainActor
final class ScreenshotAnnotationController {
  var onCopied: (() -> Void)?
  var onFailure: ((String) -> Void)?

  private(set) var isActive = false
  private var isStarting = false
  private var captureTask: Task<Void, Never>?
  private var canvasWindows: [NSWindow] = []
  private var canvases: [ScreenshotCanvasView] = []
  private var toolbarWindow: NSPanel?
  private var toolControl: NSSegmentedControl?
  private var colorWell: NSColorWell?
  private var activeCanvas: ScreenshotCanvasView?

  fileprivate var annotationTool = ScreenshotTool.pen
  fileprivate var annotationColor: NSColor { colorWell?.color ?? .systemPink }

  func start() {
    guard !isActive, !isStarting else { return }
    isStarting = true
    captureTask = Task { [weak self] in
      guard let self else { return }
      do {
        let displays = try await captureDisplays()
        guard !Task.isCancelled else { return }
        show(displays)
      } catch {
        guard !Task.isCancelled else { return }
        isStarting = false
        onFailure?(error.localizedDescription)
      }
    }
  }

  func cancel() {
    captureTask?.cancel()
    captureTask = nil
    isStarting = false
    isActive = false
    toolbarWindow?.orderOut(nil)
    canvasWindows.forEach { $0.orderOut(nil) }
    toolbarWindow = nil
    canvasWindows = []
    canvases = []
    activeCanvas = nil
  }

  private func captureDisplays() async throws -> [CapturedDisplay] {
    let content = try await SCShareableContent.current
    let screensByID = Dictionary(
      uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
        (screen.displayID).map { ($0, screen) }
      }
    )

    var captures: [CapturedDisplay] = []
    for display in content.displays {
      guard let screen = screensByID[display.displayID] else { continue }
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let configuration = SCStreamConfiguration()
      configuration.width = Int(CGFloat(display.width) * CGFloat(filter.pointPixelScale))
      configuration.height = Int(CGFloat(display.height) * CGFloat(filter.pointPixelScale))
      configuration.captureResolution = .best
      configuration.scalesToFit = true
      configuration.showsCursor = false
      configuration.capturesAudio = false
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
      )
      captures.append(CapturedDisplay(screen: screen, image: image))
    }
    guard !captures.isEmpty else { throw ScreenshotCaptureError.noDisplays }
    return captures
  }

  private func show(_ displays: [CapturedDisplay]) {
    isStarting = false
    isActive = true
    annotationTool = .pen

    for display in displays {
      let canvas = ScreenshotCanvasView(
        frame: CGRect(origin: .zero, size: display.screen.frame.size),
        screenshot: display.image
      )
      canvas.delegate = self
      let window = ScreenshotOverlayWindow(
        contentRect: display.screen.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false,
        screen: display.screen
      )
      window.contentView = canvas
      window.backgroundColor = .black
      window.level = .screenSaver
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      window.isOpaque = true
      window.hasShadow = false
      window.setFrame(display.screen.frame, display: false)
      canvasWindows.append(window)
      canvases.append(canvas)
      window.orderFrontRegardless()
    }

    let initialCanvas = canvas(at: NSEvent.mouseLocation) ?? canvases.first
    activeCanvas = initialCanvas
    showToolbar(on: initialCanvas?.window?.screen ?? NSScreen.main)
    initialCanvas?.window?.makeKey()
    initialCanvas?.window?.makeFirstResponder(initialCanvas)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  private func showToolbar(on screen: NSScreen?) {
    guard let screen else { return }
    let toolbar = makeToolbar()
    let size = NSSize(width: 610, height: 56)
    let origin = NSPoint(
      x: screen.frame.midX - size.width / 2,
      y: screen.frame.minY + 28
    )
    let window = NSPanel(
      contentRect: NSRect(origin: origin, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.contentView = toolbar
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = true
    window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    window.orderFrontRegardless()
    toolbarWindow = window
  }

  private func makeToolbar() -> NSView {
    let background = NSVisualEffectView()
    background.material = .hudWindow
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 14
    background.layer?.masksToBounds = true

    let tools = NSSegmentedControl(
      images: ["pencil.tip", "arrow.up.right", "rectangle"].compactMap {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil)
      },
      trackingMode: .selectOne,
      target: self,
      action: #selector(selectTool(_:))
    )
    tools.selectedSegment = annotationTool.rawValue
    tools.setAccessibilityLabel("Annotation tool")
    toolControl = tools

    let color = NSColorWell()
    color.color = .systemPink
    color.colorWellStyle = .minimal
    color.setAccessibilityLabel("Annotation color")
    colorWell = color

    let undo = toolbarButton(symbol: "arrow.uturn.backward", label: "Undo", action: #selector(undo))
    let clear = toolbarButton(symbol: "trash", label: "Clear", action: #selector(clear))
    let select = NSButton(title: "Select Area", target: self, action: #selector(selectArea))
    select.bezelStyle = .rounded
    select.keyEquivalent = "\r"
    let full = NSButton(title: "Full Screen", target: self, action: #selector(copyScreen))
    full.bezelStyle = .rounded

    let stack = NSStackView(views: [tools, color, divider(), undo, clear, divider(), select, full])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 9),
      stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -9),
    ])
    return background
  }

  private func toolbarButton(symbol: String, label: String, action: Selector) -> NSButton {
    let button = NSButton(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
      target: self,
      action: action
    )
    button.isBordered = false
    button.toolTip = label
    return button
  }

  private func divider() -> NSBox {
    let divider = NSBox()
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    divider.heightAnchor.constraint(equalToConstant: 24).isActive = true
    return divider
  }

  private func canvas(at screenPoint: CGPoint) -> ScreenshotCanvasView? {
    canvases.first { $0.window?.frame.contains(screenPoint) == true }
  }

  @objc private func selectTool(_ sender: NSSegmentedControl) {
    guard let tool = ScreenshotTool(rawValue: sender.selectedSegment) else { return }
    annotationTool = tool
  }

  @objc private func undo() {
    activeCanvas?.undo()
  }

  @objc private func clear() {
    activeCanvas?.clear()
  }

  @objc private func selectArea() {
    beginAreaSelection()
  }

  @objc private func copyScreen() {
    copyFullDisplay()
  }

  private func copy(_ canvas: ScreenshotCanvasView, rect: CGRect) {
    guard let image = canvas.renderedImage(in: rect) else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.writeObjects([image]) else {
      onFailure?("Betterflow could not copy the screenshot to the clipboard.")
      return
    }
    cancel()
    onCopied?()
  }
}

extension ScreenshotAnnotationController: ScreenshotCanvasDelegate {
  fileprivate func canvasDidBecomeActive(_ canvas: ScreenshotCanvasView) {
    guard activeCanvas !== canvas else { return }
    activeCanvas = canvas
    canvas.window?.makeKey()
    canvas.window?.makeFirstResponder(canvas)
    if let screen = canvas.window?.screen, toolbarWindow?.screen != screen {
      toolbarWindow?.orderOut(nil)
      toolbarWindow = nil
      showToolbar(on: screen)
    }
  }

  fileprivate func canvasDidFinishSelection(_ canvas: ScreenshotCanvasView, rect: CGRect) {
    copy(canvas, rect: rect)
  }

  fileprivate func cancelScreenshot() {
    cancel()
  }

  fileprivate func undoAnnotation() {
    activeCanvas?.undo()
  }

  fileprivate func beginAreaSelection() {
    toolbarWindow?.orderOut(nil)
    canvases.forEach { $0.beginSelection() }
    activeCanvas?.window?.makeKey()
    activeCanvas?.window?.makeFirstResponder(activeCanvas)
  }

  fileprivate func copyFullDisplay() {
    guard let canvas = canvas(at: NSEvent.mouseLocation) ?? activeCanvas else { return }
    copy(canvas, rect: canvas.bounds)
  }

  fileprivate func selectAnnotationTool(_ tool: ScreenshotTool) {
    annotationTool = tool
    toolControl?.selectedSegment = tool.rawValue
  }
}

private final class ScreenshotCanvasView: NSView {
  weak var delegate: ScreenshotCanvasDelegate?

  private let screenshot: NSImage
  private var annotations: [ScreenshotAnnotation] = []
  private var draft: ScreenshotAnnotation?
  private var isSelecting = false
  private var selectionStart: CGPoint?
  private var selectionRect = CGRect.zero

  init(frame: NSRect, screenshot: CGImage) {
    self.screenshot = NSImage(cgImage: screenshot, size: frame.size)
    super.init(frame: frame)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    nil
  }

  override var acceptsFirstResponder: Bool { true }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawScene()
    guard isSelecting else { return }

    let shade = NSBezierPath(rect: bounds)
    if !selectionRect.isEmpty { shade.appendRect(selectionRect) }
    shade.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.38).setFill()
    shade.fill()

    guard !selectionRect.isEmpty else { return }
    let border = NSBezierPath(rect: selectionRect)
    border.lineWidth = 1
    border.setLineDash([5, 4], count: 2, phase: 0)
    NSColor.white.setStroke()
    border.stroke()
  }

  override func mouseDown(with event: NSEvent) {
    delegate?.canvasDidBecomeActive(self)
    let point = convert(event.locationInWindow, from: nil)
    if isSelecting {
      selectionStart = point
      selectionRect = CGRect(origin: point, size: .zero)
    } else if let delegate {
      draft = ScreenshotAnnotation(
        tool: delegate.annotationTool,
        color: delegate.annotationColor,
        lineWidth: 4,
        points: [point]
      )
    }
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let selectionStart {
      selectionRect = CGRect(
        x: min(selectionStart.x, point.x),
        y: min(selectionStart.y, point.y),
        width: abs(point.x - selectionStart.x),
        height: abs(point.y - selectionStart.y)
      ).intersection(bounds)
    } else if draft?.tool == .pen {
      draft?.points.append(point)
    } else if let first = draft?.points.first {
      draft?.points = [first, point]
    }
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    mouseDragged(with: event)
    if isSelecting {
      selectionStart = nil
      guard selectionRect.width >= 4, selectionRect.height >= 4 else {
        selectionRect = .zero
        needsDisplay = true
        return
      }
      delegate?.canvasDidFinishSelection(self, rect: selectionRect)
    } else if let draft {
      annotations.append(draft)
      self.draft = nil
      needsDisplay = true
    }
  }

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    switch (event.keyCode, modifiers.contains(.command)) {
    case (53, _): delegate?.cancelScreenshot()
    case (36, true), (76, true): delegate?.copyFullDisplay()
    case (36, false), (76, false): delegate?.beginAreaSelection()
    case (6, true): delegate?.undoAnnotation()
    case (35, false): delegate?.selectAnnotationTool(.pen)
    case (0, false): delegate?.selectAnnotationTool(.arrow)
    case (15, false): delegate?.selectAnnotationTool(.rectangle)
    default: super.keyDown(with: event)
    }
  }

  func undo() {
    if !annotations.isEmpty { annotations.removeLast() }
    needsDisplay = true
  }

  func clear() {
    annotations = []
    draft = nil
    needsDisplay = true
  }

  func beginSelection() {
    isSelecting = true
    selectionStart = nil
    selectionRect = .zero
    needsDisplay = true
  }

  func renderedImage(in rect: CGRect) -> NSImage? {
    let captureRect = rect.standardized.intersection(bounds)
    guard !captureRect.isEmpty else { return nil }
    let scale = window?.backingScaleFactor ?? 2
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int((captureRect.width * scale).rounded()),
        pixelsHigh: Int((captureRect.height * scale).rounded()),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }

    bitmap.size = captureRect.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.translateBy(x: -captureRect.minX, y: -captureRect.minY)
    drawScene()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: captureRect.size)
    image.addRepresentation(bitmap)
    return image
  }

  private func drawScene() {
    screenshot.draw(in: bounds)
    annotations.forEach(draw)
    if let draft { draw(draft) }
  }

  private func draw(_ annotation: ScreenshotAnnotation) {
    guard let first = annotation.points.first else { return }
    annotation.color.setStroke()
    annotation.color.setFill()

    switch annotation.tool {
    case .pen:
      let path = NSBezierPath()
      path.lineWidth = annotation.lineWidth
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      path.move(to: first)
      annotation.points.dropFirst().forEach { path.line(to: $0) }
      path.stroke()
    case .arrow:
      guard let end = annotation.points.last else { return }
      let path = NSBezierPath()
      path.lineWidth = annotation.lineWidth
      path.lineCapStyle = .round
      path.move(to: first)
      path.line(to: end)
      path.stroke()

      let angle = atan2(end.y - first.y, end.x - first.x)
      let headLength = max(12, annotation.lineWidth * 4)
      let head = NSBezierPath()
      head.move(to: end)
      head.line(
        to: CGPoint(
          x: end.x - headLength * cos(angle - .pi / 6),
          y: end.y - headLength * sin(angle - .pi / 6)
        ))
      head.move(to: end)
      head.line(
        to: CGPoint(
          x: end.x - headLength * cos(angle + .pi / 6),
          y: end.y - headLength * sin(angle + .pi / 6)
        ))
      head.lineWidth = annotation.lineWidth
      head.lineCapStyle = .round
      head.stroke()
    case .rectangle:
      guard let end = annotation.points.last else { return }
      let rect = CGRect(
        x: min(first.x, end.x),
        y: min(first.y, end.y),
        width: abs(end.x - first.x),
        height: abs(end.y - first.y)
      )
      let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
      path.lineWidth = annotation.lineWidth
      path.stroke()
    }
  }
}

private final class ScreenshotOverlayWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

extension NSScreen {
  fileprivate var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
      .map { CGDirectDisplayID($0.uint32Value) }
  }
}

private enum ScreenshotCaptureError: LocalizedError {
  case noDisplays

  var errorDescription: String? {
    "Betterflow could not find a display to capture."
  }
}
