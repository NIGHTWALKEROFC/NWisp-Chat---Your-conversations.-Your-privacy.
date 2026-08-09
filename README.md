<div align="center">

# 🔒 Secure Chat & Stories

**Private messaging that disappears. Stories that fade. No feed, no ads, no data mining.**

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Firebase](https://img.shields.io/badge/Backend-Firebase-FFCA28?logo=firebase&logoColor=black)](https://firebase.google.com)
[![Codemagic](https://img.shields.io/badge/CI%2FCD-Codemagic-4297F7)](https://codemagic.io)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

</div>

---

## ✨ What is this

A privacy-first mobile app combining **WhatsApp-style encrypted messaging** with **Instagram-style 24-hour Stories** — built to disappear by design. Messages live on the server for a maximum of 24 hours. Stories vanish after a day. No feed, no permanent posts, no ads, no premium tier.

## 🧩 Features

| | |
|---|---|
| 🔑 | Username-based identity — email/phone stay private |
| 💬 | 1:1 and group chats, end-to-end encrypted via the Signal Protocol |
| 📸 | Photos, videos (≤20MB), documents, reactions, replies |
| ⏳ | 24-hour server-side message retention, auto-deleted |
| 📱 | 24-hour Stories with custom viewer circles (Friends / Family / Work) |
| 🕵️ | Granular privacy controls — last seen, read receipts, discoverability |

## 🏗️ Architecture

Flutter (Android + iOS)
│
├── Firebase Auth → identity
├── Cloud Firestore → messages, stories, metadata (TTL auto-delete)
├── Firebase Storage → media (photos/videos)
├── Cloud Functions → push notification relay
└── Signal Protocol → end-to-end encryption (client-side only)

No self-hosted server — everything runs on Firebase's managed, free-tier infrastructure.

## 🚀 Getting started

1. Clone the repo and run `flutter pub get` inside `mobile/`.
2. Create a Firebase project and run `flutterfire configure`.
3. Deploy `firestore.rules` and `storage.rules`.
4. Enable Firestore TTL policies on `expiresAt` for `messages` and `stories`.
5. `flutter run`.

Full setup walkthrough: see [`docs/SETUP.md`](docs/SETUP.md).

## 🔐 Security

- All message content is encrypted client-side with the Signal Protocol before it ever reaches Firebase — the server only ever sees ciphertext.
- Firestore Security Rules enforce conversation membership and per-user write scoping.
- Report vulnerabilities privately — do not open a public issue for security bugs.

## 📦 Builds

Handled via [Codemagic](https://codemagic.io) — see `codemagic.yaml`. Every push to `main` triggers Android and iOS builds.

## 📄 License

MIT — see [`LICENSE`](LICENSE).

---

<div align="center">
Built by <a href="https://github.com/NIGHTWALKEROFC">NIGHTWALKEROFC</a>
</div>
