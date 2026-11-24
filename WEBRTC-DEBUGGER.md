# Debugging WebRTC with LiveKit Observer

When a user says the agent sounded robotic, couldn't hear them, or kept dropping, the cause is often on their side of the call: their network, their browser, or their microphone. LiveKit's session data shows the server's view. A **WebRTC internals dump** from the user's browser shows theirs: the route their media took, what was lost on the way, and what the browser did about it.

This guide covers collecting a dump from a customer and reading it in LiveKit Observer.

## When to ask for a dump

Ask for one when the problem is about media or connectivity on the client:

- Audio from the agent is choppy, robotic, delayed, or cuts out.
- The agent doesn't hear the user, or hears them in pieces.
- The call won't connect, or disconnects and reconnects.
- It works on one network (home) but not another (office, VPN, hotel Wi-Fi).

A dump won't help with what the agent decided to say, transcription mistakes, or the agent's own latency (LLM and TTS). For those, use the session's transcript, traces, and latency in Observer.

## Collecting a dump

The dump comes from Chrome's built-in `chrome://webrtc-internals` page. It works in desktop **Chrome**, **Edge** (`edge://webrtc-internals`), and other Chromium-based browsers. Firefox and Safari have no equivalent that Observer reads. If the problem happens there, ask the user to reproduce it in Chrome.

### What to send the customer

Copy this, and fill in your contact details:

> To help us see what happened on your side of the call, please capture a diagnostic file from Chrome:
>
> 1. **Before joining the call**, open a new tab and go to: `chrome://webrtc-internals/?keepRemovedConnections`
>    (In Edge, use `edge://webrtc-internals/?keepRemovedConnections`.) Leave this tab open.
> 2. In another tab, join the call and use it as you normally would until the problem happens.
> 3. Note the time it happened and what you noticed (for example, "10:42, the agent's voice went robotic for about 10 seconds").
> 4. Go back to the webrtc-internals tab and click **Create a WebRTC-Internals dump** to expand it.
> 5. Click **Download the "webrtc-internals dump"**, then click **Download the "rtcstats dump"**. This saves two files, usually `webrtc_internals_dump.gz` and `rtcstats_dump.gz`, in your Downloads folder.
> 6. Send us both files, the time you noted, and what kind of network you were on (home Wi-Fi, office, VPN, mobile hotspot).
>
> The files contain technical details about the connection, including IP addresses, but no audio, video, or what was said.

### Why these steps matter

- **Open the page first.** Chrome records a call's events from the moment the page is open. Opened mid-call, it misses how the call connected.
- **`?keepRemovedConnections`** keeps a call's data after it ends or its tab closes. Without it, Chrome throws the data away when the call hangs up, and the customer has to download before leaving the call.
- **Download both files.** The webrtc-internals dump keeps the last 1,000 samples of each statistic, about 16 minutes at Chrome's one-per-second rate, so a long call loses its beginning. The rtcstats dump keeps every sample since the page opened. Observer reads both, so if the call was long, open the rtcstats dump.
- **Compression is fine.** Chrome compresses the files with gzip by default (the "Compress result" checkbox). Observer opens them compressed or not.

### Also get

- **The session.** The room name or session ID (`RM_…`) and the participant's identity, or failing that, the time with its time zone. Then you can open the same call in Observer and line it up with the transcript and recordings.
- **The symptom, in their words, with a time.** "Robotic at 10:42" tells you which part of the charts to look at.
- **The network.** VPNs, corporate firewalls, and congested Wi-Fi cause most client-side problems.

### Handling the files

The dump contains the user's local and public IP addresses, the SDP for the call, and the address of the page they used. That address can include the LiveKit access token in its query string. Observer hides the query string when it shows the page, but the file still contains it. Treat dumps like other customer data: receive them privately, don't post them in public channels or tickets, and delete them when you're done.

## Opening a dump in Observer

Choose **File › Open WebRTC Internals Dump…** (⌘O) and pick the file. Each dump opens in its own window. If you have both files, open the rtcstats dump for a long call, or either one for a short call.

A LiveKit client has two peer connections, and the menu at the top right switches between them:

- **Subscriber (receives)** carries what the user heard: the agent's audio.
- **Publisher (sends)** carries what the user said: their microphone.

Problems with *hearing the agent* show up on the subscriber. Problems with *the agent hearing the user* show up on the publisher.

The window has six tabs.

### Findings

Start here. Each finding says what was seen and when (clock time, and seconds since the connection started), what it usually means, and what to check next. The most serious findings are listed first.

| Finding | Raised when |
| --- | --- |
| Connection failed | The ICE or connection state reached `failed`. |
| Never connected | The connection ended without reaching `connected`. |
| Connection interrupted | ICE went `disconnected`, even if it recovered. |
| ICE candidate errors | The browser couldn't reach or use a STUN or TURN server. These are harmless if another route worked. |
| Relayed through TURN / Relayed over TCP | Media went through a TURN relay. When the relay is reached over TCP or TLS, it's a warning, because TCP turns loss into jitter. |
| High round-trip time | Median round trip over 250 ms, or any over 1 s. |
| Low send bandwidth | The browser estimated under 100 kbps of upload room after the first 5 seconds. |
| Packet loss receiving audio/video | Average loss of 2% or more (an error at 5%), or 15% in any one interval. |
| High jitter receiving audio/video | 95th-percentile jitter over 50 ms. |
| Large jitter buffer | Median jitter buffer delay over 250 ms. |
| Audio concealment | On average, over 3% of received audio was concealed (an error at 10%). |
| Gaps receiving audio/video | Nothing arrived for 3 seconds or more. |
| Microphone is silent | Audio was sent, but the microphone level stayed at zero. |
| Upstream packet loss | The server reported losing over 2% on average, or over 5% at the 95th percentile, of what the browser sent. |
| Video froze / Video quality limited | Video froze, or the browser lowered quality because of bandwidth or CPU. |
| Camera or microphone request failed | `getUserMedia` failed, for example because permission was denied or no device matched. |

"No problems found" means none of these checks tripped. The cause may still be on the server or agent side, so check the session itself.

### Expert Analysis

If LiveKit Inference is turned on for the project selected in the main window (**Settings › AI**), this tab asks a model to review the dump as a WebRTC support engineer would. It returns:

- a short assessment in plain language
- the likely causes, ranked as *likely*, *possible* or *unlikely*, each with the evidence it's based on and what to check next
- questions to ask the customer that would confirm or rule out a cause

Nothing is sent until you click **Run expert analysis**. The tab shows the estimated cost first, and you can expand **Evidence to send** to see exactly what goes to the model. That's a summary built from the dump: each connection's route, candidates, state changes and statistics (with a coarse timeline), plus the rule-based findings. It leaves out IP addresses, the page address, SDP and credentials. The request is billed to that project and counts against the monthly limit in **Settings › AI**. The result is saved, so reopening the same dump shows it again.

Treat the answer as a second opinion: the model can be wrong, so check each cause against the charts before you tell the customer. A reply that cites evidence it wasn't given is rejected.

### Connection

How the browser reached LiveKit:

- **Route.** The candidate pair that carried media, for example `srflx → host over UDP · wifi`. `host` and `srflx` are direct routes. `relay` means a TURN server, and *relay reached over TCP/TLS* means UDP was probably blocked.
- **Candidates gathered.** Which kinds of route the browser found. If a connection failed and no `relay` candidates were gathered, the browser had no fallback through a strict firewall.
- **ICE servers.** The STUN and TURN servers from the configuration, without credentials.
- **Round trip and available send bandwidth** over time.
- **State changes.** Every ICE, connection, gathering, and signaling state change, with times.

### Streams

Charts for each audio and video stream, all on the same time axis, so a spike in one lines up with the others.

Charts with a known good range are coloured: the line is green where the value is good, orange where it's fair, and red where it's poor, over matching shaded zones. The limits are shown next to each chart's title and match the Findings rules:

| Metric | Good | Fair | Poor |
| --- | --- | --- | --- |
| Packet loss, loss at receiver | ≤ 1% | ≤ 5% | > 5% |
| Jitter, jitter at receiver | ≤ 30 ms | ≤ 50 ms | > 50 ms |
| Jitter buffer delay | ≤ 100 ms | ≤ 250 ms | > 250 ms |
| Concealment | ≤ 2% | ≤ 10% | > 10% |
| Round trip | ≤ 150 ms | ≤ 300 ms | > 300 ms |
| Available send bandwidth | ≥ 200 kbps | ≥ 100 kbps | < 100 kbps |
| Frame rate | ≥ 24 fps | ≥ 15 fps | < 15 fps |

Bitrate, audio level and resolution have no fixed good range, so they stay blue.

- **Received audio** (subscriber): bitrate, packet loss, jitter, jitter buffer delay, concealment, and audio level.
- **Sent audio** (publisher): bitrate, the microphone level, and the loss, jitter, and round trip the server reported back.
- **Video:** frame rate and resolution, plus freezes and quality limits.

### Timeline

The peer connection's full update log: offers and answers with their SDP, ICE candidates, state changes, and errors. Search it with the field at the top. Individual candidates are hidden by default. The camera and microphone requests are listed above the log.

### All Stats

Every stats object in the dump, as the browser reported it. Select an object to see its properties, and select a property with a chart icon to plot it. Use this for anything the other tabs don't cover.

## Reading it by symptom

| The user says… | Look at |
| --- | --- |
| "The agent sounded robotic or choppy." | **Subscriber → Streams**, received audio: packet loss, jitter, and concealment at the time they gave. Concealment going up with loss means the network dropped packets. Concealment going up with jitter but no loss means packets arrived too unevenly. |
| "The agent couldn't hear me" or "kept interrupting." | **Publisher**: is the microphone level above zero? Is there upstream packet loss? A silent microphone means a device or permission problem, not the network. |
| "There was a long delay." | Round trip on **Connection**, and jitter buffer delay on **Streams**. A TCP relay adds both. If neither is high, the delay is probably in the agent (LLM, TTS); check the session's latency in Observer. |
| "It kept dropping." | **Connection → State changes**, and gaps on **Streams**. Compare the times with what the user was doing (switching Wi-Fi, a VPN reconnecting, the laptop sleeping). |
| "It wouldn't connect." | **Findings** for *Never connected* or *Connection failed*, then the candidates and ICE candidate errors. No relay candidates on a corporate network usually means TURN is blocked. |
| "My microphone didn't work." | **Findings** for *Camera or microphone request failed*, and the device requests on **Timeline**. |

## Lining it up with the session

The dump's times come from the user's computer clock, which is usually within a second of real time. To compare:

1. Open the session in Observer (Quick Jump, ⌘K, with the room name or `RM_…` ID).
2. Find the moment on the session's transcript or spectrogram, and the same clock time in the dump.
3. Loss or concealment in the dump at the same moment as glitches in LiveKit's recording points to the network between the user and LiveKit. If the recording sounds clean but the user heard glitches, the problem was on the user's downlink or device. If the recording also has the glitch on the agent's channel and the dump is clean, look at the agent and TTS (for example, Observer's **TTS static** check).

For SIP calls there's no browser, so there's no dump. Use a packet capture instead (**File › Add Packet Capture…**).

## Limits

- **Chromium only.** Firefox's `about:webrtc` and Safari's logs aren't supported.
- **Standard stats only.** Very old Chrome versions that report only the legacy `goog…` statistics show their update log, but no streams or findings.
- **About one sample per second.** Problems shorter than a second blur into one sample.
- **The last ~16 minutes in the webrtc-internals dump.** Use the rtcstats dump for longer calls.
- **The thresholds are rules of thumb.** A finding is a pointer to the right chart, not a verdict. Always check the chart.
