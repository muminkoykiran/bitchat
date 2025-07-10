//
// HeaderView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

struct HeaderView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Binding var showPeerList: Bool
    @Binding var showSidebar: Bool
    @Binding var showAppInfo: Bool
    @Environment(\.colorScheme) var colorScheme
    
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }
    
    var body: some View {
        HStack {
            // Sidebar toggle
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSidebar.toggle()
                }
            }) {
                Image(systemName: "line.3.horizontal")
                    .font(.title2)
                    .foregroundColor(textColor)
            }
            .accessibilityLabel("Toggle sidebar")
            
            Spacer()
            
            // App title and connection status
            VStack(spacing: 2) {
                Text("BitChat")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(textColor)
                
                // Connection status indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut(duration: 0.3), value: viewModel.connectedPeers.count)
                    
                    Text(connectionStatusText)
                        .font(.caption)
                        .foregroundColor(secondaryTextColor)
                }
            }
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 16) {
                // Peer list toggle
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPeerList.toggle()
                    }
                }) {
                    Image(systemName: "person.2")
                        .font(.title2)
                        .foregroundColor(textColor)
                        .overlay(
                            // Badge for peer count
                            Text("\(viewModel.connectedPeers.count)")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Color.red)
                                .clipShape(Circle())
                                .offset(x: 10, y: -10)
                                .opacity(viewModel.connectedPeers.count > 0 ? 1 : 0)
                        )
                }
                .accessibilityLabel("Show peer list (\(viewModel.connectedPeers.count) connected)")
                
                // App info button
                Button(action: {
                    showAppInfo = true
                }) {
                    Image(systemName: "info.circle")
                        .font(.title2)
                        .foregroundColor(textColor)
                }
                .accessibilityLabel("Show app information")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    private var connectionStatusColor: Color {
        switch viewModel.connectedPeers.count {
        case 0:
            return .red
        case 1...3:
            return .yellow
        default:
            return .green
        }
    }
    
    private var connectionStatusText: String {
        let count = viewModel.connectedPeers.count
        switch count {
        case 0:
            return "Disconnected"
        case 1:
            return "1 peer"
        default:
            return "\(count) peers"
        }
    }
}

#Preview {
    HeaderView(
        showPeerList: .constant(false),
        showSidebar: .constant(false),
        showAppInfo: .constant(false)
    )
    .environmentObject(ChatViewModel())
}
