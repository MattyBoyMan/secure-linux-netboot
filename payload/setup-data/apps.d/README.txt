Secure Linux App Library: the app list (contract C11)
=====================================================

Every file here named NN-group.tsv is part of the list. Files are read in name order. Lines starting with # and
blank lines are ignored. Add an app by adding one line. Nothing else needs changing: the setup step
(steps/52-app-library.sh), the "Optional apps" window and "secure-linux-app-library install NAME" all read this folder.

Row format (nine columns, separated by TAB characters, one app per line):

  id  kind  title  plain_description  approx_size_mb  profiles  default  arch  idea

  id                 The app's name. flatpak: the Flathub id (org.example.App). rpm: the Fedora package name.
                     pipx: the Python package name. Only letters, digits and . _ + - are allowed.
                     serverapp: the recipe folder name under linux/files/server-apps/ (for example jellyfin).
                     kittool: the command name of a Secure Linux tool (for example secure-linux-ai-web).
  kind               flatpak, rpm, pipx, serverapp or kittool.
                     serverapp and kittool rows are "listed only": setup never installs them by itself. A row of
                     these two kinds must say default off, must not offer the atomic profile, and is shown as a
                     'skip' with a plain reason if somebody chose it. A serverapp is set up with
                     "secure-linux-server-apps install ID" (it needs Docker or Podman and the person's own password).
                     A kittool is already on the computer and sets itself up when it is first opened.
  title              Short name people see (60 characters at most).
  plain_description  One plain sentence about what it does (240 characters at most). No jargon.
  approx_size_mb     Whole number of megabytes, shown as the size in the Optional apps window.
  profiles           Which setups are offered it, a comma list of: full, lite, atomic.
                     A "full" app is skipped on a lite computer. An rpm or pipx row should not list "atomic".
  default            on = installed for everyone on those profiles (when online); off = only if chosen.
  arch               all, or x86_64 for apps that only exist for Intel and AMD computers. On ARM (Apple Silicon,
                     Raspberry Pi) an x86_64 row is skipped with a plain note, and is never a failure.
  idea               The idea number from the idea list (may be empty).

Where choices are saved: /etc/secure-linux/app-library.list. One name per line: "name" = install it,
"-name" = do not install it (for an app that is on by default). The Optional apps window writes it for you.

How it behaves:
  - Online, an app is fetched from the internet. With no internet it is installed from the verified copy on the
    Secure Linux drive if the drive holds one (the drive builder stores the apps listed in
    offline-bundle/sources.json; add an app's id there too to make it available offline). If the drive has no copy,
    the app waits ("Will install when this computer is online" in the skipped-apps list) and a timer tries again
    every hour. Setup is never "incomplete" because of the App Library. pipx apps have no offline copy; they wait. The offline copies of serverapp and
    kittool apps (container images, models) are listed under "extra_payloads" in offline-bundle/sources.json.
  - approx_size_mb is the disk space the app needs. "secure-linux-app-library size [NAME...]" adds it up (with no
    names: what setup installs on this computer) so the drive builder and the Optional apps window can warn before
    the drive or the computer runs out of space. "install NAME" refuses when the app is bigger than the free space.
  - Running setup or repair again installs nothing twice.
  - A row with a mistake (wrong column count, bad id, unknown kind...) is reported by
    "secure-linux-app-library check" and left out; the other rows still work. The same id twice is a mistake.
  - Only rows reviewed by the kit's maintainers belong here. pipx rows come from PyPI: add one only after checking
    the package and its maker.

Not offered here (Matthew's decisions; the checker refuses these idea numbers and words):
  - No Windows tools (ideas 42 and 43; nothing that runs Windows programs, such as Wine or Bottles).
  - No video or image generation (idea 64).
  - No study tools (idea 78), no music-making tools (idea 79), no game or animation tools (idea 80).

Example row (TAB between columns; this one is only an example and is not installed):
  # org.example.Notes<TAB>flatpak<TAB>Example Notes<TAB>Write short notes.<TAB>40<TAB>full,lite<TAB>off<TAB>all<TAB>
