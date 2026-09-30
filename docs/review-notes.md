# Review notes

Text to paste into App Store Connect and Play Console when Freenet AppKit goes to review. Fill in the two links before the first submission.

| Placeholder | What to put there |
| --- | --- |
| `<VIDEO_LINK>` | An unlisted link to a screen recording of the steps below, on an iPhone and on an Android phone |
| `<SUPPORT_EMAIL>` | The monitored support address, the same one the support page gives |

## App Review notes

Paste into App Store Connect → the app → App Review Information → Notes. Sign-in required: No.

```text
Freenet AppKit runs a Freenet peer inside the app. Freenet is a peer-to-peer network: there is no central server. The app has two tabs:

- River: a group chat. Rooms and messages are stored on the Freenet network.
- Atlas: a directory of sites published on Freenet.

Both are web apps. The embedded peer downloads them from the network and serves them to the app's WKWebView on 127.0.0.1. They run only inside the app and use no native APIs beyond in-app message alerts. The peer runs only while the app is open, and it stops when the app goes to the background.

The first connection to the network can take up to a minute. The peer uses UDP. On a network that blocks UDP, the app shows "Freenet could not reach the network" with a Try again button. Mobile data or another Wi-Fi network works in that case.

No account or sign-in is needed. To try the app:
1. Start the app and tap Continue on the welcome screen.
2. Wait for River to load.
3. Tap the button to create a room, give it a name, and send a message.
4. Open the Atlas tab to browse the directory.

A recording of these steps: <VIDEO_LINK>

Encryption: the peer uses standard algorithms (X25519, AES-GCM, ChaCha20, Ed25519, BLAKE3) to secure its connections and stored data.

Contact: <SUPPORT_EMAIL>
```

## Play testing instructions

In Play Console → App content → App access, choose "All functionality is available without special access". Paste these notes into the release's testing instructions.

```text
Freenet AppKit runs a Freenet peer inside the app. Freenet is a peer-to-peer network with no central server. The River tab is a group chat and the Atlas tab is a directory of Freenet sites. Both are web apps that the embedded peer downloads from the network and shows in a WebView on 127.0.0.1. The peer runs only while the app is open.

The first connection can take up to a minute. The peer uses UDP. If a network blocks UDP, the app says so and offers Try again. Mobile data works in that case.

No sign-in is needed. Tap Continue on the welcome screen, wait for River to load, create a room and send a message, then open the Atlas tab.

Recording: <VIDEO_LINK>
Contact: <SUPPORT_EMAIL>
```

## Before submitting

| Item | iOS | Android |
| --- | --- | --- |
| Record the screen recording and fill in `<VIDEO_LINK>` | iPhone | Android phone or emulator |
| Store listing name "Freenet AppKit", identifier `freenet.appkit` | App Store Connect app record | Play Console app |
| Encryption questions answered | App Store Connect, first build | – |
| Privacy answers | App Privacy | Data safety form |
| Support and terms pages live at the URLs in `AppInfo` | Both | Both |
