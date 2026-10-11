import Foundation

/// How well a distribution supports a generic ARM64 UEFI virtual machine.
public enum ARMSupport: String, Codable {
    /// An official ARM64 / AArch64 UEFI ISO is published.
    case official
    /// ARM64 exists but needs a community, preview or specially prepared UEFI image.
    case limited
    /// Only Intel/AMD installers are published.
    case none

    public var title: String {
        switch self {
        case .official: return "ARM64 ISO"
        case .limited: return "Community / preview"
        case .none: return "Intel only"
        }
    }
}

public struct LinuxDistribution: Identifiable, Hashable {
    public let id: String
    public let name: String
    /// The backend profile and defaults this distribution uses.
    public let family: GuestOS
    public let support: ARMSupport
    public let downloadURL: URL
    public let summary: String
    /// Lowercased tokens matched against installer filenames and ISO volume labels.
    public let keywords: [String]
    public let desktop: Bool

    public var recommendedMemoryGiB: Int { desktop ? 8 : 4 }
    public var recommendedDiskGiB: Int { desktop ? 64 : 32 }

    init(_ id: String, _ name: String, _ family: GuestOS, _ support: ARMSupport, _ url: String,
         _ summary: String, keywords: [String], desktop: Bool = true) {
        self.id = id
        self.name = name
        self.family = family
        self.support = support
        self.downloadURL = URL(string: url)!
        self.summary = summary
        self.keywords = keywords
        self.desktop = desktop
    }

    public static func entry(id: String) -> LinuxDistribution? { catalog.first { $0.id == id } }

    /// Ordered from most to least specific so flavours win over their parent distribution.
    public static let catalog: [LinuxDistribution] = [
        .init("ubuntu-server", "Ubuntu Server", .ubuntu, .official, "https://ubuntu.com/download/server/arm",
              "Lightweight server install with optional desktop later.", keywords: ["live-server", "ubuntu-server", "ubuntu server"], desktop: false),
        .init("kubuntu", "Kubuntu", .ubuntu, .limited, "https://kubuntu.org/getkubuntu/",
              "Ubuntu with KDE Plasma. ARM64 builds vary by release.", keywords: ["kubuntu"]),
        .init("xubuntu", "Xubuntu", .ubuntu, .limited, "https://xubuntu.org/download/",
              "Ubuntu with Xfce. ARM64 builds vary by release.", keywords: ["xubuntu"]),
        .init("ubuntu-mate", "Ubuntu MATE", .ubuntu, .limited, "https://ubuntu-mate.org/download/",
              "Ubuntu with MATE. ARM64 builds vary by release.", keywords: ["ubuntu-mate", "ubuntu mate"]),
        .init("lubuntu", "Lubuntu", .ubuntu, .limited, "https://lubuntu.me/downloads/",
              "Ubuntu with LXQt. ARM64 builds vary by release.", keywords: ["lubuntu"]),
        .init("pop-os", "Pop!_OS", .ubuntu, .limited, "https://system76.com/pop/download/",
              "System76's Ubuntu-based desktop. ARM64 ISO is in preview.", keywords: ["pop-os", "pop_os", "popos"]),
        .init("ubuntu", "Ubuntu Desktop", .ubuntu, .official, "https://ubuntu.com/download/desktop",
              "The most popular desktop Linux. Best tested with Lumen.", keywords: ["ubuntu"]),
        .init("kali", "Kali Linux", .debian, .official, "https://www.kali.org/get-kali/#kali-installer-images",
              "Security and penetration testing toolkit.", keywords: ["kali"]),
        .init("parrot", "Parrot OS", .debian, .limited, "https://parrotsec.org/download/",
              "Security-focused Debian derivative.", keywords: ["parrot"]),
        .init("debian", "Debian", .debian, .official, "https://www.debian.org/distrib/netinst",
              "Rock-solid universal operating system.", keywords: ["debian"]),
        .init("fedora-server", "Fedora Server", .linux, .official, "https://fedoraproject.org/server/download",
              "Fedora for servers, with Cockpit.", keywords: ["fedora-server", "fedora server"], desktop: false),
        .init("fedora-kde", "Fedora KDE Plasma", .linux, .official, "https://fedoraproject.org/kde/download",
              "Fedora with the KDE Plasma desktop.", keywords: ["fedora-kde", "fedora-kde-live"]),
        .init("fedora", "Fedora Workstation", .linux, .official, "https://fedoraproject.org/workstation/download",
              "Cutting-edge GNOME desktop from the Fedora Project.", keywords: ["fedora"]),
        .init("opensuse-leap", "openSUSE Leap", .linux, .official, "https://get.opensuse.org/leap/",
              "Stable, enterprise-grade openSUSE.", keywords: ["leap"]),
        .init("opensuse-tumbleweed", "openSUSE Tumbleweed", .linux, .official, "https://get.opensuse.org/tumbleweed/",
              "Rolling release, tested by openQA.", keywords: ["tumbleweed", "opensuse"]),
        .init("sles", "SUSE Linux Enterprise", .linux, .official, "https://www.suse.com/download/sles/",
              "Enterprise server from SUSE.", keywords: ["sle-", "sles"], desktop: false),
        .init("rhel", "Red Hat Enterprise Linux", .linux, .official, "https://developers.redhat.com/products/rhel/download",
              "Free developer subscription available.", keywords: ["rhel"], desktop: false),
        .init("rocky", "Rocky Linux", .linux, .official, "https://rockylinux.org/download",
              "Community enterprise OS, RHEL compatible.", keywords: ["rocky"], desktop: false),
        .init("almalinux", "AlmaLinux", .linux, .official, "https://almalinux.org/get-almalinux/",
              "Community enterprise OS, RHEL compatible.", keywords: ["almalinux", "alma"], desktop: false),
        .init("centos-stream", "CentOS Stream", .linux, .official, "https://www.centos.org/download/",
              "Upstream of Red Hat Enterprise Linux.", keywords: ["centos"], desktop: false),
        .init("oracle", "Oracle Linux", .linux, .official, "https://yum.oracle.com/oracle-linux-isos.html",
              "Enterprise Linux from Oracle.", keywords: ["oraclelinux", "oracle"], desktop: false),
        .init("arch", "Arch Linux ARM", .arch, .limited, "https://archboot.com",
              "Rolling DIY distribution. Use an Archboot aarch64 UEFI ISO.", keywords: ["archboot", "archlinux", "arch"]),
        .init("manjaro", "Manjaro ARM", .arch, .limited, "https://manjaro.org/products/download/arm",
              "Arch-based desktop. Use the generic UEFI image.", keywords: ["manjaro"]),
        .init("endeavouros", "EndeavourOS", .arch, .limited, "https://endeavouros.com/",
              "Arch-based. ARM builds target boards, not UEFI VMs.", keywords: ["endeavour"]),
        .init("void", "Void Linux", .voidLinux, .limited, "https://voidlinux.org/download/",
              "Independent, runit-based. Needs a prepared aarch64 UEFI image.", keywords: ["void"]),
        .init("alpine", "Alpine Linux", .linux, .official, "https://alpinelinux.org/downloads/",
              "Tiny, security-oriented. Use the aarch64 “standard” ISO.", keywords: ["alpine"], desktop: false),
        .init("nixos", "NixOS", .linux, .official, "https://nixos.org/download/#nixos-iso",
              "Declarative, reproducible system configuration.", keywords: ["nixos"]),
        .init("gentoo", "Gentoo", .linux, .official, "https://www.gentoo.org/downloads/",
              "Source-based. Use the arm64 minimal install ISO.", keywords: ["gentoo", "install-arm64-minimal"], desktop: false),
        .init("openeuler", "openEuler", .linux, .official, "https://www.openeuler.org/en/download/",
              "Enterprise Linux community distribution.", keywords: ["openeuler"], desktop: false),
        .init("other", "Other Linux", .linux, .official, "https://distrowatch.com/search.php?arch=aarch64",
              "Any ARM64 / AArch64 UEFI-bootable ISO.", keywords: [])
    ]

    /// Matches a filename and/or ISO volume label to a catalog entry.
    public static func match(_ text: String) -> LinuxDistribution? {
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return nil }
        let tokens = Set(lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return catalog.first { entry in
            entry.keywords.contains { keyword in
                // Short keywords must appear as a whole token (avoid "arch" matching "aarch64").
                let trimmed = keyword.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
                if trimmed.count <= 5 { return tokens.contains(trimmed) }
                return lowered.contains(keyword)
            }
        }
    }
}
