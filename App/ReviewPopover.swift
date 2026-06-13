// SPDX-License-Identifier: MIT

import SwiftUI

/// One reviewable speaker row (bound by `ReviewPopover`).
struct SpeakerReviewItem: Identifiable, Sendable, Equatable {
    var id: Int64
    var label: String
    var assignedEmail: String?
    var confidence: SpeakerConfidence
    var provenance: SpeakerProvenance
    var hasSnippet: Bool
}

/// Everything the Review popover needs for one meeting.
struct ReviewData: Sendable, Equatable {
    var meetingID: Int64
    var meetingTitle: String
    var speakers: [SpeakerReviewItem]
    var attendees: [NamedAttendee]
}

/// Lets the user confirm or correct speaker → attendee assignments, with a 5 s
/// audio preview per speaker. Assignments are always best-effort and editable
/// here (ADR-005).
struct ReviewPopover: View {
    @Bindable var coordinator: AppCoordinator
    let meetingID: Int64

    @State private var data: ReviewData?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let data {
                Text(data.meetingTitle)
                    .font(.headline)
                Text("Confirm who each speaker is. Scribe's guesses are shown — correct any that are wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(data.speakers) { speaker in
                    speakerRow(speaker, attendees: data.attendees)
                    Divider()
                }
            } else {
                ProgressView("Loading speakers…")
            }
        }
        .padding()
        .frame(width: 420)
        .task(id: meetingID) {
            data = await coordinator.reviewData(meetingID: meetingID)
        }
    }

    @ViewBuilder
    private func speakerRow(_ speaker: SpeakerReviewItem, attendees: [NamedAttendee]) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(speaker.label == AppCoordinator.localUserLabel ? "You (microphone)" : speaker.label)
                    .font(.subheadline.weight(.medium))
                Text("\(speaker.confidence.rawValue) · \(speaker.provenance.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if speaker.hasSnippet {
                Button {
                    Task { await coordinator.playSnippet(meetingID: meetingID, speakerID: speaker.id) }
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Play a 5-second sample")
            }

            Picker("", selection: assignmentBinding(for: speaker)) {
                Text("Unassigned").tag(String?.none)
                ForEach(attendees, id: \.email) { attendee in
                    Text(attendee.name).tag(String?.some(attendee.email))
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    private func assignmentBinding(for speaker: SpeakerReviewItem) -> Binding<String?> {
        Binding(
            get: { speaker.assignedEmail },
            set: { newEmail in
                Task {
                    await coordinator.reassignSpeaker(meetingID: meetingID, speakerID: speaker.id, toEmail: newEmail)
                    data = await coordinator.reviewData(meetingID: meetingID)
                }
            }
        )
    }
}
