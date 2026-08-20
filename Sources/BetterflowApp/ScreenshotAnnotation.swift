import AppKit
@preconcurrency import ScreenCaptureKit

private enum ScreenshotTool: Int {
  case pen
  case arrow
  case rectangle
  case comment
}

private struct ScreenshotAnnotation {
  let tool: ScreenshotTool
  let color: NSColor
  let lineWidth: CGFloat
  var points: [CGPoint]
  var text = ""
  var targetRect: CGRect?
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
    let size = NSSize(width: 650, height: 56)
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
      images: ["pencil.tip", "arrow.up.right", "rectangle", "text.bubble"].compactMap {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil)
      },
      trackingMode: .selectOne,
      target: self,
      action: #selector(selectTool(_:))
    )
    tools.selectedSegment = annotationTool.rawValue
    tools.setAccessibilityLabel("Annotation tool")
    ["Pen (P)", "Arrow (A)", "Rectangle (R)", "Comment (T)"].enumerated().forEach {
      tools.setToolTip($0.element, forSegment: $0.offset)
    }
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
    selectAnnotationTool(tool)
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
    activeCanvas?.finishTextEditing()
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
    activeCanvas?.finishTextEditing()
    annotationTool = tool
    toolControl?.selectedSegment = tool.rawValue
  }
}

private final class ScreenshotCanvasView: NSView, NSTextViewDelegate {
  weak var delegate: ScreenshotCanvasDelegate?

  private let screenshot: NSImage
  private let usesLightCommentBubble: Bool
  private var annotations: [ScreenshotAnnotation] = []
  private var draft: ScreenshotAnnotation?
  private var editingCommentIndex: Int?
  private var editingCommentOriginalAnnotation: ScreenshotAnnotation?
  private var editingCommentIsNew = false
  private var commentEditor: ScreenshotCommentTextView?
  private var draggedCommentIndex: Int?
  private var commentDragOffset = CGPoint.zero
  private var commentPressPoint: CGPoint?
  private var didDragComment = false
  private var isSelecting = false
  private var selectionStart: CGPoint?
  private var selectionRect = CGRect.zero

  init(frame: NSRect, screenshot: CGImage) {
    self.screenshot = NSImage(cgImage: screenshot, size: frame.size)
    usesLightCommentBubble = screenshotIsMostlyDark(screenshot)
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
      finishTextEditing()
      selectionStart = point
      selectionRect = CGRect(origin: point, size: .zero)
    } else if let delegate, delegate.annotationTool == .comment {
      beginComment(at: point, color: delegate.annotationColor)
    } else if let delegate {
      finishTextEditing()
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
    } else if let draggedCommentIndex,
      annotations.indices.contains(draggedCommentIndex)
    {
      if let commentPressPoint,
        hypot(point.x - commentPressPoint.x, point.y - commentPressPoint.y) >= 3
      {
        didDragComment = true
      }
      if didDragComment {
        let annotation = annotations[draggedCommentIndex]
        let requestedCenter = CGPoint(
          x: point.x - commentDragOffset.x,
          y: point.y - commentDragOffset.y
        )
        annotations[draggedCommentIndex].points[1] = constrainedCommentCenter(
          requestedCenter,
          text: annotation.text
        )
      }
    } else if draft?.tool == .comment, let start = draft?.points.first {
      let targetRect = CGRect(
        x: min(start.x, point.x),
        y: min(start.y, point.y),
        width: abs(point.x - start.x),
        height: abs(point.y - start.y)
      ).intersection(bounds)
      let commentText = draft?.text ?? ""
      draft?.targetRect = targetRect
      draft?.points[1] = constrainedCommentCenter(
        CGPoint(x: targetRect.maxX + 148, y: targetRect.maxY + 48),
        text: commentText
      )
    } else if draft?.tool == .pen {
      draft?.points.append(point)
    } else if let first = draft?.points.first {
      draft?.points = [first, point]
    }
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    mouseDragged(with: event)
    let clickedCommentIndex = didDragComment ? nil : draggedCommentIndex
    draggedCommentIndex = nil
    commentPressPoint = nil
    didDragComment = false
    if isSelecting {
      selectionStart = nil
      guard selectionRect.width >= 4, selectionRect.height >= 4 else {
        selectionRect = .zero
        needsDisplay = true
        return
      }
      delegate?.canvasDidFinishSelection(self, rect: selectionRect)
    } else if var draft {
      if draft.tool == .comment,
        let targetRect = draft.targetRect,
        targetRect.width < 4 || targetRect.height < 4
      {
        draft.targetRect = nil
      }
      annotations.append(draft)
      self.draft = nil
      if draft.tool == .comment { startTextEditing(at: annotations.count - 1, isNew: true) }
      needsDisplay = true
    } else if let clickedCommentIndex {
      startTextEditing(at: clickedCommentIndex)
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
    case (17, false): delegate?.selectAnnotationTool(.comment)
    default: super.keyDown(with: event)
    }
  }

  func undo() {
    finishTextEditing()
    if !annotations.isEmpty { annotations.removeLast() }
    needsDisplay = true
  }

  func clear() {
    discardCommentEditor()
    annotations = []
    draft = nil
    needsDisplay = true
  }

  func beginSelection() {
    finishTextEditing()
    isSelecting = true
    selectionStart = nil
    selectionRect = .zero
    needsDisplay = true
  }

  func renderedImage(in rect: CGRect) -> NSImage? {
    finishTextEditing()
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

  func finishTextEditing() {
    guard let index = editingCommentIndex, annotations.indices.contains(index) else {
      discardCommentEditor()
      return
    }
    annotations[index].text = commentEditor?.string ?? annotations[index].text
    let isEmpty = annotations[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    discardCommentEditor()
    if isEmpty { annotations.remove(at: index) }
    needsDisplay = true
  }

  func cancelTextEditing() {
    guard let index = editingCommentIndex, annotations.indices.contains(index) else {
      discardCommentEditor()
      return
    }
    let originalAnnotation = editingCommentOriginalAnnotation ?? annotations[index]
    let removesComment = editingCommentIsNew
    discardCommentEditor()
    if removesComment {
      annotations.remove(at: index)
    } else {
      annotations[index] = originalAnnotation
    }
    needsDisplay = true
  }

  func textDidChange(_ notification: Notification) {
    guard let editor = notification.object as? NSTextView,
      editor === commentEditor,
      let index = editingCommentIndex,
      annotations.indices.contains(index)
    else { return }
    annotations[index].text = editor.string
    annotations[index].points[1] = constrainedCommentCenter(
      annotations[index].points[1],
      text: editor.string
    )
    updateCommentEditorFrame()
    needsDisplay = true
  }

  private func beginComment(at point: CGPoint, color: NSColor) {
    if let editingCommentIndex,
      annotations.indices.contains(editingCommentIndex),
      !commentRect(for: annotations[editingCommentIndex]).contains(point)
    {
      finishTextEditing()
      return
    }
    finishTextEditing()
    if let index = annotations.indices.reversed().first(where: {
      annotations[$0].tool == .comment && commentRect(for: annotations[$0]).contains(point)
    }) {
      let center = annotations[index].points[1]
      draggedCommentIndex = index
      commentDragOffset = CGPoint(x: point.x - center.x, y: point.y - center.y)
      commentPressPoint = point
      didDragComment = false
      return
    }

    draft = ScreenshotAnnotation(
      tool: .comment,
      color: color,
      lineWidth: 3,
      points: [
        point,
        constrainedCommentCenter(
          CGPoint(x: point.x + 160, y: point.y + 72),
          text: ""
        ),
      ]
    )
    needsDisplay = true
  }

  private func startTextEditing(at index: Int, isNew: Bool = false) {
    guard annotations.indices.contains(index) else { return }
    editingCommentIndex = index
    editingCommentOriginalAnnotation = annotations[index]
    editingCommentIsNew = isNew
    let editor = ScreenshotCommentTextView(frame: .zero)
    editor.delegate = self
    editor.string = annotations[index].text
    editor.font = commentFont
    editor.textColor = commentTextColor
    editor.drawsBackground = false
    editor.isRichText = false
    editor.importsGraphics = false
    editor.isHorizontallyResizable = false
    editor.isVerticallyResizable = false
    editor.textContainerInset = .zero
    editor.textContainer?.lineFragmentPadding = 0
    editor.textContainer?.widthTracksTextView = true
    editor.wantsLayer = true
    editor.layer?.masksToBounds = true
    editor.onCommandReturn = { [weak self] in self?.delegate?.copyFullDisplay() }
    editor.onCommit = { [weak self] in self?.finishTextEditing() }
    editor.onCancel = { [weak self] in self?.cancelTextEditing() }
    commentEditor = editor
    addSubview(editor)
    updateCommentEditorFrame()
    window?.makeFirstResponder(editor)
    needsDisplay = true
  }

  private func discardCommentEditor() {
    commentEditor?.delegate = nil
    commentEditor?.removeFromSuperview()
    commentEditor = nil
    editingCommentIndex = nil
    editingCommentOriginalAnnotation = nil
    editingCommentIsNew = false
    draggedCommentIndex = nil
    commentPressPoint = nil
    didDragComment = false
    window?.makeFirstResponder(self)
  }

  private func updateCommentEditorFrame() {
    guard let index = editingCommentIndex,
      annotations.indices.contains(index),
      let commentEditor
    else { return }
    let rect = commentRect(for: annotations[index])
    commentEditor.frame = CGRect(
      x: rect.minX + 12,
      y: rect.minY + 9,
      width: rect.width - 24,
      height: rect.height - 18
    )
  }

  private func commentRect(for annotation: ScreenshotAnnotation) -> CGRect {
    guard annotation.points.count >= 2 else { return .zero }
    let size = commentSize(for: annotation.text)
    return CGRect(
      x: annotation.points[1].x - size.width / 2,
      y: annotation.points[1].y - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  private func commentSize(for text: String) -> CGSize {
    let width: CGFloat = 240
    let measured = (text.isEmpty ? "Comment" : text as NSString).boundingRect(
      with: CGSize(width: width - 24, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: commentFont]
    )
    return CGSize(
      width: width,
      height: min(max(64, ceil(measured.height) + 36), max(64, min(220, bounds.height - 24)))
    )
  }

  private func constrainedCommentCenter(_ center: CGPoint, text: String) -> CGPoint {
    let size = commentSize(for: text)
    return CGPoint(
      x: min(max(center.x, bounds.minX + size.width / 2 + 12), bounds.maxX - size.width / 2 - 12),
      y: min(max(center.y, bounds.minY + size.height / 2 + 12), bounds.maxY - size.height / 2 - 12)
    )
  }

  private func drawScene() {
    screenshot.draw(in: bounds)
    annotations.enumerated().forEach { index, annotation in
      draw(annotation, drawsCommentText: index != editingCommentIndex)
    }
    if let draft { draw(draft) }
  }

  private func draw(_ annotation: ScreenshotAnnotation, drawsCommentText: Bool = true) {
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
    case .comment:
      drawComment(annotation, drawsText: drawsCommentText)
    }
  }

  private func drawComment(_ annotation: ScreenshotAnnotation, drawsText: Bool) {
    guard annotation.points.count >= 2 else { return }
    let bubbleRect = commentRect(for: annotation)
    let bubbleCenter = annotation.points[1]
    let targetRect = annotation.targetRect?.standardized
    let anchor = targetRect.map { pointOnRectBoundary($0, toward: bubbleCenter) }
      ?? annotation.points[0]

    if let targetRect, targetRect.width >= 4, targetRect.height >= 4 {
      let target = NSBezierPath(roundedRect: targetRect, xRadius: 5, yRadius: 5)
      target.lineWidth = annotation.lineWidth
      annotation.color.setStroke()
      target.stroke()
    }

    if !bubbleRect.insetBy(dx: -4, dy: -4).contains(anchor) {
      let lineStart = pointOnRectBoundary(bubbleRect, toward: anchor)
      let line = NSBezierPath()
      line.move(to: lineStart)
      line.line(to: anchor)
      line.lineWidth = annotation.lineWidth
      line.lineCapStyle = .round
      annotation.color.setStroke()
      line.stroke()

      let angle = atan2(anchor.y - lineStart.y, anchor.x - lineStart.x)
      let headLength = max(11, annotation.lineWidth * 4)
      let head = NSBezierPath()
      head.move(to: anchor)
      head.line(
        to: CGPoint(
          x: anchor.x - headLength * cos(angle - .pi / 6),
          y: anchor.y - headLength * sin(angle - .pi / 6)
        ))
      head.move(to: anchor)
      head.line(
        to: CGPoint(
          x: anchor.x - headLength * cos(angle + .pi / 6),
          y: anchor.y - headLength * sin(angle + .pi / 6)
        ))
      head.lineWidth = annotation.lineWidth
      head.lineCapStyle = .round
      head.stroke()
    }

    let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 13, yRadius: 13)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = 9
    shadow.shadowOffset = CGSize(width: 0, height: -2)
    shadow.set()
    commentBubbleColor.setFill()
    bubble.fill()
    NSGraphicsContext.restoreGraphicsState()
    annotation.color.setStroke()
    bubble.lineWidth = 2
    bubble.stroke()

    if drawsText {
      (annotation.text as NSString).draw(
        in: bubbleRect.insetBy(dx: 12, dy: 10),
        withAttributes: [
          .font: commentFont,
          .foregroundColor: commentTextColor,
        ]
      )
    }
  }

  private func pointOnRectBoundary(_ rect: CGRect, toward target: CGPoint) -> CGPoint {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let delta = CGPoint(x: target.x - center.x, y: target.y - center.y)
    guard delta.x != 0 || delta.y != 0 else { return center }
    let xScale = delta.x == 0 ? CGFloat.greatestFiniteMagnitude : rect.width / 2 / abs(delta.x)
    let yScale = delta.y == 0 ? CGFloat.greatestFiniteMagnitude : rect.height / 2 / abs(delta.y)
    let scale = min(xScale, yScale)
    return CGPoint(x: center.x + delta.x * scale, y: center.y + delta.y * scale)
  }

  private var commentFont: NSFont {
    NSFont.systemFont(ofSize: 15, weight: .medium)
  }

  private var commentBubbleColor: NSColor {
    usesLightCommentBubble
      ? NSColor(calibratedWhite: 0.96, alpha: 0.96)
      : NSColor(calibratedWhite: 0.10, alpha: 0.95)
  }

  private var commentTextColor: NSColor {
    usesLightCommentBubble ? .black.withAlphaComponent(0.86) : .white
  }
}

private final class ScreenshotCommentTextView: NSTextView {
  var onCommandReturn: (() -> Void)?
  var onCommit: (() -> Void)?
  var onCancel: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 53 {
      onCancel?()
    } else if (event.keyCode == 36 || event.keyCode == 76), modifiers.contains(.command) {
      onCommandReturn?()
    } else if event.keyCode == 36 || event.keyCode == 76 {
      if modifiers.contains(.shift) {
        super.keyDown(with: event)
      } else {
        onCommit?()
      }
    } else {
      super.keyDown(with: event)
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

func screenshotIsMostlyDark(_ image: CGImage) -> Bool {
  let sampleWidth = 48
  let sampleHeight = 48
  let bytesPerPixel = 4
  let bytesPerRow = sampleWidth * bytesPerPixel
  var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
  let rendered = pixels.withUnsafeMutableBytes { bytes in
    guard let context = CGContext(
      data: bytes.baseAddress,
      width: sampleWidth,
      height: sampleHeight,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    ) else { return false }
    context.interpolationQuality = .low
    context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
    return true
  }
  guard rendered else { return false }

  let darkPixelCount = stride(from: 0, to: pixels.count, by: bytesPerPixel).reduce(0) {
    count, index in
    let luminance = 0.2126 * Double(pixels[index])
      + 0.7152 * Double(pixels[index + 1])
      + 0.0722 * Double(pixels[index + 2])
    return count + (luminance < 0.52 * 255 ? 1 : 0)
  }
  return darkPixelCount * 2 >= sampleWidth * sampleHeight
}
