import SwiftUI

#if DEBUG
// Shim to avoid build error if NotificationService isn't compiled in this target yet.
// Remove this once NotificationService.swift is part of the app target.
struct NotificationServiceShim {
    static func scheduleNotification(for: ScheduleItem) {}
}
#endif

#if !canImport(ActivityKit)
// Shim to avoid build error if ActivityKit isn't available or the manager isn't in this target.
enum LiveActivityManager {
    static func startOrUpdate(current: ScheduleItem?, next: ScheduleItem?) {}
    static func endAll() {}
}
#endif

@MainActor
private final class ImportViewModel: ObservableObject {
    @Published var source: ImageSource?
    @Published var isRecognizing = false
    @Published var errorMessage: String?
    @Published var showCaptureHint = false
    @Published var lastCapturedPhotoId: String?
    @Published var selectedPhotoId: String?
    @Published var selectedPhotoImage: UIImage?
    @Published var showPhotoViewer = false
    @Published var showImportReview = false
    @Published var importReviewItems: [ScheduleItem] = []
    @Published var skippedPastImportAppointments: [ScheduleItem] = []

    func showPhoto(with identifier: String) {
        selectedPhotoId = identifier
        selectedPhotoImage = nil
        showPhotoViewer = true
    }

    func dismissImportReview() {
        showImportReview = false
        importReviewItems = []
        skippedPastImportAppointments = []
    }

    func presentImportReview(from result: ScheduleImportResult) {
        importReviewItems = result.importedItems
        skippedPastImportAppointments = result.skippedPastAppointments
        showImportReview = true
    }
}

struct ContentView: View {
    @StateObject private var store = ScheduleStore()
    @StateObject private var coordinator = ScheduleCoordinator()
    @StateObject private var importViewModel = ImportViewModel()
    @State private var showClearConfirmation = false
    @State private var showInfo = false
    @AppStorage("hasAcceptedInfo") private var hasAcceptedInfo: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if store.days.isEmpty && !importViewModel.isRecognizing { emptyState }
                else { scheduleList }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text("Mein Terminplan")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Button {
                            showInfo = true
                        } label: {
                            Image(systemName: "info.circle.fill")
                                .imageScale(.medium)
                                .foregroundStyle(.blue)
                                .accessibilityLabel("Informationen anzeigen")
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) { showClearConfirmation = true } label: { Image(systemName: "trash") }
                        .disabled(store.days.isEmpty)
                        .accessibilityLabel("Alle Termine löschen")
                }
                ToolbarItem(placement: .topBarTrailing) { importMenu.disabled(!hasAcceptedInfo) }
#if DEBUG
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        coordinator.insertDebugAppointments(into: store)
                    } label: {
                        Label("Test", systemImage: "hammer")
                    }
                    .disabled(!hasAcceptedInfo)
                    .accessibilityLabel("Testtermine anlegen")
                }
#endif
            }
            .confirmationDialog("Gespeicherte Termine löschen?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
                Button("Alle Termine löschen", role: .destructive) {
                    coordinator.clearAll(in: store)
                }
            }
            .sheet(item: $importViewModel.source) { source in
                CameraPicker(sourceType: source.pickerSource) { image in
                    importViewModel.lastCapturedPhotoId = coordinator.savePhoto(image)?.path
                    recognize(image)
                }
            }
            .sheet(isPresented: $showInfo) {
                InfoSheetView(
                    hasAccepted: hasAcceptedInfo,
                    onAccept: {
                        hasAcceptedInfo = true
                        showInfo = false
                    },
                    onDecline: {
                        showInfo = false
                    }
                )
            }
            .sheet(isPresented: $importViewModel.showImportReview) {
                ImportReviewView(items: importViewModel.importReviewItems) {
                    importViewModel.dismissImportReview()
                } onCommit: {
                    Task {
                        await coordinator.commitImport(
                            importedItems: importViewModel.importReviewItems,
                            skippedPastAppointments: importViewModel.skippedPastImportAppointments,
                            into: store
                        )
                        importViewModel.dismissImportReview()
                        await showTemporaryCaptureHint()
                    }
                }
            }
            .sheet(isPresented: $importViewModel.showPhotoViewer) {
                NavigationStack {
                    Group {
                        if let img = importViewModel.selectedPhotoImage {
                            ZoomableImage(uiImage: img)
                                .background(Color(.systemBackground))
                        } else {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Lade Foto...")
                            }
                            .padding()
                        }
                    }
                    .navigationTitle("Foto")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Fertig") { importViewModel.showPhotoViewer = false }
                        }
                    }
                    .onAppear {
                        reloadSelectedPhotoIfNeeded()
                    }
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if importViewModel.showCaptureHint {
                        Text("Bitte prüfe die erfassten Daten mit den Terminen auf dem Papier. Falls Abweichungen bestehen, erstelle bitte eine neue Aufnahme direkt über dem Papier bis das Ergebnis brauchbar ist.")
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !hasAcceptedInfo {
                        Button {
                            showInfo = true
                        } label: {
                            Text("Zur Freischaltung zum Einlesen bitte zuerst Bedingungen akzeptieren!")
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, importViewModel.showCaptureHint ? 0 : 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: importViewModel.showCaptureHint)
            .animation(.easeInOut(duration: 0.25), value: hasAcceptedInfo)
            .alert("Hinweis", isPresented: Binding(get: { importViewModel.errorMessage != nil }, set: { if !$0 { importViewModel.errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(importViewModel.errorMessage ?? "") }
            .task {
                if !hasAcceptedInfo {
                    showInfo = true
                }
                await coordinator.handleStartup(store: store)
            }
            .onScenePhaseBecameActive {
                coordinator.handleSceneBecameActive(store: store)
            }
        }
    }

    private func showPhoto(with identifier: String) {
        importViewModel.showPhoto(with: identifier)
        loadSelectedPhoto(identifier: identifier)
    }

    private func reloadSelectedPhotoIfNeeded() {
        guard importViewModel.showPhotoViewer, importViewModel.selectedPhotoImage == nil, let identifier = importViewModel.selectedPhotoId else { return }
        loadSelectedPhoto(identifier: identifier)
    }

    private func loadSelectedPhoto(identifier: String) {
        coordinator.showPhoto(identifier: identifier) { result in
            switch result {
            case .success(let image):
                importViewModel.selectedPhotoImage = image
            case .failure(let error):
                importViewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private var importMenu: some View {
        Menu {
            Button("Kamera", systemImage: "camera") { importViewModel.source = .camera }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button("Fotomediathek", systemImage: "photo") { importViewModel.source = .photoLibrary }
        } label: { Label("Einlesen", systemImage: "doc.text.viewfinder") }
    }

    private var emptyState: some View {
        ContentUnavailableView("Noch keine Termine", systemImage: "calendar", description: Text("Mit „Einlesen“ den Wochenplan fotografieren oder aus der Fotomediathek auswählen."))
    }

    private var scheduleList: some View {
        List {
            if let next = ScheduleLogic.currentOrNext(from: store.days.flatMap { $0.items }) {
                let isCurrent = ScheduleLogic.isCurrent(next)
                Section(isCurrent ? "Jetzt" : "Als Nächstes") {
                    NextAppointmentCard(item: next, onShowPhoto: { id in showPhoto(with: id) })
                }
            }
            ForEach(store.days) { day in
                Section(day.germanHeading) {
                    ForEach(day.items) { item in
                        ScheduleRow(item: item, onShowPhoto: { id in showPhoto(with: id) })
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .id(coordinator.refreshToken)
    }

    private func recognize(_ image: UIImage) {
        importViewModel.isRecognizing = true
        Task {
            do {
                let importResult = try await coordinator.previewImport(
                    from: image,
                    photoPath: importViewModel.lastCapturedPhotoId,
                    existingItems: store.days.flatMap { $0.items }
                )
                if importResult.trimmedItems.isEmpty {
                    importViewModel.errorMessage = "Es wurden keine Termine oder Informationszeilen erkannt."
                } else if importResult.importedItems.isEmpty {
                    importViewModel.errorMessage = "Es wurden keine zukünftigen Termine im Plan erkannt."
                } else {
                    importViewModel.presentImportReview(from: importResult)
                }
            } catch {
                importViewModel.errorMessage = error.localizedDescription
            }
            importViewModel.isRecognizing = false
        }
    }

    private func showTemporaryCaptureHint() async {
        importViewModel.showCaptureHint = true
        if #available(iOS 17.0, *) {
            try? await Task.sleep(for: .seconds(3))
        } else {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        withAnimation { importViewModel.showCaptureHint = false }
    }
}

private struct ImportReviewView: View {
    let items: [ScheduleItem]
    let onCancel: () -> Void
    let onCommit: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                if !item.timeText.isEmpty {
                                    Text(item.timeText)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                                Text(item.kind == .appointment ? "Termin" : "Info")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.title)
                                .font(.body.weight(item.kind == .appointment ? .semibold : .regular))
                            if !item.durationText.isEmpty {
                                Text(item.durationText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !item.note.isEmpty {
                                Text(item.note)
                                    .font(.footnote)
                                    .italic()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text("Bitte prüfe die erkannten Termine mit dem Papierplan. Wenn etwas nicht stimmt, verwirf den Import und scanne den Plan erneut.")
                }
            }
            .navigationTitle("Erkannte Termine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Verwerfen", role: .destructive, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen", action: onCommit)
                }
            }
        }
    }
}

private struct NextAppointmentCard: View {
    let item: ScheduleItem
    let onShowPhoto: ((String) -> Void)?

    private var isCurrent: Bool {
        ScheduleLogic.isCurrent(item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(item.timeText, systemImage: "clock.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                if let id = item.photoFileURL ?? item.photoAssetLocalIdentifier {
                    Button {
                        onShowPhoto?(id)
                    } label: {
                        Image(systemName: "photo")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Foto anzeigen")
                    }
                    .buttonStyle(.plain)
                }
                if isCurrent {
                    Text("Jetzt")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Jetzt")
                }
            }
            Text(item.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(nil)
        }
        .padding(.vertical, 6)
    }
}

private enum ImageSource: String, Identifiable {
    case camera, photoLibrary
    var id: String { rawValue }
    var pickerSource: UIImagePickerController.SourceType { self == .camera ? .camera : .photoLibrary }
}

private struct ScheduleRow: View {
    let item: ScheduleItem
    let onShowPhoto: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.timeText).fontWeight(.semibold)
                if !item.durationText.isEmpty { Text(item.durationText).font(.caption).foregroundStyle(.secondary) }
            }.frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .fontWeight(item.kind == .information ? .medium : .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
                if !item.location.isEmpty { Text(item.location).font(.subheadline).foregroundStyle(.secondary) }
                if !item.note.isEmpty { Text(item.note).font(.footnote).italic().foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let id = item.photoFileURL ?? item.photoAssetLocalIdentifier {
                Button {
                    onShowPhoto?(id)
                } label: {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Foto anzeigen")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    @ViewBuilder
    func onScenePhaseBecameActive(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.modifier(ScenePhaseChange17(action: action))
        } else {
            self.modifier(ScenePhaseChange16(action: action))
        }
    }
}

private struct ScenePhaseChange17: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let action: () -> Void
    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { action() }
        }
    }
}

private struct ScenePhaseChange16: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let action: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { action() }
            }
        } else {
            content.onChange(of: scenePhase) { phase in
                if phase == .active { action() }
            }
        }
    }
}

private struct ZoomableImage: View {
    let uiImage: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let magnification = MagnificationGesture()
                .onChanged { value in
                    let newScale = lastScale * value
                    scale = max(1, min(newScale, 4))
                }
                .onEnded { _ in
                    lastScale = scale
                }

            let drag = DragGesture()
                .onChanged { value in
                    guard scale > 1 else { return }
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                }
                .onEnded { _ in
                    lastOffset = offset
                }

            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnification)
                .simultaneousGesture(drag)
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if scale > 1 {
                            scale = 1
                            lastScale = 1
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2
                            lastScale = 2
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: scale)
        }
        .background(Color.black.opacity(0.02))
    }
}
