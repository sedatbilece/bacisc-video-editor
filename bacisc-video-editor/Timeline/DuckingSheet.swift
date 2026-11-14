import EditorCore
import SwiftUI

/// Lowers an audio track (music) while the chosen voice track has speech.
struct DuckingSheet: View {
    let track: Track
    let project: Project
    var session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var voiceTrackID: Track.ID?
    @State private var amount: Double = -12

    /// Other tracks whose clips can carry sound.
    private var voiceTracks: [Track] {
        project.tracks.filter { other in
            other.id != track.id && !project.audibleClips(onTrack: other.id).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Duck \(project.label(ofTrack: track.id))")
                .font(.title2.bold())
            Text("While someone speaks on the voice track, this track is lowered and comes back up in the pauses. Speech is found from the voice track's audio level.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if voiceTracks.isEmpty {
                Text("No other track has audio yet.")
                    .foregroundStyle(.secondary)
            } else {
                Form {
                    Picker("Voice Track", selection: $voiceTrackID) {
                        ForEach(voiceTracks) { voice in
                            Text(project.label(ofTrack: voice.id)).tag(Track.ID?.some(voice.id))
                        }
                    }
                    LabeledContent("Lower By") {
                        HStack {
                            Slider(value: $amount, in: Ducking.amountRange, step: 1)
                            Text("\(Int(amount)) dB")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
            }

            HStack {
                if track.ducking != nil {
                    Button("Remove Ducking", role: .destructive) {
                        session.setDucking(nil, onTrack: track.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if let voiceTrackID {
                        session.setDucking(Ducking(voiceTrackID: voiceTrackID, amount: amount), onTrack: track.id)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(voiceTrackID == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            voiceTrackID = track.ducking?.voiceTrackID ?? voiceTracks.first?.id
            amount = track.ducking?.amount ?? -12
        }
    }
}
