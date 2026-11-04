# Secure Linux netboot

## One manual step

GitHub only lets apps with extra permission create workflow files directly, so the automated publish
could not create `.github/workflows/build-flipper-fap.yml`. The same workflow is included here as
`flipper/build-flipper-fap.yml`. To enable the Flipper app build:

1. Open this repository on GitHub and choose **Add file → Create new file**.
2. Name the file `.github/workflows/build-flipper-fap.yml`.
3. Paste the contents of `flipper/build-flipper-fap.yml`, then choose **Commit changes**.
4. Open **Actions**, select **Build the Boot2Flipper app (Flipper Zero)** (`build-flipper-fap`), then
   choose **Run workflow**.

After this one-time setup, the workflow also runs monthly.

Install **The Complete Secure Linux Package** on a PC **without a USB stick**: the computer downloads
everything itself. Works two ways:

- **With a Flipper Zero** (RogueMaster firmware + the Boot2Flipper app): the Flipper pretends to be a
  tiny USB stick holding only a network loader; the PC starts from it and this menu appears.
- **With anything else that can boot iPXE**: a netboot.xyz stick, your own iPXE setup, or a PC that
  already network-boots - chainload
  `https://raw.githubusercontent.com/MattyBoyMan/secure-linux-netboot/main/menu.ipxe`
  and you get the same menu.

## The 4-press flow

1. **Boot-menu key** on the PC (F12 on Dell/Lenovo, F9 on HP, F8 on Asus, Esc on many others, Option on
   an Intel Mac) and pick the Flipper ("FLIPPER Boot2Flipper") or your iPXE device.
2. **Enter** on "Install Secure Linux (recommended)" - or just wait 10 seconds; the menu starts the
   recommended option by itself.
3. **Answer the installer's questions.** Nothing is chosen for you beyond that default: the installer
   checks the computer and recommends a setup, asks which drive to erase (you type `ERASE`), asks for
   your login name and password, and asks about Wi-Fi. That is the same setup screen the USB stick
   shows.
4. **Walk away.** The computer installs, encrypts the drive and turns off. At the first start the apps
   install themselves and the beginner's guide opens.

## What the menu offers

| Choice | What it is |
|---|---|
| Install Secure Linux (recommended) | Fedora 44 from Fedora's own mirrors, with the kit's installer |
| Lighter Debian | Debian 13 (64-bit) for PCs with under 2 GB of memory |
| Very old 32-bit PCs | Debian 12 (32-bit), supported until June 2028 |
| Fix or rescue a computer | the netboot.xyz tools |
| More systems and tools | the full netboot.xyz menu |
| iPXE shell | for experts |
| Reboot | gives the computer back unchanged |

## Requirements

- A 64-bit PC for the recommended option (the Debian entries cover smaller and 32-bit-only PCs).
- **Internet on the target PC** while installing: a network cable or a phone on USB tethering is the
  reliable way - the boot files and the installer itself load before any Wi-Fi question can run.
  Once the installer is up, its Wi-Fi question can connect Wi-Fi for everything after.
- **Boot menu access** on the PC (UEFI or legacy - both work).
- The Flipper is optional; see above.

## Privacy

The files in this repository are **generic installer files only**. There are no names, no password
hashes and no Wi-Fi passwords in them - there is nothing personal to leak. Your login name and
password are asked on the installer's own screen, on the computer being set up; the password is
turned into a one-way hash in memory and never sent anywhere. The test suite
(`tests/netboot/run.sh` in the source kit) checks every published file for secrets on every change.

## Where everything comes from

- Fedora: `download.fedoraproject.org` (redirects to a nearby mirror - that is normal).
- Debian: `deb.debian.org`.
- The installer files and the Secure Linux payload: this repository (`raw.githubusercontent.com` for
  the installer files, the repository download for the payload).
- Rescue tools: `netboot.xyz`.

## The Flipper app (Boot2Flipper)

Boot2Flipper has no prebuilt releases. After the one manual step above, a GitHub Action in this
repository (`.github/workflows/build-flipper-fap.yml`) builds it from source with the RogueMaster
firmware toolchain, monthly and on demand, and attaches `boot2flipper.fap` to this repository's
**"flipper-fap" release**. Download that file, put it on the Flipper's SD card under `apps/USB/`,
copy the `flipper/` folder's contents to the SD card root, add the two iPXE files from
<https://boot.ipxe.org>, and follow `flipper/README-FLIPPER.txt`.

## Honest limits

- **Secure Boot and the Flipper**: the iPXE the Flipper serves is not Microsoft-signed, so a PC with
  Secure Boot **on** will refuse to start from the Flipper. Turn Secure Boot off in the BIOS first.
  (Booting through netboot.xyz's *signed* images is the Secure-Boot-on path; the menu's Fedora entry
  then uses Fedora's own shim so the rest of the chain stays verified.)
- **The Debian entries need Secure Boot off**: their installer kernel is loaded directly, not through
  a shim. You can turn Secure Boot back on after the Fedora install; Debian's own shim flow is a
  separate manual setup.
- **The first load from a Flipper is slow** (1-2 minutes): it is a tiny computer sending the loader
  over USB. After that, everything downloads at internet speed.
- **Wi-Fi alone can't start the process**: iPXE and the installer download step need a cable or USB
  tethering first. The installer connects Wi-Fi itself once it is running.
- If the payload download ever fails mid-install, the installer says so loudly and leaves a marker
  (`/root/secure-linux-payload-missing`): the computer still gets a working plain Fedora, and nothing
  is silently half-done.

## For maintainers

This repository is generated from the Secure Linux kit by `netboot/render-netboot.sh`
(`netboot/dist/` is exactly this tree). The kit's own templates stay the single source of truth;
the renderer fails rather than drifting from them. Tests: `bash tests/netboot/run.sh`.

**Every file here is plain text.** `payload/` is the Fedora setup source tree (`setup.sh`, `bin/`,
`steps/` and the rest); `payload/debian/` is the Debian setup source tree. There are no uploaded
archives or other binary artifacts, so every file can be published through GitHub's text-file API.
At install time the computer downloads GitHub's own whole-repository archive as transport, unpacks
its `secure-linux-netboot-main/` folder and copies the appropriate `payload/` subtree into place.
