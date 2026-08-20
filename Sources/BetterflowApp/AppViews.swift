import BetterflowBenchmarkCore
import Combine
import ServiceManagement
import SwiftUI

struct MenuContentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var coordinator: RecognitionCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(coordinator.state.label)
          .font(.headline)
        Text(model.settings.selectedModel.displayName)
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

      if case .error(let message) = coordinator.state {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
        Button("Dismiss Error") { coordinator.clearError() }
      }

      Divider()
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
      priorityEnabled: model.settings.microphonePriorityEnabled,
      priority: model.settings.microphonePriority
    )?.name ?? "System Default"
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
      VocabularySettingsView(settings: model.settings)
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
        ForEach(BenchmarkModel.allCases, id: \.self) { candidate in
          ModelDownloadRow(
            model: candidate,
            selected: settings.selectedModel == candidate,
            state: downloads.states[candidate] ?? .checking,
            select: { downloads.select(candidate) },
            download: { downloads.download(candidate) },
            delete: { deleteCandidate = candidate }
          )
        }
      }

      Section("Selected Model") {
        let selected = settings.selectedModel
        CapabilityRow(
          label: "Self-correction",
          supported: selected.supportsRevisions
        )
        CapabilityRow(
          label: "Guide words",
          supported: selected.supportsGuidance
        )
        LabeledContent("Requirements", value: selected.requirements)

        if !selected.supportsRevisions {
          Label(
            "This model cannot revise earlier text while you speak.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.orange)
          .font(.callout)
        }
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

private struct ModelDownloadRow: View {
  let model: BenchmarkModel
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
        ProgressView()
          .controlSize(.small)
      case .notDownloaded, .failed:
        Button("Download", action: download)
      case .downloaded:
        Button("Delete", role: .destructive, action: delete)
      case .unavailable:
        EmptyView()
      }
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

private struct CapabilityRow: View {
  let label: String
  let supported: Bool

  var body: some View {
    LabeledContent(label) {
      HStack {
        Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle.fill")
          .foregroundStyle(supported ? .green : .secondary)
        Text(supported ? "Supported" : "Not supported")
      }
    }
  }
}

private struct VocabularySettingsView: View {
  @ObservedObject var settings: AppSettings

  var body: some View {
    Form {
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
}

private struct AudioSettingsView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var settings: AppSettings
  @State private var devicesByID: [String: AudioInputDevice] = [:]

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
    .onAppear { refreshDevices() }
    .onChange(of: model.microphoneGranted) { _, _ in refreshDevices() }
    .onChange(of: settings.microphonePriorityEnabled) { _, _ in refreshDevices() }
    .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
      refreshDevices()
    }
  }

  private var systemDefault: AudioInputDevice? {
    devicesByID.values.first(where: \.isDefault)
  }

  private func refreshDevices() {
    let devices = AudioDeviceCatalog.inputDevices()
    devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
    settings.rememberMicrophones(devices)
  }

  private func movePriority(_ index: Int, by delta: Int) {
    let destination = index + delta
    guard settings.microphonePriority.indices.contains(destination) else { return }
    settings.microphonePriority.swapAt(index, destination)
  }
}
