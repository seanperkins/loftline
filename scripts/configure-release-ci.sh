#!/bin/zsh
# One-time setup of signing for .github/workflows/release.yml. Run it yourself: it uses your keychain export and your
# GitHub login, and it writes to GitHub.
#
#   1. Keychain Access -> login keychain -> "My Certificates" -> select
#      "Developer ID Application: Sean Perkins (HH3SJBAS42)" (the one with a private key, not another team's item)
#      -> File > Export Items... -> Personal Information Exchange (.p12), with any new password.
#   2. scripts/configure-release-ci.sh /path/to/exported.p12
#
# The signing p12 is re-wrapped under a freshly generated passphrase, checked to be a Developer ID identity WITH its
# private key, and only then pushed to a PRIVATE vault repo. The runner reads the vault with a read-only deploy key made
# new on every run. Notarisation uses the App Store Connect API key (checked-in id and issuer; only the .p8 is secret).
#
# Adapted from rootkit-game's tools/configure_macos_ci.sh. Do NOT run that one for LoftLine: it hard-codes
# seanperkins/rootkit-macos-certs and would re-wrap the p12 there, breaking rootkit-game's MACOS_CERT_PASSWORD.
#
# Variables: REPO (default seanperkins/loftline), VAULT (default seanperkins/loftline-macos-certs), ASC_KEY_ID
# (default 4XBH56T7RS), MACOS_IDENTITY (default the Developer ID above), OPENSSL (an OpenSSL 3.x binary).
set -euo pipefail

REPO="${REPO:-seanperkins/loftline}"
VAULT="${VAULT:-seanperkins/loftline-macos-certs}"
ASC_KEY_ID="${ASC_KEY_ID:-4XBH56T7RS}"
IDENTITY="${MACOS_IDENTITY:-Developer ID Application: Sean Perkins (HH3SJBAS42)}"
KEY_TITLE="loftline GitHub Actions (read-only)"

# First, before anything else is looked at: never write to another project's vault or secrets.
for target in "$REPO" "$VAULT"; do
  case "$target" in
    *rootkit*)
      print -u2 -r -- "refusing to use $target: it belongs to rootkit-game, and this script would replace its signing material"
      exit 1 ;;
  esac
  [[ $target =~ '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' ]] || { print -u2 -r -- "not an owner/name repo: $target"; exit 1; }
done

P12="${1:?usage: scripts/configure-release-ci.sh <exported-signing.p12>}"
P8="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

# OpenSSL 3.x is required: -legacy and -macalg sha1 control the RC2-40 encoding macOS `security import` accepts, and
# /usr/bin/openssl on macOS is LibreSSL, which has neither flag.
OPENSSL="${OPENSSL:-openssl}"
if ! "$OPENSSL" version 2>/dev/null | grep -q "OpenSSL 3"; then
  print -u2 -r -- "need OpenSSL 3.x, got: $("$OPENSSL" version 2>&1 || true)"
  print -u2 -r -- "try: brew install openssl@3 && OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl $0 $P12"
  exit 1
fi
[[ -f $P12 ]] || { print -u2 -r -- "no such file: $P12"; exit 1; }
[[ -f $P8 ]] || { print -u2 -r -- "no App Store Connect key at $P8 (expected key id $ASC_KEY_ID)"; exit 1; }
read -rs "P12PW?original p12 password (the one you set in Keychain Access): "
print
[[ -n $P12PW ]] || { print -u2 -r -- "empty password"; exit 1; }

umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- re-wrap under a generated passphrase ------------------------------------
# Passphrases travel in the environment (-passin env:...), not in argv, where any process could read them.
VLT_PW="$("$OPENSSL" rand -hex 24)"
export P12PW VLT_PW
# Keychain Access exports a legacy RC2/3DES p12 that OpenSSL 3.x refuses without -legacy: try modern, then legacy on the
# input side only. Every stage uses files: OpenSSL 3.6's `pkcs12 -export` cannot read a PEM stream from stdin.
if ! "$OPENSSL" pkcs12 -in "$P12" -passin env:P12PW -nodes -out "$TMP/raw.pem" 2>"$TMP/rw.err"; then
  "$OPENSSL" pkcs12 -legacy -in "$P12" -passin env:P12PW -nodes -out "$TMP/raw.pem" 2>"$TMP/rw.err" \
    || { print -u2 -r -- "could not read the p12; openssl said:"; cat "$TMP/rw.err" >&2; exit 1; }
  print "read the p12 with -legacy (Keychain Access legacy encoding)"
fi
# macOS `security import` accepts only -legacy -macalg sha1 on a real PKCS#12; OpenSSL 3 defaults and bare -legacy both
# fail with "MAC verification failed".
"$OPENSSL" pkcs12 -legacy -macalg sha1 -export -in "$TMP/raw.pem" -passout env:VLT_PW -out "$TMP/macos-signing.p12" 2>"$TMP/rw2.err" \
  || { print -u2 -r -- "could not re-export the p12; openssl said:"; cat "$TMP/rw2.err" >&2; exit 1; }

# --- verify WHAT was exported before anything is pushed ----------------------
# Catches another team's item or a certificate exported without its key here, not as a burnt CI run.
"$OPENSSL" pkcs12 -legacy -in "$TMP/macos-signing.p12" -passin env:VLT_PW -nodes -out "$TMP/verify.pem" 2>"$TMP/verify.err" \
  || { print -u2 -r -- "could not verify the re-wrapped p12; openssl said:"; cat "$TMP/verify.err" >&2; exit 1; }
SUBJECTS="$("$OPENSSL" crl2pkcs7 -nocrl -certfile "$TMP/verify.pem" | "$OPENSSL" pkcs7 -print_certs -noout)"
[[ $SUBJECTS == *"Developer ID Application"* ]] \
  || { print -u2 -r -- "WRONG IDENTITY: $SUBJECTS"; print -u2 -r -- "expected a 'Developer ID Application' certificate"; exit 1; }
grep -qE "BEGIN (RSA )?PRIVATE KEY" "$TMP/verify.pem" \
  || { print -u2 -r -- "no private key in the p12: was the certificate exported without its key?"; exit 1; }
print "verified: Developer ID Application identity with its private key"

# --- the vault: private, created if missing ----------------------------------
if gh repo view "$VAULT" >/dev/null 2>&1; then
  visibility="$(gh repo view "$VAULT" --json visibility --jq .visibility)"
  [[ $visibility == PRIVATE ]] || { print -u2 -r -- "$VAULT is $visibility; the signing vault must be private"; exit 1; }
else
  gh repo create "$VAULT" --private --description "Encrypted signing identity for $REPO releases"
fi
gh repo clone "$VAULT" "$TMP/vault" -- --depth=1
cp "$TMP/macos-signing.p12" "$TMP/vault/macos-signing.p12"
( cd "$TMP/vault" \
  && git checkout -q -B main \
  && git config user.name "Sean Perkins" \
  && git config user.email "sean@mobility-labs.com" \
  && git add macos-signing.p12 \
  && git commit -q -m "macos-signing.p12: $(date -u +%Y-%m-%d)" \
  && git push -q origin HEAD:main )
print "pushed the re-wrapped p12 to $VAULT"

# --- a NEW read-only deploy key, CI's way into the vault ---------------------
# Always a new pair: reusing whatever key is already on the vault would leave the secret holding a private key that does
# not match it. The previous keys with this title are retired once the secret below is in place.
ssh-keygen -q -t ed25519 -f "$TMP/macos_certs_ed25519" -N "" -C "loftline-release-ci"
old_keys=(${(f)"$(gh repo deploy-key list -R "$VAULT" --json id,title --jq ".[] | select(.title == \"$KEY_TITLE\") | .id")"})
gh repo deploy-key add "$TMP/macos_certs_ed25519.pub" -R "$VAULT" -t "$KEY_TITLE"
print "added a read-only deploy key to $VAULT"

# --- the secrets: only in $REPO, and never on a command line -----------------
gh secret set MACOS_CERTS_DEPLOY_KEY --repo "$REPO" < "$TMP/macos_certs_ed25519"
print -rn -- "$VLT_PW" | gh secret set MACOS_CERT_PASSWORD --repo "$REPO"
base64 < "$P8" | gh secret set ASC_KEY_CONTENT --repo "$REPO"
print -rn -- "$IDENTITY" | gh secret set MACOS_IDENTITY --repo "$REPO"

for id in $old_keys; do
  gh repo deploy-key delete "$id" -R "$VAULT" && print "retired the previous deploy key $id"
done

print "secrets set in $REPO:"
print "  MACOS_CERTS_DEPLOY_KEY  (read-only key into $VAULT)"
print "  MACOS_CERT_PASSWORD     (the generated vault passphrase)"
print "  ASC_KEY_CONTENT         (base64 of AuthKey_${ASC_KEY_ID}.p8)"
print "  MACOS_IDENTITY"
print "check with: gh secret list -R $REPO"
