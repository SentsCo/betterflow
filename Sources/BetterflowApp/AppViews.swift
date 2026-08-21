import BetterflowBenchmarkCore
import Combine
import ServiceManagement
import Sparkle
import SwiftUI

struct MenuContentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var coordinator: RecognitionCoordinator
  let updater: SPUUpdater

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(coordinator.state.label)
          .font(.headline)
        Text(
          coordinator.recognitionEngine.isEmpty
            ? model.settings.selectedModel.displayName : coordinator.recognitionEngine
        )
          .font(.caption)
          .foregroundStyle(.secondary)
        Label(microphoneName, systemImage: "mic")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Button(coordinator.state == .listening ? "Stop Dictation" : "Start Dictation") {
        coordinator.toggleDictation()
      }
      .keyboardShortcut("d")

      Button {
        model.beginScreenshot()
      } label: {
        Label("Annotate Screenshot", systemImage: "rectangle.and.pencil.and.ellipsis")
      }

      if case .error(let message) = coordinator.state {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
        Button("Dismiss Error") { coordinator.clearError() }
      }

      Divider()
      CheckForUpdatesView(updater: updater)
      Button {
        model.showSettings()
      } label: {
        Label("Settings…", systemImage: "gearshape")
      }
      Button("Quit Betterflow") { model.quit() }
        .keyboardShortcut("q")
    }
    .padding(12)
    .frame(width: 260)
  }

  private var microphoneName: String {
    AudioDeviceCatalog.selectedDevice(
      in: model.audioDevices,
      priorityEnabled: model.settings.microphonePriorityEnabled,
      priority: model.settings.microphonePriority
    )?.name ?? "System Default"
  }
}

@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
  @Published var canCheckForUpdates = false

  init(updater: SPUUpdater) {
    updater.publisher(for: \.canCheckForUpdates)
      .assign(to: &$canCheckForUpdates)
  }
}

@MainActor
private struct CheckForUpdatesView: View {
  @ObservedObject private var viewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  init(updater: SPUUpdater) {
    self.updater = updater
    viewModel = CheckForUpdatesViewModel(updater: updater)
  }

  var body: some View {
    Button(action: updater.checkForUpdates) {
      Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
    }
    .disabled(!viewModel.canCheckForUpdates)
  }
}

struct SettingsView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    TabView {
      GeneralSettingsView(model: model, settings: model.settings)
        .tabItem { Label("General", systemImage: "switch.2") }
      ModelSettingsView(
        settings: model.settings,
        downloads: model.modelDownloads,
        cleanupDownloads: model.cleanupModelDownloads
      )
      .tabItem { Label("Models", systemImage: "waveform.badge.magnifyingglass") }
      CloudSettingsView(
        settings: model.settings,
        credentials: model.cloudCredentials
      )
      .tabItem { Label("Cloud", systemImage: "cloud") }
      VocabularySettingsView(model: model, settings: model.settings)
        .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
      HistorySettingsView(model: model, history: model.history)
        .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
      AudioSettingsView(model: model, settings: model.settings)
        .tabItem { Label("Audio", systemImage: "mic") }
    }
    .frame(width: 680, height: 520)
    .padding()
  }
}

private struct HistorySettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var history: TranscriptionHistory

  var body: some View {
    Group {
      if history.items.isEmpty {
        ContentUnavailableView(
          "No Transcriptions Yet",
          systemImage: "text.bubble",
          description: Text("Completed transcriptions will appear here.")
        )
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(history.items) { item in
              GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                  Text(item.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                  HStack {
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                      model.copyTranscript(item.text)
                    } label: {
                      Label("Copy", systemImage: "doc.on.doc")
                    }
                  }
                  if let rawText = item.rawText {
                    DisclosureGroup("Original transcript") {
                      VStack(alignment: .leading, spacing: 8) {
                        Text(rawText)
                          .frame(maxWidth: .infinity, alignment: .leading)
                          .textSelection(.enabled)
                        HStack {
                          Spacer()
                          Button {
                            model.copyTranscript(rawText)
                          } label: {
                            Label("Copy Original", systemImage: "doc.on.doc")
                          }
                        }
                      }
                      .padding(.top, 6)
                    }
                    .font(.callout)
                  }
                }
                .padding(4)
              }
            }
          }
          .padding()
        }
      }
    }
    .overlay(alignment: .bottomLeading) {
      if let error = history.persistenceError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .padding()
      }
    }
  }
}

private struct GeneralSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var settings: AppSettings
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var launchError: String?

  var body: some View {
    Form {
      Section("Dictation") {
        Picker("Start/stop key", selection: $settings.dictationKey) {
          ForEach(DictationKey.allCases) { key in
            Text(key.label).tag(key)
          }
        }
        Text(
          "Press once to start and again to finish. Enter finishes; press it again while finishing to send afterward. Command-Enter inserts immediately; Z toggles cleanup; Escape cancels."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Toggle("Show the live transcription bubble", isOn: $settings.showOverlay)
      }

      Section("Screenshots") {
        LabeledContent("Annotate shortcut") {
          ShortcutRecorder(shortcut: $settings.screenshotShortcut)
        }
        Text(
          "Draw first, then select an area or copy the full display. P selects pen, A arrow, and R rectangle. Return selects an area, Command-Return copies the display, Command-Z undoes, and Escape cancels."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Permissions") {
        PermissionRow(
          title: "Microphone",
          detail: "Capture speech from the selected input.",
          granted: model.microphoneGranted,
          request: model.requestMicrophone
        )
        PermissionRow(
          title: "Accessibility",
          detail: "Insert the final transcript into the focused app.",
          granted: model.accessibilityGranted,
          request: model.requestAccessibility
        )
        PermissionRow(
          title: "Screen Recording",
          detail: "Capture the desktop for annotated screenshots.",
          granted: model.screenRecordingGranted,
          request: model.requestScreenRecording
        )
      }

      Section("Startup") {
        Toggle("Launch Betterflow at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, enabled in
            do {
              if enabled {
                try SMAppService.mainApp.register()
              } else {
                try SMAppService.mainApp.unregister()
              }
              launchError = nil
            } catch {
              launchError = error.localizedDescription
              launchAtLogin = SMAppService.mainApp.status == .enabled
            }
          }
        if let launchError {
          Text(launchError).font(.caption).foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct PermissionRow: View {
  let title: String
  let detail: String
  let granted: Bool
  let request: () -> Void

  var body: some View {
    HStack {
      Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .foregroundStyle(granted ? .green : .orange)
      VStack(alignment: .leading) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if !granted {
        Button("Allow") { request() }
      }
    }
  }
}

private struct ModelSettingsView: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var downloads: ModelDownloadManager
  @ObservedObject var cleanupDownloads: CleanupModelDownloadManager
  @State private var deleteCandidate: BenchmarkModel?
  @State private var cleanupDeleteCandidate: CleanupModel?

  var body: some View {
    Form {
      Section("Recognition Engine") {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 270), alignment: .top)],
          alignment: .leading,
          spacing: 12
        ) {
          ForEach(BenchmarkModel.allCases, id: \.self) { candidate in
            ModelDownloadCard(
              model: candidate,
              selected: settings.selectedModel == candidate,
              state: downloads.states[candidate] ?? .checking,
              select: { downloads.select(candidate) },
              download: { downloads.download(candidate) },
              delete: { deleteCandidate = candidate }
            )
          }
        }
        Text("Speed and accuracy are relative estimates on Apple silicon; actual performance varies by Mac and speaking style.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Transcript Cleanup") {
        Toggle("Enable cleanup by default", isOn: $settings.cleanupEnabledByDefault)
        Text("Press Z while dictating to toggle cleanup for that transcription.")
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach(CleanupModel.allCases) { candidate in
          CleanupModelDownloadRow(
            model: candidate,
            selected: settings.cleanupModel == candidate,
            state: cleanupDownloads.states[candidate] ?? .checking,
            select: { cleanupDownloads.select(candidate) },
            download: { cleanupDownloads.download(candidate) },
            delete: { cleanupDeleteCandidate = candidate }
          )
        }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      downloads.refresh()
      cleanupDownloads.refresh()
    }
    .confirmationDialog(
      deleteCandidate.map { "Delete \($0.displayName)?" } ?? "Delete model?",
      isPresented: Binding(
        get: { deleteCandidate != nil },
        set: { if !$0 { deleteCandidate = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let deleteCandidate {
        Button("Delete Model", role: .destructive) {
          downloads.delete(deleteCandidate)
          self.deleteCandidate = nil
        }
      }
      Button("Cancel", role: .cancel) { deleteCandidate = nil }
    } message: {
      Text("You can download it again later.")
    }
    .confirmationDialog(
      cleanupDeleteCandidate.map { "Delete \($0.displayName)?" } ?? "Delete model?",
      isPresented: Binding(
        get: { cleanupDeleteCandidate != nil },
        set: { if !$0 { cleanupDeleteCandidate = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let cleanupDeleteCandidate {
        Button("Delete Model", role: .destructive) {
          cleanupDownloads.delete(cleanupDeleteCandidate)
          self.cleanupDeleteCandidate = nil
        }
      }
      Button("Cancel", role: .cancel) { cleanupDeleteCandidate = nil }
    } message: {
      Text("You can download it again later.")
    }
  }
}

private struct CleanupModelDownloadRow: View {
  let model: CleanupModel
  let selected: Bool
  let state: ModelDownloadState
  let select: () -> Void
  let download: () -> Void
  let delete: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: select) {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : .secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(selected ? "Selected" : "Select \(model.displayName)")

      Button(action: select) {
        VStack(alignment: .leading, spacing: 3) {
          Text(model.displayName)
            .foregroundStyle(.primary)
          Text(model.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(statusText)
            .font(.caption2)
            .foregroundStyle(statusIsError ? .red : .secondary)
            .lineLimit(2)
        }
      }
      .buttonStyle(.plain)

      Spacer()

      switch state {
      case .checking, .downloading, .deleting:
        ProgressView().controlSize(.small)
      case .notDownloaded, .failed:
        if model == .qwenSmall { Button("Download", action: download) }
      case .downloaded:
        if model == .qwenSmall {
          Button("Delete", role: .destructive, action: delete)
        }
      case .unavailable:
        EmptyView()
      }
    }
  }

  private var statusText: String {
    switch state {
    case .checking: "Checking…"
    case .notDownloaded: "\(model.detail) · Not downloaded"
    case .downloaded(let bytes):
      bytes.map {
        "Downloaded · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))"
      } ?? model.detail
    case .downloading: "Downloading…"
    case .deleting: "Deleting…"
    case .unavailable(let message), .failed(let message): message
    }
  }

  private var statusIsError: Bool {
    if case .failed = state { return true }
    return false
  }
}

private struct ModelDownloadCard: View {
  let model: BenchmarkModel
  let selected: Bool
  let state: ModelDownloadState
  let select: () -> Void
  let download: () -> Void
  let delete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        Button(action: select) {
          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "Selected" : "Select \(model.displayName)")

        Button(action: select) {
          Text(model.displayName)
            .font(.headline)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)

        Spacer(minLength: 4)
        downloadControl
      }

      Text(model.summary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 18) {
        ModelRatingView(title: "Speed", rating: model.presentation.speed)
        ModelRatingView(title: "Accuracy", rating: model.presentation.accuracy)
        ModelSizeView(label: model.presentation.size)
      }

      HStack(spacing: 6) {
        ModelFeatureBadge(label: "Revisions", supported: model.supportsRevisions)
        ModelFeatureBadge(label: "Guide words", supported: model.supportsGuidance)
      }

      Text(statusText)
        .font(.caption2)
        .foregroundStyle(statusIsError ? Color.red : Color.secondary)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(
          selected ? Color.accentColor : Color.primary.opacity(0.10),
          lineWidth: selected ? 1.5 : 1
        )
    )
  }

  @ViewBuilder
  private var downloadControl: some View {
    switch state {
    case .checking, .downloading, .deleting:
      ProgressView().controlSize(.small)
    case .notDownloaded, .failed:
      Button("Download", action: download).controlSize(.small)
    case .downloaded:
      Button("Delete", role: .destructive, action: delete).controlSize(.small)
    case .unavailable:
      EmptyView()
    }
  }

  private var statusText: String {
    switch state {
    case .checking: "Checking…"
    case .notDownloaded: "Not downloaded"
    case .downloaded(let bytes):
      bytes.map {
        "Downloaded · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))"
      }
        ?? "Downloaded · Managed by macOS"
    case .downloading: "Downloading…"
    case .deleting: "Deleting…"
    case .unavailable(let message), .failed(let message): message
    }
  }

  private var statusIsError: Bool {
    if case .failed = state { return true }
    return false
  }
}

private struct CloudProviderCard: View {
  let provider: CloudTranscriptionProvider
  let selected: Bool
  let configured: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          Text(provider.displayName)
            .font(.headline)
            .foregroundStyle(.primary)
          Spacer(minLength: 4)
          if configured {
            Label("Key saved", systemImage: "key.fill")
              .font(.caption2)
              .foregroundStyle(.green)
          }
        }

        Text(provider.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 18) {
          ModelRatingView(title: "Speed", rating: provider.presentation.speed)
          ModelRatingView(title: "Accuracy", rating: provider.presentation.accuracy)
          ModelSizeView(label: provider.presentation.size)
        }

        HStack(spacing: 6) {
          ModelFeatureBadge(label: "Revisions", supported: true)
          ModelFeatureBadge(label: "Guide words", supported: true)
        }

        Text(configured ? "Ready to use · No local download" : "API key required · No local download")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(
            selected ? Color.accentColor : Color.primary.opacity(0.10),
            lineWidth: selected ? 1.5 : 1
          )
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(selected ? "Selected \(provider.displayName)" : "Select \(provider.displayName)")
  }
}

private struct ModelRatingView: View {
  let title: String
  let rating: ModelRating

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title.uppercased())
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
      HStack(spacing: 2) {
        ForEach(1...4, id: \.self) { level in
          Capsule()
            .fill(level <= rating.score ? Color.accentColor : Color.secondary.opacity(0.18))
            .frame(width: 9, height: 4)
        }
      }
      Text(rating.label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

private struct ModelSizeView: View {
  let label: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("MODEL SIZE")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.tertiary)
      Text(label)
        .font(.caption)
        .foregroundStyle(.primary)
      Text(detail)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private var detail: String {
    switch label {
    case "Cloud": "No download"
    case "System": "Managed by macOS"
    default: "Parameters"
    }
  }
}

private struct ModelFeatureBadge: View {
  let label: String
  let supported: Bool

  var body: some View {
    Label(label, systemImage: supported ? "checkmark" : "xmark")
      .font(.caption2.weight(.medium))
      .foregroundStyle(supported ? Color.primary : Color.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(
        Capsule().fill(supported ? Color.green.opacity(0.12) : Color.secondary.opacity(0.10))
      )
  }
}

private struct ModelRating {
  let label: String
  let score: Int

  static let moderate = ModelRating(label: "Moderate", score: 2)
  static let fast = ModelRating(label: "Fast", score: 3)
  static let veryFast = ModelRating(label: "Very fast", score: 4)
  static let good = ModelRating(label: "Good", score: 2)
  static let high = ModelRating(label: "High", score: 3)
  static let excellent = ModelRating(label: "Excellent", score: 4)
}

private struct ModelPresentation {
  let speed: ModelRating
  let accuracy: ModelRating
  let size: String
}

private extension BenchmarkModel {
  var presentation: ModelPresentation {
    switch self {
    case .parakeet:
      ModelPresentation(speed: .veryFast, accuracy: .high, size: "110M")
    case .moonshineSmall:
      ModelPresentation(speed: .veryFast, accuracy: .good, size: "123M")
    case .moonshineMedium:
      ModelPresentation(speed: .fast, accuracy: .high, size: "245M")
    case .whisper:
      ModelPresentation(speed: .moderate, accuracy: .excellent, size: "≈809M")
    case .appleSpeech:
      ModelPresentation(speed: .fast, accuracy: .high, size: "System")
    case .appleDictation:
      ModelPresentation(speed: .fast, accuracy: .good, size: "System")
    case .parakeetEou:
      ModelPresentation(speed: .veryFast, accuracy: .high, size: "120M")
    case .nemotron:
      ModelPresentation(speed: .fast, accuracy: .high, size: "0.6B")
    case .qwen:
      ModelPresentation(speed: .moderate, accuracy: .excellent, size: "0.6B")
    }
  }
}

private extension CloudTranscriptionProvider {
  var presentation: ModelPresentation {
    switch self {
    case .deepgram:
      ModelPresentation(speed: .veryFast, accuracy: .high, size: "Cloud")
    case .elevenLabs, .openAI:
      ModelPresentation(speed: .veryFast, accuracy: .excellent, size: "Cloud")
    }
  }
}

private struct CloudSettingsView: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var credentials: CloudCredentials
  @State private var apiKey = ""
  @State private var keyError: String?

  var body: some View {
    Form {
      Section("Transcription Location") {
        Picker("Mode", selection: $settings.transcriptionMode) {
          ForEach(TranscriptionMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        Text(settings.transcriptionMode.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Cloud Service") {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 270), alignment: .top)],
          alignment: .leading,
          spacing: 12
        ) {
          ForEach(CloudTranscriptionProvider.allCases) { provider in
            CloudProviderCard(
              provider: provider,
              selected: settings.cloudProvider == provider,
              configured: credentials.configuredProviders.contains(provider),
              select: { settings.cloudProvider = provider }
            )
          }
        }
        Text("Speed and accuracy are qualitative estimates for live English dictation; network conditions still matter.")
          .font(.caption)
          .foregroundStyle(.secondary)

        Picker("Guide word strength", selection: strengthBinding) {
          ForEach(GuideWordStrength.allCases) { strength in
            Text(strength.displayName).tag(strength)
          }
        }
        .pickerStyle(.segmented)
      }

      Section("API Key") {
        SecureField(
          hasSavedKey ? "Saved in Keychain" : "Paste API key",
          text: $apiKey
        )
        .textContentType(.password)

        HStack {
          Button("Save") { saveKey() }
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("Test") { credentials.test(settings.cloudProvider) }
            .disabled(!hasSavedKey || isTesting)
          if hasSavedKey {
            Button("Remove", role: .destructive) { removeKey() }
          }
          Spacer()
          Link("Get API Key", destination: settings.cloudProvider.keyURL)
          Link("Billing", destination: settings.cloudProvider.billingURL)
        }

        if let message = statusMessage {
          Label(message, systemImage: statusIcon)
            .font(.caption)
            .foregroundStyle(statusColor)
        } else {
          Text("Keys are stored only in macOS Keychain.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if settings.transcriptionMode == .automatic {
        Section {
          Label(
            "If the service is unreachable, Betterflow continues with \(settings.selectedModel.displayName) using the audio already captured.",
            systemImage: "arrow.triangle.branch"
          )
          .font(.callout)
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: settings.cloudProvider) {
      apiKey = ""
      keyError = nil
    }
  }

  private var hasSavedKey: Bool {
    credentials.configuredProviders.contains(settings.cloudProvider)
  }

  private var validation: CloudCredentialValidation {
    credentials.validation[settings.cloudProvider] ?? .idle
  }

  private var isTesting: Bool {
    validation == .testing
  }

  private var statusMessage: String? {
    keyError ?? validation.label ?? (hasSavedKey ? "Saved in Keychain" : nil)
  }

  private var statusIcon: String {
    if keyError != nil { return "exclamationmark.circle.fill" }
    return switch validation {
    case .valid: "checkmark.circle.fill"
    case .invalid: "exclamationmark.circle.fill"
    case .testing: "hourglass"
    case .idle: "key.fill"
    }
  }

  private var statusColor: Color {
    if keyError != nil { return .red }
    return switch validation {
    case .valid: .green
    case .invalid: .red
    case .testing, .idle: .secondary
    }
  }

  private var strengthBinding: Binding<GuideWordStrength> {
    Binding(
      get: { settings.guideWordStrength(for: settings.cloudProvider) },
      set: { settings.setGuideWordStrength($0, for: settings.cloudProvider) }
    )
  }

  private func saveKey() {
    do {
      try credentials.save(apiKey, for: settings.cloudProvider)
      apiKey = ""
      keyError = nil
      credentials.test(settings.cloudProvider)
    } catch {
      keyError = error.localizedDescription
    }
  }

  private func removeKey() {
    do {
      try credentials.remove(settings.cloudProvider)
      apiKey = ""
      keyError = nil
    } catch {
      keyError = error.localizedDescription
    }
  }
}

private struct VocabularySettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var settings: AppSettings

  var body: some View {
    Form {
      if settings.selectedModel.supportsGuideWordStrength {
        Section("Strength for \(settings.selectedModel.displayName)") {
          Picker("Strength", selection: strengthBinding) {
            ForEach(GuideWordStrength.allCases) { strength in
              Text(strength.displayName).tag(strength)
            }
          }
          .pickerStyle(.segmented)
        }
      }

      Section {
        ForEach(settings.guideWords.indices, id: \.self) { index in
          HStack {
            TextField(
              "Guide word",
              text: $settings.guideWords[index],
              prompt: Text("Word or name")
            )
            .labelsHidden()
            Button {
              settings.guideWords.remove(at: index)
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
          }
        }
        Button {
          settings.addGuideWord()
        } label: {
          Label("Add Guide Word", systemImage: "plus")
        }
      } header: {
        Text("Guide Words")
      }
    }
    .formStyle(.grouped)
  }

  private var strengthBinding: Binding<GuideWordStrength> {
    Binding(
      get: { settings.guideWordStrength(for: settings.selectedModel) },
      set: { strength in
        settings.setGuideWordStrength(strength, for: settings.selectedModel)
        model.coordinator.prepareSelectedModel()
      }
    )
  }
}

private struct AudioSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var settings: AppSettings

  var body: some View {
    Form {
      Section("Microphone Selection") {
        Toggle(
          "Use an ordered microphone priority list",
          isOn: $settings.microphonePriorityEnabled
        )
        LabeledContent("System default", value: systemDefault?.name ?? "Unavailable")
      }

      if settings.microphonePriorityEnabled {
        Section {
          ForEach(Array(settings.microphonePriority.enumerated()), id: \.element) {
            index, uid in
            let device = devicesByID[uid]
            let isAvailable = device != nil
            let canAssessAvailability = model.microphoneGranted || !devicesByID.isEmpty
            HStack(spacing: 10) {
              Text("\(index + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
              VStack(alignment: .leading, spacing: 2) {
                Text(device?.name ?? settings.knownMicrophoneNames[uid] ?? "Unknown microphone")
                Label(
                  canAssessAvailability
                    ? (isAvailable ? "Available" : "Unavailable") : "Status unknown",
                  systemImage: isAvailable ? "checkmark.circle.fill" : "bolt.slash"
                )
                .font(.caption)
                .foregroundStyle(isAvailable ? .green : .secondary)
              }
              Spacer()
              Button {
                movePriority(index, by: -1)
              } label: {
                Image(systemName: "arrow.up")
              }
              .disabled(index == 0)
              .buttonStyle(.borderless)
              Button {
                movePriority(index, by: 1)
              } label: {
                Image(systemName: "arrow.down")
              }
              .disabled(index == settings.microphonePriority.count - 1)
              .buttonStyle(.borderless)
              if canAssessAvailability, !isAvailable {
                Button {
                  settings.forgetMicrophone(uid)
                } label: {
                  Image(systemName: "trash")
                }
                .help("Forget this microphone")
                .buttonStyle(.borderless)
              }
            }
            .id("\(uid):\(isAvailable)")
          }
        } header: {
          Text("Priority Order")
        } footer: {
          Text("Uses the first available device. Disconnected devices keep their position.")
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { model.refreshAudioDevices() }
  }

  private var systemDefault: AudioInputDevice? {
    model.audioDevices.first(where: \.isDefault)
  }

  private var devicesByID: [String: AudioInputDevice] {
    Dictionary(uniqueKeysWithValues: model.audioDevices.map { ($0.id, $0) })
  }

  private func movePriority(_ index: Int, by delta: Int) {
    let destination = index + delta
    guard settings.microphonePriority.indices.contains(destination) else { return }
    settings.microphonePriority.swapAt(index, destination)
  }
}
