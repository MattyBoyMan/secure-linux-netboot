CrowdSec package signing keys used by secure-linux-attack-shield (the Attack Shield).

The Attack Shield installs CrowdSec from CrowdSec's own package source. Before it runs any package command it
checks these two files against the SHA-256 and the full key fingerprint written inside the tool, gives them to
the package system, and points the package source at these copies (never at a download). If either file is
missing or changed, nothing is installed.

crowdsec-rpm-archive.asc
  "Crowdsec Rpm Archive <support@crowdsec.net>", fingerprint 9082D8CACBBEB0DAB218BAB04C3D386C3CDF0DB4
  (rpm short id 3cdf0db4). Signs the CrowdSec rpm packages: the header signature of
  crowdsec-firewall-bouncer-nftables-0.0.38-1.el9.x86_64.rpm names issuer 9082D8CACBBEB0DAB218BAB04C3D386C3CDF0DB4
  (checked 2026-11-17). Expires 2027-05 (key data); a later kit must ship the renewed key.
  SHA-256 f660f2924c969b319864569f0ad5f9f97adc4bd75e28a5cbf9ea4cf2bf55c676
  Source: https://packagecloud.io/crowdsec/crowdsec/gpgkey/crowdsec-crowdsec-FED78314A2468CCF.pub.gpg
  (same bytes on 2026-11-14 and 2026-11-17). Not found on keyserver.ubuntu.com, so this key is trusted on the
  word of CrowdSec's package host over https (first use), then pinned.

crowdsec-packagecloud-repo.asc
  "https://packagecloud.io/crowdsec/crowdsec", fingerprint 6A89E3C2303A901A889971D3376ED5326E93CD0C
  (rpm short id 6e93cd0c). Its subkey C358C5638A13ACC3A665A9419EB2753BF09DFB77 signs the package list
  (repodata/repomd.xml.asc, checked 2026-11-17).
  SHA-256 cd5729fe6f95d29efc48f1cfe63e0d4a3088506cf99f3cf74b572c4b70429980
  Source: https://packagecloud.io/crowdsec/crowdsec/gpgkey (same bytes on 2026-11-14 and 2026-11-17); the same
  fingerprint is published on keyserver.ubuntu.com (second source, checked 2026-11-17).

The third key the repository lists (Crowdsec Team <debian@crowdsec.net>, B06F1981145CE2F2) is for Debian
packages and has expired, so it is not shipped or trusted.
