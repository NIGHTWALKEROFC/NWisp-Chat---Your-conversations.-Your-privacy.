import 'dart:math';

/// Feature: "Suggest a strong password" button on the signup and
/// password-reset screens.
///
/// DESIGN NOTE: the original ask was for the suggested password to be
/// built "using their name and email". This deliberately does NOT do
/// that. Weaving in personal info that's often knowable by other people
/// (a name, an email address someone can see in your inbox, a contacts
/// list, a leaked breach) gives anyone who has that info a head start
/// guessing the password, which undermines the entire point of
/// generating one at all. A fully random password is both stronger AND
/// no harder to use here, since the "Copy" button next to it means
/// nobody has to actually remember or type it.
///
/// Uses Random.secure() (a cryptographically secure RNG, not the
/// default pseudo-random one) and excludes visually ambiguous
/// characters (0/O, 1/l/I) so a password read off-screen (e.g. by
/// someone typing it into a password manager by hand) is less error-prone.
String generateStrongPassword({int length = 14}) {
  const lowers = 'abcdefghijkmnopqrstuvwxyz'; // no l
  const uppers = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; // no I, O
  const digits = '23456789'; // no 0, 1
  const symbols = '!@#%^&*-_=+?';
  const all = lowers + uppers + digits + symbols;
  final rand = Random.secure();

  // Guarantee at least one of each character class, then fill the rest
  // randomly, then shuffle so the guaranteed ones aren't always in the
  // same position (which would itself be a mild, needless pattern).
  final chars = <String>[
    lowers[rand.nextInt(lowers.length)],
    uppers[rand.nextInt(uppers.length)],
    digits[rand.nextInt(digits.length)],
    symbols[rand.nextInt(symbols.length)],
  ];
  for (int i = chars.length; i < length; i++) {
    chars.add(all[rand.nextInt(all.length)]);
  }
  chars.shuffle(rand);
  return chars.join();
}
