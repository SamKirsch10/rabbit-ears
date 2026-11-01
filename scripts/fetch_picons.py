#!/usr/bin/env python3
"""
Downloads channel logos from the tv-logo/tv-logos GitHub repo and places
them where this TVHeadend server's picon config expects them.

Normally run this ON the TVHeadend server itself -- it writes to the local
picon directory on disk, taken from the server's own "piconpath" setting.
Pass --directory to write somewhere else instead (e.g. a mounted share),
if you're running it from another machine.

Usage:
    python3 fetch_picons.py [--base-url http://localhost:9981] [--user USER] [--password PASS]
                             [--force] [--dry-run] [--no-network-lookup] [--directory PATH]

Matching has two passes, both conservative on purpose -- a wrong logo is
worse than a missing one:

1. Direct: a channel's normalized name must EXACTLY match a logo filename
   upstream (e.g. "BUZZR" -> buzzr-us.png). No substring/fuzzy matching,
   since e.g. a loose match on "west" would wrongly grab
   "bally-sports-west-us.png".

2. Network fallback: for channels that look like a US ATSC call sign
   (WSB-HD, WAGA-HD, WXIA-TV, ...) and didn't match directly -- which is
   most local affiliates, since this logo repo has no per-station/per-
   market coverage -- looks the call sign up on Wikidata and, only if the
   result's description unambiguously names a known US network (e.g.
   "ABC affiliate in Atlanta"), uses that network's generic logo instead
   (e.g. abc-us.png). This is a stand-in for the actual station logo, not
   the station's own branding, and is always printed separately so you
   can tell which is which.

Anything neither pass can confidently resolve is left alone and printed
as unmatched, with any upstream filenames that merely contain the slug
listed as hints for manual review -- never auto-applied.
"""
import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

LOGO_REPO_API = "https://api.github.com/repos/tv-logo/tv-logos/contents/countries/united-states"
LOGO_RAW_BASE = "https://raw.githubusercontent.com/tv-logo/tv-logos/main/countries/united-states/"
USER_AGENT = "tvh-picon-fetcher/1.0 (personal picon script)"

WIKIDATA_SEARCH_API = "https://www.wikidata.org/w/api.php"
# Verified against the repo's actual file list -- don't guess these, several
# obvious names (plain "cbs-us.png") don't exist.
NETWORK_LOGOS = {
    "abc": "abc-us.png",
    "nbc": "nbc-us.png",
    "cbs": "cbs-logo-white-us.png",  # only a white variant exists upstream
    "fox": "fox-us.png",
    "cw": "cw-us.png",
    "pbs": "pbs-us.png",
    "telemundo": "telemundo-us.png",
    "univision": "univision-us.png",
    "ion": "ion-television-us.png",
}
NETWORK_PATTERN = re.compile(
    r"\b(ABC|NBC|CBS|Fox|The CW|CW|PBS|Telemundo|Univision|Ion)\b.{0,40}?"
    r"(affiliate|television station|owned-and-operated|O&O)",
    re.IGNORECASE,
)
# US call signs: W east of the Mississippi, K west, 3-4 letters, with TVHeadend
# often appending a stream-quality label (HD/SD) that ISN'T part of the real
# FCC call sign -- the actual suffix is almost always -TV/-LD/-CD, tried below.
CALLSIGN_RE = re.compile(r"^([wk][a-z]{2,4})[\s-]*(tv|hd|sd|cd|ld|dt\d*)?$")
CALLSIGN_SUFFIXES = ["-TV", "-LD", "-CD", ""]

# Pulled from an actual RF channel scan of this market (not guessed) -- checked
# first, before ever calling Wikidata, since it's free, instant, and 100%
# accurate for this lineup. Keys are base_name()-normalized (suffix stripped,
# uppercased, non-alphanumerics removed). Extend this if you rescan and find
# more affiliates; anything not listed here still falls through to the
# Wikidata fallback pass.
LOCAL_CALLSIGN_NETWORK = {
    "WSB": "abc",
    "WAGA": "fox",
    "WXIA": "nbc",
    "WUPA": "cbs",
    "WPCH": "cw",
    "PCH": "cw",
    "TMDO": "telemundo",
    "ION": "ion",
    "WGTV": "pbs",
    "WNGH": "pbs",
    "ATLPBS": "pbs",
    "WUVG": "univision",
    # GPB (Georgia Public Broadcasting) doesn't appear under this exact label
    # in the scan, but it's unambiguously the statewide PBS network.
    "GPB": "pbs",
}


def base_name(channel_name):
    """Normalized for matching against LOCAL_CALLSIGN_NETWORK and as the base
    call sign tried against Wikidata -- e.g. "WSB-HD" and "WSB HD" both
    become "WSB", since HD/SD here is TVHeadend's stream-quality label, not
    part of the real call sign."""
    s = channel_name.strip().upper()
    s = re.sub(r"[\s_-]*(HD|SD|CD|LD|DT\d*|TV)$", "", s)
    s = re.sub(r"[^A-Z0-9]", "", s)
    return s


def api_get(base_url, path, user=None, password=None, params=None):
    url = base_url.rstrip("/") + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    if user:
        creds = base64.b64encode(f"{user}:{password or ''}".encode()).decode()
        req.add_header("Authorization", f"Basic {creds}")
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode())


def fetch_logo_index():
    req = urllib.request.Request(LOGO_REPO_API, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=15) as resp:
        entries = json.loads(resp.read().decode())
    return sorted({e["name"] for e in entries if e["name"].endswith(".png")})


def normalize(name):
    name = name.lower()
    name = re.sub(r"[\s_-]*(hd|sd|cd)$", "", name)
    name = re.sub(r"[^a-z0-9]+", "-", name).strip("-")
    return name


def candidate_filenames(channel_name):
    slug = normalize(channel_name)
    return [f"{slug}-us.png", f"the-{slug}-us.png"]


def picon_filename_for(channel):
    icon = channel.get("icon", "")
    if not icon.startswith("picon://"):
        return None
    return icon[len("picon://"):]


def wikidata_search(query):
    url = WIKIDATA_SEARCH_API + "?" + urllib.parse.urlencode({
        "action": "wbsearchentities", "search": query,
        "language": "en", "format": "json", "limit": "5",
    })
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    # A single flaky request shouldn't abort a run with hundreds of Wikidata
    # calls in it -- retry transient errors a couple times, then give up on
    # just this one lookup (treated as "no match") rather than crashing.
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 2:
                time.sleep(int(e.headers.get("Retry-After", "10")) + 1)
                continue
            return {"search": []}
        except (urllib.error.URLError, OSError, ValueError):
            if attempt < 2:
                time.sleep(3)
                continue
            return {"search": []}
    return {"search": []}


def network_lookup(channel_name):
    """Returns (wikidata_label, description, network_key) or None."""
    m = CALLSIGN_RE.match(channel_name.strip().lower())
    if not m:
        return None
    base = m.group(1).upper()
    for suffix in CALLSIGN_SUFFIXES:
        data = wikidata_search(base + suffix)
        for item in data.get("search", []):
            desc = item.get("description", "") or ""
            match = NETWORK_PATTERN.search(desc)
            if match:
                network = match.group(1).lower().replace("the cw", "cw")
                if network in NETWORK_LOGOS:
                    return item["label"], desc, network
        time.sleep(1.5)  # be polite to Wikidata's API between queries
    return None


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--base-url", default="http://localhost:9981")
    parser.add_argument("--user")
    parser.add_argument("--password")
    parser.add_argument(
        "--force", action="store_true",
        help="Re-download even if the picon file already exists on disk"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show matches without writing files or contacting TVHeadend to reload"
    )
    parser.add_argument(
        "--no-network-lookup", action="store_true",
        help="Skip the Wikidata call-sign-to-network fallback pass entirely"
    )
    parser.add_argument(
        "--directory",
        help="Write picons here instead of asking TVHeadend for its configured "
             "piconpath -- needed if this script isn't running on the TVHeadend "
             "server itself (e.g. a mounted share with a different local path)"
    )
    args = parser.parse_args()

    print("Fetching channel list from TVHeadend...")
    channels = api_get(
        args.base_url, "/api/channel/grid", args.user, args.password, {"limit": "1000"}
    )["entries"]

    if args.directory:
        picon_dir = args.directory
    else:
        print("Fetching server config for picon path...")
        config = api_get(args.base_url, "/api/config/load", args.user, args.password)["entries"][0]
        picon_param = next((p for p in config["params"] if p["id"] == "piconpath"), None)
        picon_uri = (picon_param.get("value") or picon_param.get("default", "")) if picon_param else ""
        if not picon_uri.startswith("file://"):
            print(f"piconpath isn't a local file:// path ({picon_uri!r}); pass "
                  "--directory to override it, since this script only handles "
                  "local picon storage.", file=sys.stderr)
            sys.exit(1)
        picon_dir = urllib.parse.unquote(picon_uri[len("file://"):])
    print(f"Picon directory: {picon_dir}")

    print("Fetching tv-logo/tv-logos file index...")
    logo_index = fetch_logo_index()
    print(f"{len(logo_index)} US logos available upstream\n")

    matched = []       # (name, source_filename, dest_path)
    local_matched = []    # (name, network, source_filename, dest_path)
    network_matched = []  # (name, wikidata_label, description, source_filename, dest_path)
    unmatched = []      # (name, reason, hints)
    pending_network_lookup = []  # (name, dest_path)

    for channel in channels:
        name = channel["name"]
        target_filename = picon_filename_for(channel)
        if not target_filename:
            unmatched.append((name, "no picon:// icon reference on this channel", []))
            continue

        dest_path = os.path.join(picon_dir, target_filename)
        if os.path.exists(dest_path) and not args.force:
            continue  # already has an icon on disk; leave it alone

        found_source = next(
            (c for c in candidate_filenames(name) if c in logo_index), None
        )
        if found_source:
            matched.append((name, found_source, dest_path))
            continue

        network = LOCAL_CALLSIGN_NETWORK.get(base_name(name))
        if network:
            local_matched.append((name, network, NETWORK_LOGOS[network], dest_path))
            continue

        pending_network_lookup.append((name, dest_path))

    if not args.no_network_lookup and pending_network_lookup:
        print(f"Checking {len(pending_network_lookup)} unmatched channel(s) against "
              "Wikidata for a network affiliation (this calls an external API, "
              "rate-limited, so it can take a while)...\n")
        for name, dest_path in pending_network_lookup:
            result = network_lookup(name)
            if result:
                label, desc, network = result
                network_matched.append((name, label, desc, NETWORK_LOGOS[network], dest_path))
            else:
                slug = normalize(name)
                hints = [f for f in logo_index if slug and slug in f] if len(slug) >= 3 else []
                unmatched.append((name, "no exact or network match", hints))
    else:
        for name, dest_path in pending_network_lookup:
            slug = normalize(name)
            hints = [f for f in logo_index if slug and slug in f] if len(slug) >= 3 else []
            unmatched.append((name, "no exact match", hints))

    print(f"Matched {len(matched)} channel(s) directly:")
    for name, source, dest in matched:
        print(f"  {name:24s} -> {source}")

    print(f"\nMatched {len(local_matched)} channel(s) via known local network affiliation "
          "(generic network logo, not the station's own):")
    for name, network, source, dest in local_matched:
        print(f"  {name:24s} -> {source}   [{network}]")

    print(f"\nMatched {len(network_matched)} channel(s) via Wikidata network lookup "
          "(generic network logo, not the station's own):")
    for name, label, desc, source, dest in network_matched:
        print(f"  {name:24s} -> {source}   [{label}: \"{desc}\"]")

    print(f"\nUnmatched {len(unmatched)} channel(s):")
    for name, reason, hints in unmatched:
        hint_text = f" (possible: {', '.join(hints[:3])})" if hints else ""
        print(f"  {name:24s} -> {reason}{hint_text}")

    all_downloads = [(n, s, d) for n, s, d in matched] + \
                     [(n, s, d) for n, _, s, d in local_matched] + \
                     [(n, s, d) for n, _, _, s, d in network_matched]

    if args.dry_run:
        print("\nDry run: no files downloaded, TVHeadend not contacted.")
        return

    if all_downloads:
        print()
        os.makedirs(picon_dir, exist_ok=True)
        downloaded = 0
        for name, source, dest in all_downloads:
            url = LOGO_RAW_BASE + urllib.parse.quote(source)
            try:
                req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(req, timeout=15) as resp, open(dest, "wb") as f:
                    f.write(resp.read())
                print(f"Downloaded {name} -> {dest}")
                downloaded += 1
            except (urllib.error.URLError, OSError) as e:
                print(f"FAILED {name}: {e}", file=sys.stderr)

        if downloaded:
            print("\nTriggering TVHeadend to reload the image cache...")
            try:
                api_get(
                    args.base_url, "/api/imagecache/config/trigger",
                    args.user, args.password, {"trigger": "1"}
                )
                print("Done.")
            except Exception as e:
                print(f"Could not trigger the reload automatically: {e}", file=sys.stderr)
                print("Use the admin web UI, or restart tvheadend, to pick up the new files.",
                      file=sys.stderr)
    else:
        print("\nNothing to download.")


if __name__ == "__main__":
    main()
