Secure Linux release keys (public keys only)

This folder holds the PUBLIC keys that Secure Linux releases are checked against.
Every file named *.asc here is a trusted public key. revoked.txt lists keys that were withdrawn.

- Nothing secret is ever kept here. A private key in this folder makes every check refuse.
- While this folder has no *.asc key, signing is "not set up yet": updates are checked the way
  they always were (each file's SHA-256 against the published list).
- Once a key is here, an update from any source (GitHub, a home server, a USB stick) is used only
  when its release.json.sig and payload-files.json.sig were made with one of these keys.

The kit's maker adds keys with signing-tools/sign-release.sh make-key on his own computer.
Check a release by hand:  secure-linux-release-verify check --from FOLDER
