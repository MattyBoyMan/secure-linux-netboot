THE FLIPPER ZERO AND NETBOOT - install Secure Linux without a USB stick
========================================================================

The Flipper pretends to be a tiny USB stick that holds only a network boot
loader (iPXE). The computer starts from it, then downloads everything else
over the internet. The actual Linux install is the same one the real USB
stick does, with the same questions.

WHAT YOU NEED
  - a Flipper Zero with the RogueMaster firmware
  - the Boot2Flipper app on the Flipper (see step 1)
  - the iPXE boot files on the SD card (see step 2)
  - internet for the computer being set up: a network cable, or a phone
    connected by USB with USB tethering on (the computer downloads Linux
    itself; the installer's own Wi-Fi question can take over after that)

EASIEST WAY: USE THE PREP SCRIPT
  Windows: right-click prepare-flipper.ps1 and choose Run with PowerShell.
  Linux/macOS: run  bash prepare-flipper.sh  from this folder.
  The script lists removable drives with labels and sizes, asks you to pick the
  SD card by number, and confirms the exact writes before touching the card.
  It then copies apps_data and badusb, downloads and checks the iPXE files,
  and installs the released Boot2Flipper app if one exists. If there is no app
  release yet, it shows the one manual GitHub step; run the script again after
  that step and it finishes the card automatically. No drive is guessed silently.
  The manual steps below are the alternative if you prefer them.

1. INSTALL THE APP
   Get boot2flipper.fap from this repository's "flipper-fap" release
   (it is built automatically from the Boot2Flipper source, once a month,
   by a GitHub Action - see .github/workflows/build-flipper-fap.yml).
   Use exactly boot2flipper.fap from that tag, not an unrelated latest release.
   The release records both source commit IDs and the file's SHA-256. Building
   against current RogueMaster source does not guarantee compatibility with
   every RogueMaster release; test the app with your exact firmware version.
   Copy the .fap to the SD card under  apps/USB/  (qFlipper or the
   Flipper mobile app does this), then find "Boot to Flipper" in the
   Flipper's app menu under USB.
   If there is no release yet, build it yourself: clone
   github.com/RogueMaster/flipperzero-firmware-wPlugins (recursively),
   drop the source of github.com/Stella-IT/boot2flipper into
   applications_user/boot2flipper, and run  ./fbt fap_boot2flipper .
   The finished app is under  build/f7-firmware-D/.extapps/ .

2. COPY THIS FOLDER TO THE SD CARD
   Copy the CONTENTS of this folder (the apps_data and badusb folders)
   to the ROOT of the Flipper's SD card. Then add the two iPXE boot files:
   download ipxe.efi and ipxe.lkrn from https://boot.ipxe.org and put them
   in  SD Card/apps_data/boot2flipper/ipxe/  (the folder is already here,
   with a note in it).
   The settings file apps_data/boot2flipper/config.b2f is already filled
   in: internet from DHCP, boot method UEFI, and this repository's menu
   as the chainload address. In the app, choose "Load Config" and pick
   config.b2f once; then "Save Config" so it sticks. If the file ever
   fails to load, set these in the app by hand instead:
     Boot Method:   UEFI
     Network:       DHCP
     Chainload:     https://raw.githubusercontent.com/MattyBoyMan/secure-linux-netboot/main/menu.ipxe

3. START THE COMPUTER FROM THE FLIPPER
   - Open the Boot2Flipper app on the Flipper and press Start.
   - Plug the Flipper into the computer.
   - Power the computer on and tap its boot-menu key:
         Dell, Lenovo ....... F12
         HP .................. F9
         Asus ................ F8
         most others ......... Esc or F12
         Intel Mac ........... hold Option
   - Pick the boot device called "FLIPPER Boot2Flipper" (or similar).
   - The menu appears with the recommended install highlighted. Press Enter
     to start it. The menu waits forever: nothing starts by itself.
   The first load from the Flipper is SLOW: it is a tiny computer sending
   the loader over USB, so give it 1-2 minutes. After that, everything
   comes over the internet at full speed.

HONEST NOTES
  - Secure Boot: the Flipper's iPXE is not Microsoft-signed, so on a PC
    with Secure Boot ON the Flipper stick will not start. Turn Secure Boot
    off in the BIOS first (the installer's own Secure Boot question later
    explains the trade-offs). The Fedora installer's shim entry in the
    menu keeps Secure Boot working for PCs that netboot through a signed
    iPXE (for example netboot.xyz's signed images).
  - The Debian entries also need Secure Boot OFF: their installer kernel
    is loaded directly, not through a shim.
  - The computer needs internet while installing. A cable or phone USB
    tethering always works; the installer's Wi-Fi question can connect
    Wi-Fi for the rest.
  - Only the tiny loader comes from the Flipper. Linux comes from Fedora's
    and Debian's official servers, and the installer files from this
    repository. Nothing personal (no names, passwords or Wi-Fi details) is
    in any of these files.

THE badusb FOLDER
  Scripts for computers that are ALREADY installed (USB or netboot - same
  system). The Flipper pretends to be a keyboard and types one command.
  Copy the .txt files to the SD card under /badusb/, open Bad USB on the
  Flipper, pick one, press Run. Only ever use them on your own computers.
  See badusb/README.txt.
