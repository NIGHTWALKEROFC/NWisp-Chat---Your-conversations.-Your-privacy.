# NWisp

Privacy-focused messaging app with disappearing content by design. 1:1 encrypted chat and 24-hour stories, no dedicated backend server.

## Stack

- **Frontend:** Flutter (Dart) — package `com.nightwalker.securechat`
- **Auth & metadata:** Firebase Auth (email/password), Cloud Firestore (users, contacts, requests, conversation metadata, stories, reports)
- **Messaging & media:** Supabase (Postgres relay table for message delivery, Storage for avatars/chat media/stories)
- **CI/CD:** Codemagic — builds release APKs from this repo

## Architecture

Firebase only handles authentication and non-message metadata. Message content never touches Firebase and is never stored server-side long-term.

- **Encryption:** every message is end-to-end encrypted on-device before sending — X25519 (ECDH) between the sender's and recipient's static key pairs, HKDF, AES-256-GCM. Each account has one identity key pair; the private key stays in the OS keystore (`flutter_secure_storage`), the public key is published to `users/{uid}.publicKey` in Firestore so others can encrypt to it.
- **Delivery:** encrypted messages are inserted as a single row into a Supabase table, `message_relay`. The recipient's device picks it up over Supabase Realtime (or on next app open, via a catch-up query), decrypts it, and deletes the row. Nothing about message content is meant to sit in Supabase for long.
- **Storage:** decrypted messages are kept only in an on-device SQLite database, re-encrypted with a separate device-local AES key that never leaves the device. This is the only place message content lives long-term.
- **Disappearing messages:** the auto-delete timer (app-wide default or per-chat override) is enforced on-device, since there is no server-side copy to expire.

Known limitation: the encryption scheme uses static keys, not a full Double Ratchet, so there is no per-message forward secrecy. `libsignal_protocol_dart` is a dependency for a future upgrade to full Signal-style ratcheting.

## Features

- Email/password auth with unique usernames
- Contact system: username search, friend-style requests, blocking (enforced — a blocked sender's messages are refused before they're relayed)
- 1:1 chat: text, replies, reactions, typing indicators, delivered/read receipts, online/last-seen presence
- Message actions: pin, copy, delete-for-me, delete-for-everyone (removes it from the peer's device too)
- Auto-delete messages: app-wide default with optional per-chat override
- Per-chat settings: mute, auto-delete override, clear chat (both sides), block/report
- Stories: disappear after 24 hours
- Custom accent color (HSV picker + presets), light/dark/system theme
- App-lock PIN with optional hint and password-based recovery
- In-app Help Centre and developer contact
- In-app Privacy Policy

## Project structure

```
mobile/                  Flutter app
  lib/
    services/             Auth, crypto, message relay, local message store, contacts, presence, etc.
    screens/               UI screens
    models/                 Data models
    widgets/                 Shared widgets
scripts/                 Node script for scheduled Stories cleanup
supabase/functions/      Edge function for signed media URLs
firestore.rules          Firestore security rules
firebase.json            Firebase project config
codemagic.yaml           CI build config
```
