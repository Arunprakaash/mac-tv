#!/usr/bin/env python3 -I
"""Builds Resources/TopShelf.json: each streaming app's most popular shows, for the Top Shelf.

Show data and images come from TVmaze (https://www.tvmaze.com), under CC BY-SA. Show title logos
come from Wikidata and Wikimedia Commons. No API keys. Run before a release to refresh the lists:

    python3 -I scripts/update-top-shelf.py            # shows, images and logos
    python3 -I scripts/update-top-shelf.py --logos    # only add logos to the existing list
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Mac TV's app id -> TVmaze streaming service names.
SERVICES = {
    "netflix": ["Netflix"],
    "prime": ["Prime Video", "Amazon Prime Video"],
    "appletv": ["Apple TV", "Apple TV+"],
    "hotstar": ["JioHotstar", "Disney+ Hotstar", "Hotstar"],
}
PER_SERVICE = 10
SINCE_YEAR = 2016


def get(url):
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "MacTV-TopShelf (github.com/Arunprakaash/mac-tv)"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code == 429:  # TVmaze allows about 20 requests every 10 seconds.
                time.sleep(2 + attempt * 2)
                continue
            raise
    return None


def logo_for(imdb_ids):
    """Title logos from Wikidata (property P154, logo image), by IMDb id, rendered by Wikimedia."""
    values = " ".join(f'"{i}"' for i in imdb_ids)
    query = f"SELECT ?imdb ?logo WHERE {{ VALUES ?imdb {{ {values} }} ?item wdt:P345 ?imdb . ?item wdt:P154 ?logo }}"
    data = get("https://query.wikidata.org/sparql?format=json&query=" + urllib.parse.quote(query)) or {}
    found = {}
    for row in data.get("results", {}).get("bindings", []):
        url = row["logo"]["value"]
        name = urllib.parse.unquote(url.rsplit("/", 1)[-1])
        # Prefer an English-looking file named as a logo, when a show has several.
        score = ("logo" in name.lower()) * 2 + name.isascii()
        imdb = row["imdb"]["value"]
        if imdb not in found or score > found[imdb][0]:
            found[imdb] = (score, "https://commons.wikimedia.org/wiki/Special:FilePath/" + urllib.parse.quote(name) + "?width=1000")
    return {imdb: url for imdb, (_, url) in found.items()}


def add_logos(path):
    with open(path) as f:
        data = json.load(f)
    shows = [show for shows in data["services"].values() for show in shows]
    imdb = {}
    for show in shows:
        detail = get(f"https://api.tvmaze.com/shows/{show['id']}") or {}
        imdb[show["id"]] = (detail.get("externals") or {}).get("imdb")
        time.sleep(0.5)
    logos = logo_for([i for i in imdb.values() if i])
    for show in shows:
        logo = logos.get(imdb.get(show["id"]) or "")
        if logo:
            show["logo"] = logo
        else:
            show.pop("logo", None)
    data["source"] = "TVmaze (tvmaze.com), CC BY-SA; logos from Wikidata and Wikimedia Commons"
    with open(path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"Logos for {sum('logo' in s for s in shows)} of {len(shows)} shows", file=sys.stderr)


OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "TopShelf.json")


def main():
    if "--logos" in sys.argv:
        add_logos(OUT)
        return
    wanted = {name: app for app, names in SERVICES.items() for name in names}
    candidates = {app: [] for app in SERVICES}
    page = 0
    while True:
        shows = get(f"https://api.tvmaze.com/shows?page={page}")
        if not shows:
            break
        for show in shows:
            channel = (show.get("webChannel") or {}).get("name")
            app = wanted.get(channel)
            premiered = (show.get("premiered") or "0")[:4]
            if app and premiered.isdigit() and int(premiered) >= SINCE_YEAR:
                candidates[app].append(show)
        page += 1
        print(f"page {page}", file=sys.stderr, end="\r")
        time.sleep(0.5)

    result = {}
    for app, shows in candidates.items():
        picked = []
        for show in sorted(shows, key=lambda s: s.get("weight") or 0, reverse=True):
            images = get(f"https://api.tvmaze.com/shows/{show['id']}/images") or []
            time.sleep(0.5)
            # The widest landscape background, at least 1280 wide.
            backgrounds = [i["resolutions"]["original"] for i in images if i.get("type") == "background"]
            backgrounds = [b for b in backgrounds if b["width"] >= 1280 and b["width"] / max(b["height"], 1) >= 1.5]
            if not backgrounds:
                continue
            best = max(backgrounds, key=lambda b: b["width"])
            picked.append({"id": show["id"], "name": show["name"], "image": best["url"]})
            if len(picked) == PER_SERVICE:
                break
        result[app] = picked
        print(f"{app}: {[p['name'] for p in picked]}", file=sys.stderr)

    out = OUT
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump({"source": "TVmaze (tvmaze.com), CC BY-SA", "services": result}, f, indent=2, ensure_ascii=False)
    print(f"Wrote {os.path.normpath(out)}", file=sys.stderr)
    add_logos(out)


main()
