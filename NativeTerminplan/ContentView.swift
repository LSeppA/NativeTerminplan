import SwiftUI

struct ContentView: View {
    @StateObject private var store = ScheduleStore()
    @StateObject private var calendar = CalendarService()
    @State private var source: ImageSource?
    @State private var isRecognizing = false
    @State private var showClearConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.days.isEmpty && !isRecognizing { emptyState }
                else { scheduleList }
            }
            .navigationTitle("Mein Terminplan")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { showClearConfirmation = true }.disabled(store.days.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) { importMenu }
            }
            .confirmationDialog("Gespeicherte Termine löschen?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
                Button("Alle Termine löschen", role: .destructive) { store.clear() }
            }
            .sheet(item: $source) { source in CameraPicker(sourceType: source.pickerSource) { image in recognize(image) } }
            .overlay { if isRecognizing { ProgressView("Terminplan wird gelesen …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .alert("Hinweis", isPresented: Binding(get: { errorMessage != nil || calendar.errorMessage != nil }, set: { if !$0 { errorMessage = nil; calendar.errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? calendar.errorMessage ?? "") }
        }
    }

    private var importMenu: some View {
        Menu {
            Button("Kamera", systemImage: "camera") { source = .camera }
            Button("Fotomediathek", systemImage: "photo") { source = .photoLibrary }
        } label: { Label("Einlesen", systemImage: "doc.text.viewfinder") }
    }

    private var emptyState: some View {
        ContentUnavailableView("Noch keine Termine", systemImage: "calendar", description: Text("Mit „Einlesen“ den Wochenplan fotografieren oder aus der Fotomediathek auswählen."))
    }

    private var scheduleList: some View {
        List {
            ForEach(store.days) { day in
                Section(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()).capitalized) {
                    ForEach(day.items) { item in ScheduleRow(item: item) { Task { await calendar.add(item) } }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func recognize(_ image: UIImage) {
        isRecognizing = true
        Task {
            do {
                let items = try await OCRService().recognizeSchedule(in: image)
                if items.isEmpty { errorMessage = "Es wurden keine Termine oder Informationszeilen erkannt." }
                else { store.replace(with: items) }
            } catch { errorMessage = error.localizedDescription }
            isRecognizing = false
        }
    }
}

private enum ImageSource: String, Identifiable {
    case camera, photoLibrary
    var id: String { rawValue }
    var pickerSource: UIImagePickerController.SourceType { self == .camera ? .camera : .photoLibrary }
}

private struct ScheduleRow: View {
    let item: ScheduleItem
    let addToCalendar: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.timeText).fontWeight(.semibold)
                if !item.durationText.isEmpty { Text(item.durationText).font(.caption).foregroundStyle(.secondary) }
            }.frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).fontWeight(item.kind == .information ? .medium : .semibold)
                if !item.location.isEmpty { Text(item.location).font(.subheadline).foregroundStyle(.secondary) }
                if !item.note.isEmpty { Text(item.note).font(.footnote).italic().foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if item.kind == .appointment { Button("Termin", action: addToCalendar).buttonStyle(.bordered) }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
