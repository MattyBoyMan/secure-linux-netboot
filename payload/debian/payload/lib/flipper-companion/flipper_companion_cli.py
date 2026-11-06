#!/usr/bin/env python3
"""Beginner-oriented command line and interactive menu."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from urllib.request import urlopen

from flipper_companion_backup import (
    create_backup,
    create_encrypted_backup,
    restore_backup,
    restore_encrypted_backup,
    verify_backup,
)
from flipper_companion_core import (
    COMPANION_VERSION,
    FLASH_ERASE_NOTICE,
    CompanionError,
    check_metadata,
    companion_status,
    confirm_change,
    default_pack,
    load_metadata,
    refresh_metadata,
    repository_root,
)
from flipper_companion_operations import (
    TOOLCHAIN_HELP,
    apply_install_plan,
    build_fap,
    launch_qflipper,
    make_install_plan,
    open_sd_file_manager,
    prepare_flipper,
    toolchain_status,
)
from flipper_companion_roguemaster import (
    check_dfu,
    check_release,
    create_inventory,
    merge_resources,
    prepare_release,
    resume_update,
    rollback_release,
    update_release,
)
from flipper_companion_advanced import download_and_install_latest, verify_installed_update
from flipper_companion_device import check_for_roguemaster_update, read_device_info
from flipper_companion_resources import (
    accessibility_recommendations,
    build_custom_animations,
    organise_favourites,
    organise_key_apps,
    prepare_stock_resources,
    preview_animations,
    restore_stock_animations,
    rollback_stock_animations,
)
from flipper_companion_timing import TimingStore

ROOT = repository_root(__file__)
DEFAULT_STAGING = Path.home() / ".local" / "share" / "secure-linux-flipper" / "protected-staging"
DEFAULT_TIMING = Path.home() / ".local" / "share" / "secure-linux-flipper" / "timing"


def _add_staging(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--staging-root", type=Path, default=DEFAULT_STAGING, help="Protected computer-only decryption/encryption staging folder")
    parser.add_argument("--tool", choices=("auto", "age", "gpg"), default="auto")


def _add_device_timing(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--serial-port", help="Optional Flipper serial port for official protobuf DEV-INFO")
    parser.add_argument("--timing-root", type=Path, default=DEFAULT_TIMING, help="Computer-only pseudonymous timing profiles")


def _add_destination(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--destination", choices=("sd", "computer", "both"), required=True)
    parser.add_argument("--sd", type=Path, help="Explicitly selected mounted Flipper SD folder")
    parser.add_argument("--computer-dir", type=Path, help="Computer folder that mirrors SD-relative payload paths")
    parser.add_argument("--safety-backup", type=Path, help="Computer folder for verified pre-overwrite backups")
    parser.add_argument("--yes", action="store_true", help="Confirm the displayed review non-interactively")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="secure-linux-flipper",
        description="Safe, version-linked Secure Linux companion for a RogueMaster Flipper Zero.",
        epilog=(
            "FAPs run on the Flipper, not as native Linux apps. A removable mount is never assumed to be the Flipper SD. "
            + FLASH_ERASE_NOTICE
        ),
    )
    parser.add_argument("--kit-root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    parser.add_argument("--version", action="version", version=f"%(prog)s {COMPANION_VERSION}")
    commands = parser.add_subparsers(dest="command")

    status = commands.add_parser("status", help="Honestly detect USB, candidate SD mounts, and available tools")
    status.add_argument("--json", action="store_true")

    backup = commands.add_parser("backup", help="Hash-verified full or selected SD backup")
    backup.add_argument("--sd", type=Path, required=True)
    backup.add_argument("--dest", type=Path, required=True, help="Computer backup destination")
    backup.add_argument("--select", nargs="+", help="Specific SD-relative files/folders instead of the full SD")
    backup.add_argument("--private", action="store_true", help="Encrypt with age/gpg; passphrase is prompted, never an option")
    _add_staging(backup)

    verify = commands.add_parser("verify", help="Verify every manifest and payload hash in a backup")
    verify.add_argument("backup", type=Path)

    restore = commands.add_parser("restore", help="Verified restore without deleting other Flipper files")
    restore.add_argument("backup", type=Path, help="Plain backup folder or encrypted .age/.gpg backup")
    restore.add_argument("--sd", type=Path, required=True)
    restore.add_argument("--safety-backup", type=Path, help="Required before replacing differing existing files")
    restore.add_argument("--encrypted", action="store_true", help="Decrypt only into protected staging, then restore")
    restore.add_argument("--yes", action="store_true")
    _add_staging(restore)

    install = commands.add_parser("install", help="Review and install apps, BadUSB scripts, automations, or data")
    install.add_argument("sources", nargs="+", type=Path)
    install.add_argument("--kind", choices=("fap", "badusb", "data"), required=True)
    install.add_argument("--app-folder", help="Flipper apps subfolder for FAPs, for example USB or Games")
    install.add_argument("--dest", help="SD-relative destination folder for data/scripts/automations")
    _add_destination(install)

    prepare = commands.add_parser("prepare", help="Prepare/rebuild the existing Boot2Flipper SD payload")
    prepare.add_argument("--pack", type=Path, help="Existing flipper pack; defaults to rendered pack, then source pack")
    prepare.add_argument("--fap", type=Path, help="Locally built/downloaded boot2flipper.fap")
    prepare.add_argument("--ipxe-efi", type=Path)
    prepare.add_argument("--ipxe-lkrn", type=Path)
    _add_destination(prepare)

    build = commands.add_parser("build-fap", help="Build locally with installed ufbt or official/RogueMaster fbt")
    build.add_argument("source", type=Path)
    build.add_argument("--output", type=Path, required=True, help="Computer output folder")
    build.add_argument("--tool", choices=("auto", "ufbt", "fbt"), default="auto")
    build.add_argument("--fbt-root", type=Path)
    build.add_argument("--app-name")
    build.add_argument("--safety-backup", type=Path)
    build.add_argument("--yes", action="store_true")

    commands.add_parser("toolchain-status", help="Show installed build tools and honest setup instructions")
    commands.add_parser("version", help="Show kit linkage and payload drift").add_argument("--check", action="store_true")
    refresh = commands.add_parser("refresh-version", help="Relink to an already stamped, current central release")
    refresh.add_argument("--kit-version", help="Compatibility check only; must equal the central release ID")
    refresh.add_argument("--yes", action="store_true")

    qflipper = commands.add_parser("qflipper", help="Launch official qFlipper with a larger accessible display")
    qflipper.add_argument("--scale", type=float, default=1.5)
    qflipper.add_argument("--flatpak", action="store_true")
    qflipper.add_argument("--yes", action="store_true")

    inventory = commands.add_parser("inventory", help="Categorize SD files with SHA-256 and release comparison")
    inventory.add_argument("--sd", type=Path, required=True)
    inventory.add_argument("--json", action="store_true", help="Write JSON to stdout instead of a summary")

    rm_check = commands.add_parser("rm-check", help="Inspect the official stable release or mutable 420 branch")
    rm_check.add_argument("--channel", choices=("stable", "moving-head"), default="stable")
    rm_check.add_argument("--json", action="store_true")

    rm_device = commands.add_parser("rm-check-device", help="Check for RogueMaster Update using actual device DEV-INFO and SD resource date")
    rm_device.add_argument("--sd", type=Path, required=True)
    _add_device_timing(rm_device)

    rm_install = commands.add_parser("rm-install-latest", help="Download and Install Latest RogueMaster Update for Flipper Device via qFlipper GUI")
    rm_install.add_argument("--sd", type=Path, required=True)
    rm_install.add_argument("--work-dir", type=Path, required=True)
    rm_install.add_argument("--backup-dir", type=Path, required=True)
    rm_install.add_argument("--resource-conflict", choices=("abort", "replace"), default="abort")
    rm_install.add_argument("--yes", action="store_true")
    _add_device_timing(rm_install)

    rm_verify = commands.add_parser("rm-verify", help="Verify firmware and every SD resource before 100 percent or timing history")
    rm_verify.add_argument("--release-dir", type=Path, required=True)
    rm_verify.add_argument("--sd", type=Path, required=True)
    _add_device_timing(rm_verify)

    stock_prepare = commands.add_parser("stock-prepare", help="Download and verify genuine official stock dolphin resources")
    stock_prepare.add_argument("--work-dir", type=Path, required=True)
    stock_prepare.add_argument("--version", help="Official stable version; defaults to the device-reported version")
    stock_prepare.add_argument("--require-compatible", action="store_true", help="Refuse download unless the exact official device build matches")
    _add_device_timing(stock_prepare)

    stock_preview = commands.add_parser("stock-preview", help="Preview genuine stock animation metadata and any matching PNG sources")
    stock_preview.add_argument("--stock-dir", type=Path, required=True)
    stock_preview.add_argument("--animations", nargs="+", required=True)

    stock_restore = commands.add_parser("stock-restore", help="Restore selected compatible stock dolphin animations after full backup")
    stock_restore.add_argument("--stock-dir", type=Path, required=True)
    stock_restore.add_argument("--sd", type=Path, required=True)
    stock_restore.add_argument("--animations", nargs="+", required=True)
    stock_restore.add_argument("--backup-dir", type=Path, required=True)
    stock_restore.add_argument("--yes", action="store_true")
    _add_device_timing(stock_restore)

    stock_rollback = commands.add_parser("stock-rollback", help="Roll back selected stock resources and only unchanged companion additions")
    stock_rollback.add_argument("--journal", type=Path, required=True)
    stock_rollback.add_argument("--sd", type=Path, required=True)
    stock_rollback.add_argument("--safety-backup", type=Path, required=True)
    stock_rollback.add_argument("--yes", action="store_true")

    animation_build = commands.add_parser("animation-build", help="Build custom dolphin PNG assets with a real fbt dolphin_ext toolchain")
    animation_build.add_argument("--fbt-root", type=Path, required=True)
    animation_build.add_argument("--output", type=Path, required=True)

    favourites = commands.add_parser("favourites", help="Preview and write supported /any/... favourites after full backup")
    favourites.add_argument("--sd", type=Path, required=True)
    favourites.add_argument("--entries", nargs="+", required=True)
    favourites.add_argument("--backup-dir", type=Path, required=True)
    favourites.add_argument("--yes", action="store_true")

    apps = commands.add_parser("apps-organize", help="Copy key FAPs into curated category folders without deleting originals")
    apps.add_argument("--sd", type=Path, required=True)
    apps.add_argument("--assignment", nargs=2, action="append", metavar=("CATEGORY", "SD_FAP_PATH"), required=True)
    apps.add_argument("--backup-dir", type=Path, required=True)
    apps.add_argument("--yes", action="store_true")

    commands.add_parser("accessibility", help="Show safe qFlipper and companion accessibility options")

    rm_update = commands.add_parser("rm-update", help="Verify stable RogueMaster, back up SD, then stage or open qFlipper")
    rm_update.add_argument("--sd", type=Path, required=True)
    rm_update.add_argument("--work-dir", type=Path, required=True, help="Computer release/download journal directory")
    rm_update.add_argument("--backup-dir", type=Path, required=True, help="Computer full-SD backup destination")
    rm_update.add_argument("--channel", choices=("stable", "moving-head"), default="stable")
    rm_update.add_argument("--method", choices=("stage", "qflipper"), default="stage")
    rm_update.add_argument("--resource-conflict", choices=("abort", "replace"), default="abort")
    rm_update.add_argument("--yes", action="store_true")

    rm_assets = commands.add_parser("rm-assets", help="Offline merge of verified SD resources only; never firmware")
    rm_assets.add_argument("--release-dir", type=Path, required=True)
    rm_assets.add_argument("--sd", type=Path, required=True)
    rm_assets.add_argument("--conflict", choices=("abort", "keep", "replace"), default="abort")
    rm_assets.add_argument("--yes", action="store_true")

    rm_resume = commands.add_parser("rm-resume", help="Resume a staged update from cache with zero network calls")
    rm_resume.add_argument("--release-dir", type=Path, required=True)
    rm_resume.add_argument("--sd", type=Path, required=True)
    rm_resume.add_argument("--offline", action="store_true", help="Explicitly require cached-only operation (always true for resume)")
    rm_resume.add_argument("--method", choices=("stage", "qflipper"), default=None)
    rm_resume.add_argument("--resource-conflict", choices=("abort", "replace"), default="abort")
    rm_resume.add_argument("--yes", action="store_true")

    rm_rollback = commands.add_parser("rm-rollback", help="Restore journaled pre-update SD contents; not a firmware rollback")
    rm_rollback.add_argument("--release-dir", type=Path, required=True)
    rm_rollback.add_argument("--sd", type=Path, required=True)
    rm_rollback.add_argument("--safety-backup", type=Path, required=True)
    rm_rollback.add_argument("--yes", action="store_true")

    dfu = commands.add_parser("dfu-check", help="Read-only dfu-util -l inspection; never flashes")
    dfu.add_argument("--yes", action="store_true")

    files = commands.add_parser("open-sd", help="Open the explicitly selected SD in the desktop file manager")
    files.add_argument("--sd", type=Path, required=True)
    commands.add_parser("menu", help="Open the beginner menu")
    return parser


def _targets(args: argparse.Namespace) -> list[tuple[str, Path]]:
    targets: list[tuple[str, Path]] = []
    if args.destination in {"sd", "both"}:
        if not args.sd:
            raise CompanionError("--sd is required for SD/both. Run status and explicitly choose the mounted card.")
        targets.append(("sd", args.sd))
    if args.destination in {"computer", "both"}:
        if not args.computer_dir:
            raise CompanionError("--computer-dir is required for computer/both destinations.")
        targets.append(("computer", args.computer_dir))
    return targets


def _print_status(status: dict) -> None:
    print(f"Companion: {status['companion_version']} | Kit link: {status['kit_version']}")
    devices = status["flipper_usb"]
    print(f"Known/possible Flipper USB devices: {len(devices)}")
    for device in devices:
        print(f"  {device['product']} ({device['vendor_id']}:{device['product_id']}, {device['mode']})")
        print(f"  {device['identity']}")
    if not devices:
        print("  None detected. Connect by USB and check the cable/permissions; no connection is claimed.")
    mounts = status["mounted_removable_candidates"]
    print(f"Mounted removable SD candidates: {len(mounts)}")
    for mount in mounts:
        print(f"  {mount['device']} at {mount['mount']} — {mount['label']}, {mount['size']}, {mount['filesystem']}")
    print("  Ownership is unverified: pass the intended mount explicitly with --sd.")
    if status["sd_detection_error"]:
        print(f"  {status['sd_detection_error']}")
    for name in ("qflipper", "qflipper_cli", "dfu_util", "age", "gpg", "ufbt"):
        print(f"{name}: {status[name] or 'not found'}")
    print(status["execution_note"])
    print(status["erase_note"])


def _menu(root: Path) -> int:
    print("\nSecure Linux Flipper Companion")
    print("Nothing is written until a review is shown and you type Confirm.")
    while True:
        print("\n1) Device and SD status\n2) Back up the whole SD\n3) Restore a backup\n4) Prepare Boot2Flipper\n5) Open qFlipper larger\n6) Manage SD files\n7) Version/link check\n8) Stable RogueMaster update (SD staging)\n9) Check for RogueMaster Update\n10) Download and Install Latest RogueMaster Update for Flipper Device\n11) Advanced commands/help\n0) Quit")
        choice = input("Choose a number: ").strip()
        try:
            if choice == "0":
                return 0
            if choice == "1":
                _print_status(companion_status(root))
            elif choice == "2":
                sd = Path(input("Explicit SD mount path: ").strip())
                dest = Path(input("Computer backup destination: ").strip())
                create_backup(sd, dest, root=root, reporter=print)
            elif choice == "3":
                backup = Path(input("Plain backup folder (use advanced restore for encrypted backups): ").strip())
                sd = Path(input("Explicit SD mount path: ").strip())
                safety_text = input("Safety-backup folder (required if files differ): ").strip()
                restore_backup(backup, sd, safety_backup=Path(safety_text) if safety_text else None, root=root, reporter=print)
            elif choice == "4":
                sd = Path(input("Explicit SD mount path: ").strip())
                safety_text = input("Safety-backup folder (required if files differ): ").strip()
                prepare_flipper(
                    root, pack=None, fap=None, ipxe_efi=None, ipxe_lkrn=None,
                    targets=[("sd", sd)], safety_backup=Path(safety_text) if safety_text else None,
                    yes=False, reporter=print,
                )
            elif choice == "5":
                launch_qflipper(scale=1.5, reporter=print)
            elif choice == "6":
                open_sd_file_manager(Path(input("Explicit SD mount path: ").strip()), reporter=print)
            elif choice == "7":
                metadata = load_metadata(root)
                print(json.dumps(metadata, indent=2, sort_keys=True))
                problems = check_metadata(root)
                print("Payload link is current." if not problems else "\n".join(problems))
            elif choice == "8":
                sd = Path(input("Explicit SD mount path: ").strip())
                backup_dir = Path(input("Computer full-backup destination: ").strip())
                work_dir = Path(input("Computer release/work destination: ").strip())
                print("The safe default stages update.fuf on SD; it does not flash the Flipper automatically.")
                release_dir = prepare_release(work_dir, reporter=print)
                result = update_release(
                    release_dir, sd, method="stage", resource_conflict="abort", backup_dir=backup_dir,
                    root=root, reporter=print,
                )
                print(json.dumps(result, indent=2, sort_keys=True))
            elif choice == "9":
                sd = Path(input("Explicit SD mount path: ").strip())
                serial_port = input("Flipper serial port (blank for automatic selection): ").strip() or None
                result = check_for_roguemaster_update(
                    sd, TimingStore(DEFAULT_TIMING), serial_port=serial_port, opener=urlopen,
                )
                print(json.dumps(result, indent=2, sort_keys=True))
            elif choice == "10":
                sd = Path(input("Explicit SD mount path: ").strip())
                backup_dir = Path(input("Computer full-backup destination: ").strip())
                work_dir = Path(input("Computer release/work destination: ").strip())
                serial_port = input("Flipper serial port (blank for automatic selection): ").strip() or None
                result = download_and_install_latest(
                    work_dir=work_dir, sd=sd, backup_dir=backup_dir,
                    timing_store=TimingStore(DEFAULT_TIMING), serial_port=serial_port,
                    opener=urlopen, root=root, reporter=print,
                )
                print(json.dumps(result, indent=2, sort_keys=True))
            elif choice == "11":
                build_parser().print_help()
                print("\nUse backup --private and restore --encrypted for private backups. Use install and build-fap for custom apps.")
            else:
                print("Choose one of the listed numbers.")
        except CompanionError as exc:
            print(f"Stopped safely: {exc}", file=sys.stderr)


def run(args: argparse.Namespace, parser: argparse.ArgumentParser) -> int:
    root = args.kit_root.expanduser().resolve()
    command = args.command
    if command is None:
        parser.print_help()
        print("\nStart with: secure-linux-flipper menu")
        return 0
    if command == "menu":
        return _menu(root)
    if command == "status":
        status = companion_status(root)
        if args.json:
            print(json.dumps(status, indent=2, sort_keys=True))
        else:
            _print_status(status)
        return 0
    if command == "backup":
        if args.private:
            create_encrypted_backup(
                args.sd, args.dest, selection=args.select, tool=args.tool,
                staging_root=args.staging_root, root=root, reporter=print,
            )
        else:
            create_backup(args.sd, args.dest, selection=args.select, root=root, reporter=print)
        return 0
    if command == "verify":
        manifest = verify_backup(args.backup)
        print(f"Verified {manifest['file_count']} files ({manifest['total_bytes']} bytes); every SHA-256 matches.")
        return 0
    if command == "restore":
        if args.encrypted:
            result = restore_encrypted_backup(
                args.backup, args.sd, safety_backup=args.safety_backup, staging_root=args.staging_root,
                tool=args.tool, yes=args.yes, root=root, reporter=print,
            )
        else:
            if args.backup.suffix.lower() in {".age", ".gpg", ".pgp"}:
                raise CompanionError("Use restore --encrypted. Never copy encrypted payloads directly to the Flipper.")
            result = restore_backup(args.backup, args.sd, safety_backup=args.safety_backup, yes=args.yes, root=root, reporter=print)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "install":
        items = make_install_plan(args.sources, kind=args.kind, destination=args.dest, app_folder=args.app_folder)
        result = apply_install_plan(
            items, _targets(args), safety_backup=args.safety_backup, yes=args.yes,
            root=root, reporter=print,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "prepare":
        result = prepare_flipper(
            root, pack=args.pack, fap=args.fap, ipxe_efi=args.ipxe_efi, ipxe_lkrn=args.ipxe_lkrn,
            targets=_targets(args), safety_backup=args.safety_backup, yes=args.yes, reporter=print,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "build-fap":
        build_fap(
            args.source, args.output, tool=args.tool, fbt_root=args.fbt_root, app_name=args.app_name,
            safety_backup=args.safety_backup, yes=args.yes, root=root, reporter=print,
        )
        return 0
    if command == "toolchain-status":
        print(json.dumps(toolchain_status(root), indent=2, sort_keys=True))
        return 0
    if command == "version":
        metadata = load_metadata(root)
        print(json.dumps(metadata, indent=2, sort_keys=True))
        if args.check:
            problems = check_metadata(root)
            if problems:
                print("Payload/version drift detected:\n" + "\n".join(problems), file=sys.stderr)
                print("Run secure-linux-release stamp after reviewed changes, regenerate outputs, then check again.", file=sys.stderr)
                return 1
            print("Version link is current: central release and every tracked Flipper payload hash match.")
        return 0
    if command == "refresh-version":
        confirm_change(
            "This links current Flipper hashes to an already stamped central release. It cannot refresh a stale source manifest.",
            args.yes,
        )
        metadata = refresh_metadata(root, args.kit_version)
        print(f"Linked companion {COMPANION_VERSION} to {metadata['kit_version']} across {len(metadata['assets'])} files.")
        return 0
    if command == "inventory":
        result = create_inventory(args.sd)
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            print(f"Inventoried {result['file_count']} files: {json.dumps(result['categories'], sort_keys=True)}")
            print(result["origin_note"])
        return 0
    if command == "rm-check":
        result = check_release(args.channel)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "rm-check-device":
        result = check_for_roguemaster_update(
            args.sd, TimingStore(args.timing_root), serial_port=args.serial_port, opener=urlopen,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "rm-install-latest":
        result = download_and_install_latest(
            work_dir=args.work_dir, sd=args.sd, backup_dir=args.backup_dir,
            timing_store=TimingStore(args.timing_root), serial_port=args.serial_port,
            opener=urlopen, resource_conflict=args.resource_conflict, yes=args.yes,
            root=root, reporter=print,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "rm-verify":
        result = verify_installed_update(
            release_dir=args.release_dir, sd=args.sd,
            timing_store=TimingStore(args.timing_root), serial_port=args.serial_port,
            reporter=print,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["update_complete"] else 1
    if command == "stock-prepare":
        device = read_device_info(serial_port=args.serial_port)
        stock_dir = prepare_stock_resources(
            args.work_dir, device, version=args.version, opener=urlopen,
            require_compatible=args.require_compatible,
        )
        print(json.dumps({"status": "stock-resources-verified", "stock_dir": str(stock_dir)}, indent=2))
        return 0
    if command == "stock-preview":
        result = preview_animations(args.stock_dir / "resources", args.animations)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "stock-restore":
        device = read_device_info(serial_port=args.serial_port)
        result = restore_stock_animations(
            args.stock_dir, args.sd, device, animations=args.animations,
            backup_dir=args.backup_dir, yes=args.yes, root=root, reporter=print,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "stock-rollback":
        result = rollback_stock_animations(
            args.journal, args.sd, safety_backup=args.safety_backup,
            yes=args.yes, root=root, reporter=print,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "animation-build":
        result = build_custom_animations(args.fbt_root, args.output, reporter=print)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "favourites":
        result = organise_favourites(
            args.sd, args.entries, backup_dir=args.backup_dir,
            yes=args.yes, root=root, reporter=print,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "apps-organize":
        assignments: dict[str, list[str]] = {}
        for category, source in args.assignment:
            assignments.setdefault(category, []).append(source)
        result = organise_key_apps(
            args.sd, assignments, backup_dir=args.backup_dir,
            yes=args.yes, root=root, reporter=print,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "accessibility":
        print(json.dumps(accessibility_recommendations(), indent=2, sort_keys=True))
        return 0
    if command == "rm-update":
        if args.channel == "moving-head":
            result = check_release("moving-head")
            raise CompanionError(result["risk"])
        release_dir = prepare_release(args.work_dir, reporter=print)
        result = update_release(
            release_dir, args.sd, method=args.method, resource_conflict=args.resource_conflict,
            backup_dir=args.backup_dir, yes=args.yes, root=root, reporter=print,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "rm-assets":
        result = merge_resources(
            args.release_dir, args.sd, conflict=args.conflict, yes=args.yes, root=root, reporter=print,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "rm-resume":
        options = {}
        if args.method:
            options["method"] = args.method
        result = resume_update(
            args.release_dir, args.sd, resource_conflict=args.resource_conflict, yes=args.yes,
            root=root, reporter=print, **options,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "rm-rollback":
        result = rollback_release(
            args.release_dir, args.sd, safety_backup=args.safety_backup, yes=args.yes, root=root, reporter=print,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    if command == "dfu-check":
        print(json.dumps(check_dfu(yes=args.yes, reporter=print), indent=2, sort_keys=True))
        return 0
    if command == "qflipper":
        launch_qflipper(scale=args.scale, use_flatpak=args.flatpak, yes=args.yes, reporter=print)
        return 0
    if command == "open-sd":
        open_sd_file_manager(args.sd, reporter=print)
        return 0
    raise CompanionError(f"Unknown command: {command}")


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return run(args, parser)
    except CompanionError as exc:
        print(f"Stopped safely: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\nCancelled. No further action was taken; any already-copied files remain and should be verified.", file=sys.stderr)
        return 130
    except EOFError:
        print("\nInput ended. The pending question was not accepted and no further action was taken.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
