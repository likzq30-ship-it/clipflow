import SwiftUI

struct LibrarySidebar: View {
    @Binding var selection: LibrarySection
    let customCategories: [PersistedCustomCategory]

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                ForEach(LibrarySection.fixed, id: \.self) { section in
                    row(section: section, title: section.title)
                }
            }

            Section("Categories") {
                ForEach(ClipboardItem.Category.allCases, id: \.self) { category in
                    let section = LibrarySection.builtIn(category)
                    row(section: section, title: category.label)
                }
            }

            if !sortedCustomCategories.isEmpty {
                Section("Custom") {
                    ForEach(sortedCustomCategories) { category in
                        row(
                            section: .custom(category.id),
                            title: category.name,
                            secondary: category.isEnabled ? nil : "Disabled"
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("library.sidebar")
    }
}

private extension LibrarySidebar {
    var sortedCustomCategories: [PersistedCustomCategory] {
        customCategories.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func row(
        section: LibrarySection,
        title: String,
        secondary: String? = nil
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: section.systemImage)
        }
        .tag(section)
    }
}
