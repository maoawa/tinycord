//
//  QuickRepliesManagerView.swift
//  TinyCord
//

import SwiftUI

struct QuickRepliesManagerView: View {
    @Binding var quickReplies: [String]
    let onSave: () -> Void

    @State private var showingAddAlert = false
    @State private var newReplyText = ""

    @State private var showingEditAlert = false
    @State private var editingIndex: Int? = nil
    @State private var editingReplyText = ""

    @State private var showingResetAlert = false

    static let defaultQuickReplies: [String] = [
        "OK",
        "On my way!",
        "Can't talk right now",
        "Yes",
        "No",
        "Thanks!",
        "Sounds good",
        "Call you later",
        "Check Discord later"
    ]

    var body: some View {
        List {
            Section {
                ForEach(Array(quickReplies.enumerated()), id: \.offset) { index, reply in
                    HStack {
                        Text(reply)
                            .font(.body)

                        Spacer()

                        Button {
                            editingIndex = index
                            editingReplyText = reply
                            showingEditAlert = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingIndex = index
                        editingReplyText = reply
                        showingEditAlert = true
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            editingIndex = index
                            editingReplyText = reply
                            showingEditAlert = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteReply(at: index)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete(perform: deleteReplies)
                .onMove(perform: moveReplies)
            } header: {
                Text("Quick Messages")
            } footer: {
                Text("These quick message presets appear on your Apple Watch when replying to messages. Drag the grabber handles to reorder.")
            }

            Section {
                Button {
                    newReplyText = ""
                    showingAddAlert = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Add Quick Reply")
                            .foregroundStyle(.blue)
                    }
                }

                Button(role: .destructive) {
                    showingResetAlert = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundStyle(.red)
                        Text("Reset to Defaults")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Quick Replies")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    newReplyText = ""
                    showingAddAlert = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("Add Quick Reply", isPresented: $showingAddAlert) {
            TextField("e.g. Be right there!", text: $newReplyText)
            Button("Add") {
                let trimmed = newReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    quickReplies.append(trimmed)
                    onSave()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new quick reply phrase to use on Apple Watch.")
        }
        .alert("Edit Quick Reply", isPresented: $showingEditAlert) {
            TextField("Quick Reply", text: $editingReplyText)
            Button("Save") {
                if let index = editingIndex, quickReplies.indices.contains(index) {
                    let trimmed = editingReplyText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        quickReplies[index] = trimmed
                        onSave()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Update this quick reply phrase.")
        }
        .confirmationDialog(
            "Reset quick replies to default presets?",
            isPresented: $showingResetAlert,
            titleVisibility: .visible
        ) {
            Button("Reset to Defaults", role: .destructive) {
                quickReplies = Self.defaultQuickReplies
                onSave()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will replace your custom list with the standard presets.")
        }
    }

    private func deleteReplies(at offsets: IndexSet) {
        quickReplies.remove(atOffsets: offsets)
        onSave()
    }

    private func deleteReply(at index: Int) {
        if quickReplies.indices.contains(index) {
            quickReplies.remove(at: index)
            onSave()
        }
    }

    private func moveReplies(from source: IndexSet, to destination: Int) {
        quickReplies.move(fromOffsets: source, toOffset: destination)
        onSave()
    }
}
