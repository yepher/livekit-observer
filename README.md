# LiveKit Observer

A macOS app for reviewing LiveKit Cloud sessions: the transcript, agent logs, traces, metrics, latency, and the session's audio, with per-channel mel spectrograms. It works with any LiveKit Cloud project and any agent.

## Requirements

- macOS 15 or later, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to build.
- The LiveKit CLI 2.19.4 or later (`brew install livekit-cli`).
- A LiveKit Cloud user with access to the project. Session data needs the Admin role.
- Agent observability turned on for the project, for transcripts, logs, traces, and LiveKit's session recordings.

## Build and run

```sh
./build.sh          # builds build/LiveKit Observer.app
./build.sh --test   # runs the unit tests first
open "build/LiveKit Observer.app"
```

`build.sh` signs with your Apple Development certificate when you have one (set `SIGN_IDENTITY` to choose another), so the app keeps the same identity across rebuilds and the Keychain's **Always Allow** for the storage secret sticks. Without a certificate it signs ad hoc, and macOS asks for the secret again after every rebuild.

## Setup

### LiveKit

Session data comes through `lk analytics … --user-auth`, so the app uses your `lk` sign-in and never holds LiveKit credentials itself.

1. **Sign in.** In Settings › LiveKit, or from the banner when you are signed out, choose **Sign in…**. It opens Terminal running `lk cloud auth --user-auth`, which finishes in your browser. Refresh when it is done.
2. **Pick a project.** Use the project menu in the toolbar. It lists the projects saved in `lk` (`lk project list`); "lk default project" uses whichever project `lk` treats as the default. To add a project:
   - **Link a Cloud project…** runs `lk cloud auth` in Terminal and adds the project from your browser, including its project ID for dashboard links.
   - **Add with API key…** saves a project's URL, API key, and secret with `lk project add`. `lk` accepts them only as command-line arguments, so they are briefly visible to other processes on this Mac. Reading session data still needs the Cloud sign-in from step 1.
3. **Dashboard links** need the Cloud project ID (`p_…`). Linked projects include it; for others, enter it in Settings › LiveKit.

### Egress storage (optional)

If your egress uploads recordings to S3-compatible storage, the app can list them and play each one beside LiveKit's own recording. In Settings › Egress Storage, for the selected project, enter:

| Field | Example |
| --- | --- |
| Endpoint | `https://nyc3.digitaloceanspaces.com`, `https://<account>.r2.cloudflarestorage.com`, `http://localhost:9000`, or blank for AWS S3 |
| Region | `us-east-1`; found from Spaces and AWS endpoints, `auto` for R2 |
| Bucket | the egress output bucket |
| Folder | the egress `filepath` prefix, or blank for the whole bucket |
| Access key and secret | read-only access is enough |

**Import from .env file…** fills the form from `EGRESS_S3_*` or `AWS_*` variables. The secret is stored in your login Keychain; the other fields are stored in the app's preferences. **Test** checks the connection with a one-object listing.

The app reads the JSON manifest LiveKit egress writes next to each file and matches recordings to sessions by room SID (`RM_…`). Turn on **Egress puts the user on the left channel and the agent on the right** if your egress routes audio by participant kind, for example:

```python
api.MediaSource(audio=api.AudioConfig(routes=[
    api.AudioRoute(participant_kind=api.ParticipantInfo.Kind.AGENT, channel=api.AudioChannel.AUDIO_CHANNEL_RIGHT),
    api.AudioRoute(participant_kind=api.ParticipantInfo.Kind.STANDARD, channel=api.AudioChannel.AUDIO_CHANNEL_LEFT),
    api.AudioRoute(participant_kind=api.ParticipantInfo.Kind.SIP, channel=api.AudioChannel.AUDIO_CHANNEL_LEFT),
]))
```

Otherwise its channels are labeled left and right.

## Using it

- **Session list.** The list is grouped by day and shows each session's room, start time, duration, and the agent that ran it (its dispatch name, read from the session's first log record and cached; names containing "dev" are orange). Tags show which sessions have an egress recording or observability data. LiveKit keeps observability data for 30 days, so older egress recordings show as "Recording only". Right-click a session, or use the flag button in its toolbar, to flag it; flagged sessions show an orange flag, and **Only flagged sessions** below the list shows just those. A paperclip marks sessions that have flags with notes in them. Both are saved on this Mac.
- **Session detail.** It shows the transcript, logs, traces, and metrics, plus a summary with latency (end-to-end, LLM first token, TTS first byte, end-of-turn and transcription delays), low-confidence user speech, and warnings. **Copy for Claude** puts a Markdown digest on the clipboard for a coding agent. It contains what people said, so paste it only into your own tools.
- **Cost.** The overview breaks down what the session cost at a plan's overage rates: agent session minutes (only for agents deployed to LiveKit Cloud), WebRTC participant minutes, downstream data, egress transcoding, observability, and LiveKit Inference (LLM tokens, STT audio, and TTS characters, per model). Usage comes from `lk analytics session get` and the session's traces and metrics. Pick the plan (Scale or Ship) in the box; rates are in `Cost.swift`. These are overage rates, so the figure is what the session costs once the month's included usage runs out. Turn on **Krisp noise cancellation** if your agent uses it, since LiveKit doesn't report it per session. Models used with your own provider keys are listed as billed by that provider, and TTS characters are counted from the request text, so they are missing when PII redaction is on.
- **Playback.** Space plays and pauses wherever the focus is in the session window, except while typing in a field. When a session has both an egress recording and LiveKit's recording, the player switches between them at the same moment.
- **Spectrogram.** It shows a log-mel spectrogram (80 bands, 50 Hz–12 kHz, 10 ms columns, a fixed −100 to −5 dBFS scale so lanes compare) for every channel of each recording on one timeline, stacked or side by side. Pick a zoom preset or pinch to zoom from 2 seconds to the whole session. Click a lane to move the playhead there; the view stays put and turns the page when playback reaches its right edge. Drag to scroll a zoomed view, or to scrub when the whole session is showing. Moving the pointer over a lane skims: a red line follows it and you hear the audio under it, as in Final Cut Pro (Playback › Skimming, ⌥S, turns it off). Ticks mark where agent (blue) and user (green) turns begin. LiveKit's recording puts the user on the left channel and the agent on the right. Egress and LiveKit's recording start at different moments on different clocks, so the app lines them up by matching their loudness and shows the difference beside each recording. If it picks the wrong spot, the ↔ menu beside Egress matches again, goes back to the reported start times, or nudges egress by 0.1 or 1 second; nudges are remembered for the session.
- **Flags.** Right-click a spot on the spectrogram to flag the turn being spoken there (or just that moment), or right-click a transcript line, log line, or span. Playback › Flag Playhead (⌥M) flags the turn at the playhead. Each flag takes a note. Flagged stretches are shaded on the spectrogram, and the matching transcript lines, log lines, and spans are highlighted in yellow; collapsed spans that contain one show an outline flag. The transcript and logs can show only flagged lines, the overview lists every flag, and the Flags toolbar menu jumps to one. Copy for Claude includes each flag with its transcript, log lines, and spans. Flags are saved on this Mac per session. An agent can also flag moments during the session: when it logs a message starting with "Learner flagged this moment" (at any level), the app shows a flag on the turn being spoken at that time, or the turn just before it. These flags come from the session, so they aren't saved on this Mac. The list counts these flags for each session from its warning logs (cached once LiveKit has settled the session), shows an orange "N flags" label, and **Only flagged sessions** includes them. A session tagged `flagged:learner` counts too.

## Privacy

Recordings and transcripts contain people's voices and words. Downloads are cached only on this Mac, in `~/Library/Caches/LiveKitObserver`, along with lossless copies of recordings that macOS's player mistimes (LiveKit's own recordings skip silent stretches, so the player would play each moment early); Settings › Downloads deletes them.
