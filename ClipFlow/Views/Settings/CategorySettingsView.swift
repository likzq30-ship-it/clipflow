import SwiftUI

struct CategorySettingsView: View {
    @ObservedObject var store: ClipboardStore
    let actions: SettingsActionAdapter

    @State private var name = ""
    @State private var prompt = ""

    var body: some View {
        Form {
            Section("Add Category") {
                TextField("Name", text: $name)
                TextField("Prompt", text: $prompt)
                Button("Add") {
                    let now = Date()
                    let category = PersistedCustomCategory(
                        id: UUID(),
                        name: name,
                        prompt: prompt,
                        sortOrder: store.customCategories.count,
                        isEnabled: true,
                        createdAt: now,
                        updatedAt: now
                    )
                    Task {
                        await actions.saveCategory(category)
                        name = ""
                        prompt = ""
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Categories") {
                ForEach(store.customCategories) { category in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(category.name)
                            if !category.prompt.isEmpty {
                                Text(category.prompt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            Task { await actions.deleteCategory(id: category.id, migrateTo: nil) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(String(localized: "Delete \(category.name)"))
                        .help("Delete category and clear assignments")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
