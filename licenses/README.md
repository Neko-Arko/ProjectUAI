# Kilo connection helper notices

The Android app includes `info.guardianproject:tor-android:0.4.9.14` and its
`jtorctl` dependency under BSD-3-Clause. See `kilo/tor-android.txt`. Tor and its
native dependencies retain the notices in this folder. These files ship as
Android assets and in the desktop's embedded license directory.

Windows downloads the unmodified Tor Expert Bundle 15.0.26 from the Tor Project
archive, pinned to SHA-256
`c1988c701de2f24f7d098d1d6d7f507b58f27740d097f29c246e0524d639b252`.
The complete archive retains its own `docs/` notices, including optional
pluggable transports UAI does not start. The Tor, OpenSSL, libevent and zlib
notices here are copied unchanged from that archive.

Sources: https://github.com/guardianproject/tor-android and
https://archive.torproject.org/tor-package-archive/torbrowser/15.0.26/.
The Tor Project and Guardian Project do not endorse Project UAI.
