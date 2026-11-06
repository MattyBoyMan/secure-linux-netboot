#!/usr/bin/env python3
"""Native GTK4/Libadwaita task views for Home & Server Studio."""
from __future__ import annotations

from gui_tools_gtk import (
    advanced, card, check, dropdown, entry, field, run_native, ui,
    NativeOperationWindow,
)
from home_server_gui import CONTAINER_RE, SERVER_ACTIONS, valid_target, valid_url


class HomeServerWindow(NativeOperationWindow):
    app_title = "Home & Server Studio"
    app_subtitle = "Choose a task. Safe defaults first; advanced controls stay collapsed."

    def __init__(self, application, backend, *, runner=None, demo=False, view="home", action=""):
        super().__init__(application, runner=runner, demo=demo)
        self.backend = backend
        self.ha_url = entry("http://homeassistant.local:8123", description="Manual Home Assistant web address")
        self.server_target = entry("admin@server.local", description="Server SSH login")
        self.server_action = dropdown(tuple(SERVER_ACTIONS), description="Allowlisted server job")
        self.unraid_url = entry("http://tower.local", description="unRAID web address")
        self.unraid_target = entry("root@tower.local", description="unRAID SSH login")
        self.container = entry("homeassistant", description="unRAID container name")
        self.container_action = dropdown(("start", "stop"), description="unRAID container action")
        self._build_home()
        self._build_server()
        self._build_unraid()
        self._build_docker()
        self.finish_pages(view)
        if demo:
            self.append_output("Preview only. No server, website, API or Docker command is contacted.")
        elif action == "status":
            ui.idle(self.ha_status)

    def _build_home(self):
        page = ui.page_box()
        ui.add_heading(page, "What would you like to do?", "Find an existing Home Assistant dashboard or try a private copy. The default path needs no address or token.")
        find = card("Find and open my Home Assistant", "Discovery looks for the standard homeassistant.local name on your home network and saves its address if found.")
        for text, callback in (("Find and save address", self.ha_discover), ("Open dashboard", self.ha_open), ("Read status", self.ha_status)):
            find.append(ui.button(text, callback, primary=text == "Find and save address"))
        page.append(find)
        local = card("Try a private copy on this laptop", "This rootless Podman sandbox listens only on 127.0.0.1:8123. Enable writes settings; Start may download about 1.5 GB after review.")
        for text, action in (("Enable", "enable"), ("Start", "start"), ("Stop", "stop"), ("Status", "status"), ("Open", "open")):
            local.append(ui.button(text, lambda value=action: self.ha_local(value), primary=action == "start"))
        page.append(local)
        expander, body = advanced("Advanced address, API token and maintenance")
        save_row = ui.Gtk.Box(orientation=ui.Gtk.Orientation.HORIZONTAL, spacing=12)
        save_row.append(self.ha_url)
        save_row.append(ui.button("Save address", self.save_ha_url))
        field(body, "Manual web address (only if discovery fails)", save_row)
        for text, callback in (("Plain-English doctor", self.ha_doctor), ("Check for updates", self.ha_update_check), ("API security check", self.ha_security)):
            body.append(ui.button(text, callback))
        body.append(ui.label("API token means a private pass for security information. It is optional, hidden, sent only through standard input, and never placed in arguments or activity logs.", css=("sl-caption", "sl-muted")))
        body.append(ui.button("Review & save API token privately…", self.ha_token))
        body.append(ui.label("Recommended new installation: Home Assistant OS on a small always-on computer. Container has no add-on store. Never port-forward Home Assistant; use a private mesh, login-protected tunnel or Nabu Casa.", css=("sl-caption",)))
        page.append(expander)
        self.add_page("home", "Home Assistant", "go-home-symbolic", page)

    def _build_server(self):
        page = ui.page_box()
        ui.add_heading(page, "Set up a server you already own", "Two choices are enough: how to sign in, and which reviewed job to run. Copy the kit once before running a job.")
        connect = card("1. Connect and copy the reviewed tools", "SSH login means account and server address, such as admin@server.local. Copying replaces same-name kit files but installs nothing.")
        field(connect, "SSH login", self.server_target)
        connect.append(ui.button("Review & copy server kit…", self.server_copy, primary=True))
        page.append(connect)
        action = card("2. Choose one job", "Every job uses the existing allowlisted server kit and asks for confirmation before changing the server.")
        field(action, "Job", self.server_action)
        action.append(ui.button("Review & run on server…", self.server_run, primary=True))
        page.append(action)
        expander, body = advanced("Advanced remote-output and recovery details")
        body.append(ui.label("No remote backup is made by copying. Back up before updates. A zero exit is not independent proof of installed services, running containers or healthy backups.", css=("sl-body",)))
        body.append(ui.label("All server actions remain in the Job list. Scripts can refuse unsafe non-interactive input rather than pretending to finish.", css=("sl-caption", "sl-muted")))
        page.append(expander)
        self.add_page("server", "Existing server", "network-server-symbolic", page)

    def _build_unraid(self):
        page = ui.page_box()
        ui.add_heading(page, "Use an unRAID server you already have", "unRAID is a separate operating system on another computer; it is not installed here.")
        web = card("Open the unRAID dashboard", "This is the web address of your existing unRAID server, not a download or installation address.")
        field(web, "unRAID web address", self.unraid_url)
        web.append(ui.button("Open web interface", self.unraid_web))
        page.append(web)
        status = card("Read server and container status", "SSH lets this app ask for read-only status. No container is started or stopped by this task.")
        field(status, "SSH login", self.unraid_target)
        status.append(ui.button("Read server & container status", self.unraid_status, primary=True))
        page.append(status)
        expander, body = advanced("Advanced API token and container controls")
        body.append(ui.label("An API token is an optional private pass for unRAID's read-only API check. It is hidden, stored owner-only (0600), and never logged or placed in arguments.", css=("sl-caption", "sl-muted")))
        body.append(ui.button("Review & save API token…", self.unraid_token))
        body.append(ui.button("Test API read-only", self.unraid_api))
        field(body, "Container", self.container)
        field(body, "Action", self.container_action)
        body.append(ui.button("Review container action…", self.unraid_container, primary=True))
        page.append(expander)
        self.add_page("unraid", "External unRAID", "network-server-symbolic", page)

    def _build_docker(self):
        page = ui.page_box()
        ui.add_heading(page, "Run containers with fewer administrator powers", "Rootless means Docker runs as your desktop user instead of the all-powerful root account.")
        setup = card("Set up safer per-user Docker", "Your rootful server tools stay intact. Setup grants no docker-group membership, uses Docker's official rootless tool, and enables start-at-boot where supported.")
        setup.append(ui.button("Review rootless Docker setup…", self.rootless, primary=True))
        page.append(setup)
        expander, body = advanced("Advanced Docker limits and rescue details")
        body.append(ui.label("Rootless reduces impact; it does not remove the need for image updates, backups or firewall care. Do not expose container ports directly to the internet.", css=("sl-body",)))
        body.append(ui.label("Boot repair, disk rescue and password recovery remain text-based because they can run before a desktop exists.", css=("sl-caption", "sl-muted")))
        page.append(expander)
        self.add_page("docker", "Rootless Docker", "system-run-symbolic", page)

    def _url(self, widget):
        value = widget.get_text().strip()
        if not valid_url(value):
            self.notify("Address not accepted", "Use http://server.local or https://server.local:8443, without a path or login details.")
            return None
        return value

    def _target(self, widget):
        value = widget.get_text().strip()
        if not valid_target(value):
            self.notify("SSH login not accepted", "Use a simple name@server or name@IP-address, without options or shell characters.")
            return None
        return value

    def save_ha_url(self):
        url = self._url(self.ha_url)
        if url:
            self.review("Review Home Assistant address", f"Save {url} as the address used by the existing Home Assistant helper?", (), lambda _secret: self.run(self.backend.choice_url(url)))

    def ha_open(self):
        self.run(self.backend.ha(["open"], "Open Home Assistant in its own window", remote=True))

    def ha_status(self):
        self.run(self.backend.ha(["status"], "Read Home Assistant status", remote=True))

    def ha_discover(self):
        self.review("Review network discovery", "Look for homeassistant.local and save its address if found? No internet request is made.", (), lambda _secret: self.run(self.backend.ha(["discover", "--save"], "Discover Home Assistant on the local network", remote=True)))

    def ha_doctor(self):
        self.run(self.backend.ha(["doctor"], "Run the plain-English Home Assistant doctor", remote=True))

    def ha_update_check(self):
        self.run(self.backend.ha(["update-check"], "Check Home Assistant versions", remote=True))

    def ha_security(self):
        self.run(self.backend.ha_security_api())

    def ha_token(self):
        summary = "Save a Home Assistant long-lived access token using the existing token-set helper. It is stored in the helper's private file, not in this GUI, activity log or command arguments."
        self.review("Private Home Assistant token", summary, (), lambda secret: self.run(self.backend.ha(["token-set"], "Privately save the Home Assistant token", secret=secret, remote=True)), secret_label="Paste the token (hidden; required)")

    def ha_local(self, action):
        if action not in {"enable", "start", "stop", "status", "open"}:
            return
        def begin(_secret=None):
            args = ["local", action] + (["--yes"] if action == "start" else [])
            self.run(self.backend.ha(args, f"Home Assistant private try-it: {action}"))
        if action in {"enable", "start", "stop"}:
            detail = "Enable writes the rootless loopback-only sandbox without starting it." if action == "enable" else ("Start may download about 1.5 GB and then start the private user service." if action == "start" else "Stop the private try-it service. Its configuration is not deleted.")
            self.review(f"Review local {action}", detail, (), begin)
        else:
            begin()

    def server_copy(self):
        target = self._target(self.server_target)
        if target:
            summary = f"Copy the existing server kit to ~/secure-linux-server on {target}.\n\nSame-name kit files may be replaced. Unrelated files are not intentionally deleted, and no remote backup is made. Nothing is installed by the copy itself."
            self.review("Review server-kit copy", summary, ("Confirm",), lambda _secret: self.run(self.backend.server_copy(target)))

    def server_run(self):
        target = self._target(self.server_target)
        if target:
            selected = tuple(SERVER_ACTIONS)[self.server_action.get_selected()]
            action = SERVER_ACTIONS[selected]
            summary = f"Run the allowlisted action '{action}' as administrator on {target}.\n\nThe remote script may install or change software and may ask its own questions. Copy the kit first. A zero exit alone is not independent proof of remote health."
            self.review("Review remote server change", summary, ("Confirm",), lambda _secret: self.run(self.backend.server_run(target, action)))

    def unraid_web(self):
        url = self._url(self.unraid_url)
        if url:
            self.run(self.backend.unraid_web(url))

    def unraid_status(self):
        target = self._target(self.unraid_target)
        if target:
            self.run(self.backend.unraid_status(target))

    def unraid_container(self):
        target = self._target(self.unraid_target)
        container = self.container.get_text().strip()
        if not target:
            return
        if not CONTAINER_RE.fullmatch(container):
            self.notify("Container name not accepted", "Use only letters, numbers, dot, dash and underscore.")
            return
        action = ("start", "stop")[self.container_action.get_selected()]
        summary = f"{action.title()} container {container} on external unRAID server {target} using the existing SSH helper.\n\nNo software is installed by this action. The server's own output determines what happened."
        self.review("Review unRAID container action", summary, ("Confirm",), lambda _secret: self.run(self.backend.unraid_container(action, target, container)))

    def unraid_token(self):
        url = self._url(self.unraid_url)
        if url:
            summary = f"Save an API token for the external unRAID server {url}.\n\nThe existing helper stores it only for this user with mode 0600. It is never put in a command-line argument or log."
            self.review("Private unRAID API token", summary, ("Confirm",), lambda secret: self.run(self.backend.unraid_token(url, secret)), secret_label="Paste the API token (hidden; required)")

    def unraid_api(self):
        url = self._url(self.unraid_url)
        if url:
            self.run(self.backend.unraid_api(url))

    def rootless(self):
        summary = "Set up per-user rootless Docker using the official rootless setup tool. Leave rootful Docker intact, grant no docker-group membership, and enable linger where supported."
        self.review("Review rootless Docker setup", summary, ("Confirm",), lambda _secret: self.run(self.backend.rootless()))
