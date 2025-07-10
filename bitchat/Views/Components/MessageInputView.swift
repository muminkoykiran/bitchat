//
// MessageInputView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct MessageInputView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Binding var messageText: String
    @Binding var textFieldSelection: NSRange?
    @FocusState var isTextFieldFocused: Bool
    @Binding var showCommandSuggestions: Bool
    @Binding var commandSuggestions: [String]
    @Environment(\.colorScheme) var colorScheme
    
    @State private var isRecording = false
    @State private var showEmojiPicker = false
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Command suggestions
            if showCommandSuggestions && !commandSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(commandSuggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                insertCommandSuggestion(suggestion)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(textColor.opacity(0.1))
                            .foregroundColor(textColor)
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 40)
                .background(backgroundColor)
            }
            
            Divider()
            
            // Main input area
            HStack(spacing: 12) {
                // Emoji button
                Button(action: {
                    showEmojiPicker.toggle()
                }) {
                    Image(systemName: "face.smiling")
                        .font(.title2)
                        .foregroundColor(textColor)
                }
                .accessibilityLabel("Insert emoji")
                
                // Text input
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.gray.opacity(0.1))
                        .frame(minHeight: 36)
                    
                    HStack {
                        // Input field
                        TextField("Type message...", text: $messageText, axis: .vertical)
                            .textFieldStyle(PlainTextFieldStyle())
                            .focused($isTextFieldFocused)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .lineLimit(1...6)
                            .onChange(of: messageText) { newValue in
                                handleTextChange(newValue)
                            }
                            .onSubmit {
                                sendMessage()
                            }
                        
                        // Attach button (for future file attachments)
                        Button(action: {
                            // TODO: Implement file attachment
                        }) {
                            Image(systemName: "paperclip")
                                .font(.title3)
                                .foregroundColor(secondaryTextColor)
                        }
                        .opacity(messageText.isEmpty ? 1 : 0)
                        .animation(.easeInOut(duration: 0.2), value: messageText.isEmpty)
                        .padding(.trailing, 8)
                    }
                }
                
                // Send/Voice button
                Button(action: {
                    if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        startVoiceRecording()
                    } else {
                        sendMessage()
                    }
                }) {
                    Image(systemName: messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "mic" : "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? secondaryTextColor : textColor)
                        .scaleEffect(isRecording ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.1), value: isRecording)
                }
                .accessibilityLabel(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Record voice message" : "Send message")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(backgroundColor)
        }
        .sheet(isPresented: $showEmojiPicker) {
            EmojiPickerView { emoji in
                insertEmoji(emoji)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func handleTextChange(_ newValue: String) {
        // Update command suggestions
        if newValue.hasPrefix("/") {
            let commandText = String(newValue.dropFirst())
            updateCommandSuggestions(for: commandText)
        } else {
            showCommandSuggestions = false
            commandSuggestions = []
        }
    }
    
    private func updateCommandSuggestions(for text: String) {
        let allCommands = ["/nick", "/join", "/leave", "/clear", "/help", "/channel", "/private", "/status"]
        
        if text.isEmpty {
            commandSuggestions = allCommands
        } else {
            commandSuggestions = allCommands.filter { command in
                command.lowercased().contains(text.lowercased())
            }
        }
        
        showCommandSuggestions = !commandSuggestions.isEmpty
    }
    
    private func insertCommandSuggestion(_ suggestion: String) {
        messageText = suggestion + " "
        showCommandSuggestions = false
        isTextFieldFocused = true
    }
    
    private func insertEmoji(_ emoji: String) {
        messageText += emoji
    }
    
    private func sendMessage() {
        let trimmedMessage = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }
        
        viewModel.sendMessage(trimmedMessage)
        messageText = ""
        showCommandSuggestions = false
    }
    
    private func startVoiceRecording() {
        isRecording = true
        // TODO: Implement voice recording functionality
        
        // Simulate recording for now
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isRecording = false
        }
    }
}

// MARK: - Supporting Views

struct EmojiPickerView: View {
    let onEmojiSelected: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    
    private let emojis = [
        "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇",
        "🙂", "🙃", "😉", "😌", "😍", "🥰", "😘", "😗", "😙", "😚",
        "😋", "😛", "😝", "😜", "🤪", "🤨", "🧐", "🤓", "😎", "🤩",
        "🥳", "😏", "😒", "😞", "😔", "😟", "😕", "🙁", "☹️", "😣",
        "👍", "👎", "👌", "✌️", "🤞", "🤟", "🤘", "🤙", "👈", "👉",
        "👆", "🖕", "👇", "☝️", "👋", "🤚", "🖐", "✋", "🖖", "👏"
    ]
    
    var body: some View {
        NavigationView {
            LazyVGrid(columns: Array(repeating: GridItem(.adaptive(minimum: 40)), count: 8), spacing: 10) {
                ForEach(emojis, id: \.self) { emoji in
                    Button(action: {
                        onEmojiSelected(emoji)
                        dismiss()
                    }) {
                        Text(emoji)
                            .font(.title2)
                            .frame(width: 40, height: 40)
                    }
                }
            }
            .padding()
            .navigationTitle("Emojis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    MessageInputView(
        messageText: .constant(""),
        textFieldSelection: .constant(nil),
        showCommandSuggestions: .constant(false),
        commandSuggestions: .constant([])
    )
    .environmentObject(ChatViewModel())
}
