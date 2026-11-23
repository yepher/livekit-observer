# Screenshot assets

These are native app captures using entirely synthetic fixtures. The project is **Acme Voice Demo**; phone numbers use the fictional 202-555-01xx range, SIP identities use `example.com`, and IP addresses use documentation ranges. The audio is generated harmonic bursts, not a person's voice. No real customer calls, credentials, recordings, or project data are included.

| Image | View |
| --- | --- |
| [session-overview.jpg](session-overview.jpg) | Session list, latency, and estimated cost |
| [spectrogram-jitter-overlay.jpg](spectrogram-jitter-overlay.jpg) | Egress and LiveKit audio with jitter assigned to User and Agent channels |
| [transcript.jpg](transcript.jpg) | Fictional conversation with turn metrics |
| [pcap-call-flow.jpg](pcap-call-flow.jpg) | SIP signaling and one arrow per directional RTP stream |
| [pcap-jitter.jpg](pcap-jitter.jpg) | Three streams on one capture timeline |
| [pcap-expert-analysis.jpg](pcap-expert-analysis.jpg) | Findings from deliberately introduced delay and sequence gaps |

## Regenerate

From the repository root, with Xcode, XcodeGen, Python 3, and the normal app's resolved package dependencies available:

```sh
python3 scripts/prepare-screenshots.py
open "build/ScreenshotDerivedData/Build/Products/Debug/Observer Screenshots.app"
```

The script copies the app sources into ignored build output and adds the fixtures from `scripts/screenshot-fixtures`. It builds a separate app with its own bundle identifier and temporary capture/media stores. Background synchronization and CLI access are disabled in that copy. It does not modify the shipping app's sources or accounts. This is a screenshot fixture, not a general-purpose demo mode; use the populated session and capture views only.

Capture the Overview and Transcript tabs. On Spectrogram, enable **Show PCAP jitter**; the fixture already maps captured directions to User and Agent. On Captures, open `support-call-demo.pcap` and capture Call Flow, Jitter, and Expert Analysis. Keep the entire timeline visible and move the pointer away from charts to avoid tooltips.

The current assets retain the capture tool's JPEG output without image edits. Review every replacement for private details before adding it here. Keep generated WAV and PCAP files in ignored build output.
