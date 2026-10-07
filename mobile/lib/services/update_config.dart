/// Settings for the update system.
///
/// WHERE THE APP LOOKS FOR UPDATES: the signed file that GitHub Actions makes
/// from update/update.json (see .github/workflows/sign-update.yml). The address
/// below must be the "raw" address of update/update.signed.json in YOUR
/// repository. Open it in a browser to check — you should see text starting
/// with {"alg":"ed25519" ... . The repository must be public for the app to read
/// it. You can also override it when building, without touching code:
///   --dart-define=UPDATE_URL=https://...
const String kUpdateManifestUrl = String.fromEnvironment(
  'UPDATE_URL',
  defaultValue:
      'https://raw.githubusercontent.com/NIGHTWALKEROFC/NWisp-Chat---Your-conversations.-Your-privacy./main/update/update.signed.json',
);

/// The fingerprint(s) of the key this app is signed with — the "copy check".
/// A copy that was edited and re-signed (MT Manager, apktool …) has a different
/// fingerprint and the app refuses to run. Several fingerprints can be listed,
/// separated by commas. Leave it empty to switch the copy check off.
///   --dart-define=EXPECTED_CERT_SHA256=ab12...,cd34...
/// (Only works if every build is signed with the SAME key — see the keystore
/// steps in the update guide.)
const String kExpectedCertSha256 = String.fromEnvironment('EXPECTED_CERT_SHA256');

/// The PUBLIC half of the update-signing key, hidden by XOR so it isn't one
/// plain 32-byte string a search tool can spot. It is not a secret — it can
/// only CHECK signatures, never make them. The private half lives only in your
/// GitHub secret UPDATE_SIGNING_KEY.
const List<int> kUpdateKeyMask = [
  90, 195, 23, 233, 43, 132, 109, 241, 90, 195, 23, 233, 43, 132, 109, 241,
  90, 195, 23, 233, 43, 132, 109, 241, 90, 195, 23, 233, 43, 132, 109, 241,
];

const List<List<int>> kUpdateKeysMasked = [
  // Key 1
  [150, 82, 183, 158, 11, 147, 33, 100, 24, 194, 133, 83, 37, 25, 50, 50, 25, 153, 227, 54, 195, 224, 86, 145, 234, 136, 12, 88, 79, 114, 40, 42],
  // Key 2 — spare slot for changing keys later without breaking old apps.
];

List<List<int>> updatePublicKeys() => [
      for (final k in kUpdateKeysMasked) [for (var i = 0; i < k.length; i++) k[i] ^ kUpdateKeyMask[i]],
    ];
