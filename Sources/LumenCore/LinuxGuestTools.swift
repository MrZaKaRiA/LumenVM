import Foundation

/// Read-only VirtioFS tools; installation and desktop integration run in the guest.
public enum LinuxGuestTools {
    public static let tag = "lumentools"
    /// VirtioFS tag of the Rosetta share; the guest mounts it at `rosettaMountPoint`.
    public static let rosettaTag = "rosetta"
    public static let rosettaMountPoint = "/media/rosetta"
    /// binfmt_misc registration for x86_64 ELF binaries, as documented by Apple.
    public static let rosettaBinfmt = #":rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/media/rosetta/rosetta:CF"#
    public static let installCommand = "sudo mkdir -p /mnt/lumen-tools && (mountpoint -q /mnt/lumen-tools || sudo mount -t virtiofs lumentools /mnt/lumen-tools) && bash /mnt/lumen-tools/setup.sh"

    public static func files(sharedFolders: Bool, rosetta: Bool = false) -> [String: String] {
        ["install.sh": installer(sharedFolders: sharedFolders, rosetta: rosetta), "setup.sh": setupScript,
         "session.sh": sessionScript, "runit.sh": runitScript]
    }

    public static let setupScript = #"""
    #!/bin/bash
    set -uo pipefail
    cd -- "$(dirname -- "$0")" || exit 1
    result=0
    if [ "$(id -u)" -eq 0 ]; then
      bash ./install.sh || result=1
    elif command -v sudo >/dev/null; then
      sudo bash "$PWD/install.sh" || result=1
    elif command -v doas >/dev/null; then
      doas bash "$PWD/install.sh" || result=1
    else
      echo 'Run install.sh as root, then run session.sh as your desktop user.' >&2
      result=1
    fi
    # Keep DISPLAY, XAUTHORITY and HOME from the real desktop session, not sudo.
    bash ./session.sh || result=1
    if [ "$result" -eq 0 ]; then
      echo 'Lumen guest tools are ready. Test copying text in both directions.'
    else
      echo 'Some integration steps need attention; see the messages above and /var/log/lumen-guest-tools.log.' >&2
    fi
    exit "$result"
    """#

    public static func installer(sharedFolders: Bool, rosetta: Bool = false) -> String {
        #"""
        #!/bin/bash
        set -uo pipefail
        [ "$(id -u)" -eq 0 ] || { echo 'Run install.sh as root.' >&2; exit 1; }
        exec > >(tee -a /var/log/lumen-guest-tools.log) 2>&1
        echo "=== Lumen guest tools: $(date -u) ==="
        cd -- "$(dirname -- "$0")" || exit 1
        failed=0
        # Do not abandon folder setup when a package mirror or clipboard service fails.
        if command -v apt-get >/dev/null; then
          apt-get update && apt-get install -y spice-vdagent dbus || failed=1
        elif command -v dnf >/dev/null; then
          dnf install -y spice-vdagent dbus || failed=1
        elif command -v pacman >/dev/null; then
          pacman -S --needed --noconfirm spice-vdagent dbus || failed=1
        elif command -v xbps-install >/dev/null; then
          missing=()
          for package in spice-vdagent dbus; do
            xbps-query -p pkgver "$package" >/dev/null 2>&1 || missing+=("$package")
          done
          if [ "${#missing[@]}" -gt 0 ]; then
            xbps-install -Sy "${missing[@]}" || failed=1
          else
            echo 'Void clipboard packages are already installed.'
          fi
        elif command -v zypper >/dev/null; then
          zypper --non-interactive install spice-vdagent dbus-1 || failed=1
        else
          echo 'Install spice-vdagent and D-Bus with your distribution package manager.' >&2
          failed=1
        fi
        install -d -m 755 /usr/local/lib/lumen /etc/xdg/autostart || exit 1
        install -m 755 session.sh /usr/local/lib/lumen/session.sh || exit 1
        cat > /etc/xdg/autostart/lumen-guest-tools.desktop <<'DESKTOP'
        [Desktop Entry]
        Type=Application
        Name=Lumen Guest Integration
        Exec=/bin/bash /usr/local/lib/lumen/session.sh --autostart
        NoDisplay=true
        X-GNOME-Autostart-enabled=true
        DESKTOP
        if [ -d /run/systemd/system ] && command -v systemctl >/dev/null; then
          systemctl start dbus.service || failed=1
          # Distros use either a socket-activated daemon or a directly started unit.
          if systemctl cat spice-vdagentd.socket >/dev/null 2>&1; then
            systemctl enable --now spice-vdagentd.socket || failed=1
          fi
          systemctl start spice-vdagentd.service || failed=1
          systemctl is-active spice-vdagentd.service || failed=1
          # Request discard of freed guest blocks. Host reclamation is backend/filesystem dependent.
          if systemctl cat fstrim.timer >/dev/null 2>&1; then
            systemctl enable --now fstrim.timer || echo 'Could not enable fstrim.timer; run fstrim -av occasionally to reclaim disk space.' >&2
          fi
        elif [ -d /etc/sv ] && [ -d /var/service ] && command -v sv >/dev/null; then
          bash ./runit.sh /etc/sv /var/service dbus spice-vdagentd || failed=1
        else
          echo 'No supported running service manager found. Start dbus and spice-vdagentd with your init system.' >&2
          failed=1
        fi
        if [ ! -e /dev/virtio-ports/com.redhat.spice.0 ]; then
          echo 'Clipboard port is missing. Enable Shared Clipboard in Lumen and fully shut down/start this VM.' >&2
          failed=1
        fi
        # Keep the mount ready for folders selected later in Lumen. With no host
        # share attached, nofail allows an ordinary boot without waiting for it.
        mkdir -p /mnt/lumen
        if ! awk '$2 == "/mnt/lumen" {found=1} END {exit !found}' /etc/fstab; then
          printf '\nlumen /mnt/lumen virtiofs defaults,nofail 0 0\n' >> /etc/fstab || failed=1
        fi
        if [ '\#(sharedFolders ? "1" : "0")' = 1 ]; then
          if ! mountpoint -q /mnt/lumen; then
            modprobe virtiofs 2>/dev/null || true
            mount -t virtiofs lumen /mnt/lumen || failed=1
          fi
          if awk '$2 == "/mnt/lumen" && $1 == "lumen" && $3 == "virtiofs" {found=1} END {exit !found}' /proc/mounts; then
            echo 'Mac folders mounted at /mnt/lumen. Guest permissions match the selected host folders.'
          else
            echo 'Mac folder mount failed or /mnt/lumen is occupied by another filesystem.' >&2
            failed=1
          fi
        else
          echo 'No Mac folder is selected. Choose folders in this VM settings, then shut down/start the VM.'
        fi
        if [ '\#(rosetta ? "1" : "0")' = 1 ]; then
          # Rosetta runs x86_64 Linux binaries. fstab and binfmt.d keep it across reboots.
          mkdir -p \#(rosettaMountPoint)
          if ! awk '$2 == "\#(rosettaMountPoint)" {found=1} END {exit !found}' /etc/fstab; then
            printf '\n\#(rosettaTag) \#(rosettaMountPoint) virtiofs ro,nofail 0 0\n' >> /etc/fstab || failed=1
          fi
          mountpoint -q \#(rosettaMountPoint) || mount -t virtiofs \#(rosettaTag) \#(rosettaMountPoint) || failed=1
          if [ -x \#(rosettaMountPoint)/rosetta ]; then
            mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || failed=1
            if [ -d /etc/binfmt.d ] || [ -d /run/systemd/system ]; then
              mkdir -p /etc/binfmt.d && printf '%s\n' '\#(rosettaBinfmt)' > /etc/binfmt.d/rosetta.conf || failed=1
            fi
            if [ -e /proc/sys/fs/binfmt_misc/rosetta ]; then
              echo 'Rosetta is already registered for x86_64 binaries.'
            elif printf '%s' '\#(rosettaBinfmt)' > /proc/sys/fs/binfmt_misc/register; then
              echo 'Rosetta registered: x86_64 Linux binaries now run through Rosetta.'
            else
              echo 'Could not register Rosetta with binfmt_misc.' >&2
              failed=1
            fi
          else
            echo 'Rosetta share is missing. Enable Rosetta in Lumen and fully shut down/start this VM.' >&2
            failed=1
          fi
        fi
        echo "System setup result: $failed. Log: /var/log/lumen-guest-tools.log"
        exit "$failed"
        """#
    }

    /// Kept independent of host paths so runit readiness and failure handling can be exercised.
    public static let runitScript = #"""
    #!/bin/bash
    set -uo pipefail
    source_dir=$1; service_dir=$2; shift 2
    failed=0
    for name in "$@"; do
      case "$name" in dbus|spice-vdagentd) ;; *) echo 'Invalid Lumen service name.' >&2; exit 1 ;; esac
      if [ ! -d "$source_dir/$name" ]; then
        echo "Missing runit service: $source_dir/$name" >&2
        failed=1; continue
      fi
      if [ ! -e "$service_dir/$name" ] && [ ! -L "$service_dir/$name" ]; then
        ln -s "$source_dir/$name" "$service_dir/$name" || { failed=1; continue; }
      elif [ ! "$service_dir/$name" -ef "$source_dir/$name" ]; then
        echo "Existing runit entry points elsewhere: $service_dir/$name" >&2
        failed=1; continue
      fi
      # runsvdir normally scans every five seconds. Wait for supervision before
      # asking sv to start the service, rather than misreporting that delay.
      for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
        [ -e "$service_dir/$name/supervise/control" ] && break
        sleep 1
      done
      sv -w 15 up "$service_dir/$name" || failed=1
      sv status "$service_dir/$name" || failed=1
    done
    exit "$failed"
    """#

    public static let sessionScript = #"""
    #!/bin/bash
    set -uo pipefail
    [ "$(id -u)" -ne 0 ] || { echo 'Run session.sh as your desktop user, without sudo.' >&2; exit 1; }
    if [ "${1:-}" = --autostart ]; then sleep 2; fi
    failed=0
    config=${XDG_CONFIG_HOME:-$HOME/.config}
    mkdir -p "$config/lumen" || exit 1
    if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = wayland ]; then
      echo 'Native Wayland clipboard is not supported by this SPICE X11 agent. Use an X11 desktop for shared clipboard.' >&2
      failed=1
    elif [ -z "${DISPLAY:-}" ]; then
      echo 'Open Terminal in your graphical X11 desktop and run session.sh again.' >&2
      failed=1
    elif command -v spice-vdagent >/dev/null; then
      if ! pgrep -u "$(id -u)" -x spice-vdagent >/dev/null 2>&1; then
        spice-vdagent > "$config/lumen/clipboard.log" 2>&1 || failed=1
        sleep 1
      fi
      if pgrep -u "$(id -u)" -x spice-vdagent >/dev/null 2>&1; then
        echo 'Desktop clipboard agent is running.'
      else
        echo "Desktop clipboard agent failed; see $config/lumen/clipboard.log and /var/log/lumen-guest-tools.log." >&2
        failed=1
      fi
    else
      echo 'spice-vdagent was not installed successfully.' >&2; failed=1
    fi
    # Minimal window managers often ignore XDG autostart. Add only a managed
    # hook to their existing startup file, never replace the user's startup logic.
    hook='/bin/bash /usr/local/lib/lumen/session.sh --autostart >/dev/null 2>&1 & # Lumen guest tools'
    if [ -f "$HOME/.dwm/autostart.sh" ]; then
      grep -Fq '/usr/local/lib/lumen/session.sh' "$HOME/.dwm/autostart.sh" || printf '\n%s\n' "$hook" >> "$HOME/.dwm/autostart.sh"
    elif [ -f "$HOME/.xinitrc" ]; then
      # Put the hook before exec, which never returns. Preserve the full file.
      if ! grep -Fq '/usr/local/lib/lumen/session.sh' "$HOME/.xinitrc"; then
        cp -p "$HOME/.xinitrc" "$config/lumen/xinitrc.before-lumen" || exit 1
        temp=$(mktemp "$HOME/.xinitrc.lumen.XXXXXX") || exit 1
        awk -v hook="$hook" 'NR==1 && /^#!/ {print; print hook; next} NR==1 {print hook} {print}' "$HOME/.xinitrc" > "$temp" && cat "$temp" > "$HOME/.xinitrc"
        rm -f "$temp"
      fi
    fi
    if mountpoint -q /mnt/lumen; then
      desktop=$(xdg-user-dir DESKTOP 2>/dev/null) || desktop="$HOME/Desktop"
      [ -d "$desktop" ] || desktop="$HOME"
      link="$desktop/Lumen Mac Folders"
      if [ ! -e "$link" ] && [ ! -L "$link" ]; then ln -s /mnt/lumen "$link" || failed=1; fi
      if [ -r /mnt/lumen ] && [ -x /mnt/lumen ]; then
        echo "Mac folders: /mnt/lumen. Shortcut: $link"
      else
        echo 'Your Linux user cannot access the selected Mac folder. Check host/guest folder permissions.' >&2
        failed=1
      fi
    fi
    exit "$failed"
    """#
}
