//
// MessageListView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct MessageListView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var scrollProxy: ScrollViewReader?
    @State private var showScrollToBottomButton = false
    
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
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Messages
                        ForEach(viewModel.filteredMessages) { message in
                            MessageRowView(message: message)
                                .id(message.id)
                        }
                        
                        // Typing indicators
                        ForEach(Array(viewModel.typingUsers), id: \.self) { user in
                            TypingIndicatorView(user: user)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                .background(backgroundColor)
                .onChange(of: viewModel.filteredMessages.count) { _ in
                    scrollToBottom(proxy: proxy)
                }
                .onAppear {
                    scrollToBottom(proxy: proxy)
                }
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: geometry.frame(in: .named("scroll")).minY
                        )
                    }
                )
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    // Show scroll to bottom button if user scrolled up
                    showScrollToBottomButton = value > 100
                }
                .coordinateSpace(name: "scroll")
            }
            
            // Scroll to bottom button
            if showScrollToBottomButton {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        if let proxy = scrollProxy,
                           let lastMessage = viewModel.filteredMessages.last {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                    showScrollToBottomButton = false
                }) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .background(Circle().fill(textColor))
                        .shadow(radius: 2)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 16)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .onAppear {
            // Set up scroll proxy reference
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // This is a workaround to capture the scroll proxy
                scrollProxy = ScrollViewReader { proxy in
                    EmptyView()
                } as? ScrollViewReader
            }
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewReader) {
        guard let lastMessage = viewModel.filteredMessages.last else { return }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - Supporting Views

struct MessageRowView: View {
    let message: BitchatMessage
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @State private var showMessageActions = false
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Message header
            HStack {
                // Sender info
                HStack(spacing: 4) {
                    // Channel indicator
                    if let channel = message.channel {
                        Text("#\(channel)")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    // Private message indicator
                    if message.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    
                    // Sender nickname
                    Text(message.nickname)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(textColor)
                }
                
                Spacer()
                
                // Timestamp and status
                HStack(spacing: 4) {
                    Text(formatTimestamp(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(secondaryTextColor)
                    
                    // Delivery status for sent messages
                    if message.senderID == viewModel.peerID {
                        DeliveryStatusView(messageID: message.id)
                    }
                }
            }
            
            // Message content
            MessageContentView(message: message)
                .contextMenu {
                    MessageContextMenu(message: message)
                }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(messageBackgroundColor)
                .opacity(0.5)
        )
        .onLongPressGesture {
            showMessageActions = true
        }
        .sheet(isPresented: $showMessageActions) {
            MessageActionsSheet(message: message)
        }
    }
    
    private var messageBackgroundColor: Color {
        if message.senderID == viewModel.peerID {
            return textColor.opacity(0.1) // Own messages
        } else if message.isPrivate {
            return Color.orange.opacity(0.1) // Private messages
        } else if message.content.contains("@\(viewModel.nickname)") {
            return Color.yellow.opacity(0.1) // Mentions
        } else {
            return Color.gray.opacity(0.1) // Regular messages
        }
    }
    
    private func formatTimestamp(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

struct MessageContentView: View {
    let message: BitchatMessage
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    var body: some View {
        Text(message.content)
            .font(.body)
            .foregroundColor(textColor)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
    }
}

struct DeliveryStatusView: View {
    let messageID: String
    @State private var deliveryStatus: DeliveryStatus = .pending
    
    var body: some View {
        Group {
            switch deliveryStatus {
            case .pending:
                Image(systemName: "clock")
                    .foregroundColor(.gray)
            case .sent:
                Image(systemName: "checkmark")
                    .foregroundColor(.blue)
            case .delivered:
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.red)
            }
        }
        .font(.caption2)
        .onReceive(DeliveryTracker.shared.deliveryStatusUpdated) { update in
            if update.messageID == messageID {
                deliveryStatus = update.status
            }
        }
    }
}

struct TypingIndicatorView: View {
    let user: String
    @Environment(\.colorScheme) var colorScheme
    @State private var animationOffset: CGFloat = 0
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    var body: some View {
        HStack {
            Text("\(user) is typing")
                .font(.caption)
                .foregroundColor(textColor.opacity(0.7))
                .italic()
            
            HStack(spacing: 2) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(textColor.opacity(0.7))
                        .frame(width: 4, height: 4)
                        .offset(y: animationOffset)
                        .animation(
                            Animation.easeInOut(duration: 0.6)
                                .repeatForever()
                                .delay(Double(index) * 0.2),
                            value: animationOffset
                        )
                }
            }
        }
        .padding(.leading)
        .onAppear {
            animationOffset = -4
        }
    }
}

struct MessageContextMenu: View {
    let message: BitchatMessage
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        Group {
            Button("Copy", action: {
                copyMessage()
            })
            
            if message.senderID != viewModel.peerID {
                Button("Reply", action: {
                    replyToMessage()
                })
                
                Button("Private Message", action: {
                    sendPrivateMessage()
                })
            }
            
            if message.senderID == viewModel.peerID {
                Button("Delete", role: .destructive, action: {
                    deleteMessage()
                })
            }
        }
    }
    
    private func copyMessage() {
        #if os(iOS)
        UIPasteboard.general.string = message.content
        #elseif os(macOS)
        NSPasteboard.general.setString(message.content, forType: .string)
        #endif
    }
    
    private func replyToMessage() {
        // TODO: Implement reply functionality
    }
    
    private func sendPrivateMessage() {
        // TODO: Implement private message to sender
    }
    
    private func deleteMessage() {
        // TODO: Implement message deletion
    }
}

struct MessageActionsSheet: View {
    let message: BitchatMessage
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Message Actions")
                    .font(.title2)
                    .fontWeight(.bold)
                
                // TODO: Add action buttons
                
                Spacer()
            }
            .padding()
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

// MARK: - Preference Keys

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    MessageListView()
        .environmentObject(ChatViewModel())
}
