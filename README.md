# LMS-YouTube

Fork of [philippe44's Youtube Plugin for LMS](https://github.com/philippe44/LMS-YouTube).

Modified to use [yt-dlp](https://github.com/yt-dlp/yt-dlp) to fetch media urls instead of relying on its own logic.

Very first version, there might be dragons.

**Requires a working yt-dlp in `$PATH`.**

Hopefully, this approach means the plugin itself won't break as easily and we can rely on yt-dlp for actually figuring out any changes YT makes.

## Common pitfalls

### SSL issues

This plugin *requires* SSL so make sure it's installed on your LMS server. Not a problem for Windows, OSX, most Linux x86, Raspberry pi, Cubie, Odroid and others that use a Debian-based, but can be problematic with some NAS.
Other than that, Perl must have SSL support enabled, which again is available in all recent distribution and LMS versions (I think). But in case of problem and for Debian-ish Linux, you can try

```bash
sudo apt install libio-socket-ssl-perl libnet-ssleay-perl
```

at any command prompt.

### Country for Categories

Keep in mind that `UK` is *not* a region code, but `GB` is.
