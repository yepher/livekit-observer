#!/bin/sh
# One-time setup for .github/workflows/release.yml. Run it on your Mac from the repo root:
#
#   scripts/setup-release-secrets.sh
#
# 1. Creates the Sparkle update key (or reuses the one already in your Keychain), writes its public half
#    into Config/Info.plist, and stores the private half as the SPARKLE_PRIVATE_KEY secret.
# 2. Stores your Developer ID Application certificate, exported from Keychain Access as a .p12.
# 3. Stores an App Store Connect API key (.p8) for notarization.
#
# Secrets go to GitHub with `gh secret set` over stdin; nothing is printed or left on disk.
# Keep a backup of the Sparkle private key (Keychain item "Private key for signing Sparkle updates"):
# if you lose it, installed copies can no longer update.
set -eu
cd "$(dirname "$0")/.."
SPARKLE_VERSION=2.10.1
command -v gh > /dev/null || { echo "Install the GitHub CLI: brew install gh"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "== Sparkle update key"
curl -sSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" | tar xJ -C "$work"
"$work/bin/generate_keys" > /dev/null  # creates the key, or does nothing if it already exists
public_key="$("$work/bin/generate_keys" -p)"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $public_key" Config/Info.plist
echo "Public key in Config/Info.plist: $public_key"
(umask 077; "$work/bin/generate_keys" -x "$work/sparkle.key" > /dev/null)
gh secret set SPARKLE_PRIVATE_KEY < "$work/sparkle.key"

echo
echo "== Developer ID Application certificate"
echo "In Keychain Access, under My Certificates, right-click \"Developer ID Application: Chris Wilson (WDCGJTU726)\","
echo "choose Export, and save it as a .p12 with a password."
printf "Path to the .p12: "; read -r p12
printf "Its password: "; stty -echo; read -r p12_password; stty echo; echo
base64 -i "$p12" | gh secret set DEVELOPER_ID_P12_BASE64
printf '%s' "$p12_password" | gh secret set DEVELOPER_ID_P12_PASSWORD
echo "Stored. You can delete $p12 now."

echo
echo "== App Store Connect API key, for notarization"
echo "At https://appstoreconnect.apple.com/access/integrations/api create a Team key with the Developer role"
echo "and download its .p8 (Apple lets you download it once)."
printf "Path to the .p8: "; read -r p8
printf "Key ID: "; read -r key_id
printf "Issuer ID: "; read -r issuer_id
base64 -i "$p8" | gh secret set NOTARY_KEY_P8_BASE64
printf '%s' "$key_id" | gh secret set NOTARY_KEY_ID
printf '%s' "$issuer_id" | gh secret set NOTARY_ISSUER_ID

echo
echo "Done. Commit Config/Info.plist, then release with: git tag v0.2.0 && git push origin v0.2.0"
