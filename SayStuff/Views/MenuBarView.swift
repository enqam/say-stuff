import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var profileManager: ProfileManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "mic.fill")
                    .foregroundColor(.accentColor)
                Text("SayStuff")
                    .font(.headline)
                Spacer()
                if appDelegate.isRecording {
                    RecordingIndicator()
                } else if appDelegate.isTranscribing {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding()

            Divider()

            // Profile picker
            Text("Profile")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            ForEach(profileManager.profiles) { profile in
                ProfileRow(
                    profile: profile,
                    isSelected: appDelegate.activeProfile?.id == profile.id,
                    onSelect: { appDelegate.selectProfile(profile) }
                )
            }

            Button(action: { appDelegate.openProfileEditor() }) {
                Label("Edit Profiles...", systemImage: "pencil")
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 4)

            Divider()
                .padding(.vertical, 8)

            // Settings and Quit
            Button(action: { appDelegate.openSettings() }) {
                Label("Settings...", systemImage: "gear")
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 4)

            Button(action: { appDelegate.checkForUpdates() }) {
                Label("Check for Updates...", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 4)

            Button(action: { appDelegate.quit() }) {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 4)

            Spacer()
        }
        .frame(width: 280, height: 300)
    }
}

struct ProfileRow: View {
    let profile: Profile
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                VStack(alignment: .leading) {
                    Text(profile.name)
                    Text(profile.language == "auto" ? "Auto-detect" : profile.language.uppercased())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
}

struct RecordingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .opacity(isAnimating ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.5).repeatForever(), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}

#Preview {
    MenuBarView(
        appDelegate: AppDelegate(),
        profileManager: ProfileManager.shared
    )
}
