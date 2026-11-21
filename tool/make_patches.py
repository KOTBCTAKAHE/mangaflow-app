"""OTA: delta patches from the previous releases to this one + ota.json (run in CI).

    python tool/make_patches.py v2.6.2 release/

For every ABI APK in release/ and every published release since 2.7.0 (the first version
that can apply patches) that has the same ABI, writes MangaFlow-<old>-to-<new>-<abi>.mfdelta (tool/mfdelta.py format). The app
picks the patch whose from_sha256 matches its installed APK, rebuilds the new APK
and verifies to_sha256 before installing.
"""
import hashlib
import json
import os
import sys
import urllib.request
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import mfdelta  # noqa: E402

REPO = os.environ.get("GITHUB_REPOSITORY", "KOTBCTAKAHE/mangaflow-app")
ABIS = ("arm64", "armv7", "universal")
FIRST_OTA = (2, 7, 0)  # older apps have no patcher: they get the full APK anyway
KEEP_UNIVERSAL = 3  # the 145 MB universal APK is rare and slow to diff: recent releases only
MAX_RATIO = 0.6  # a patch bigger than this share of the APK isn't worth it


def sha(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "mangaflow-ci",
                                               **({"Authorization": f"Bearer {os.environ['GH_TOKEN']}"} if os.environ.get("GH_TOKEN") else {})})
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read()


def make(job: tuple[str, str, str, str]) -> dict | None:
    old_tag, abi, url, new_path = job
    new = Path(new_path)
    work = new.parent / ".old"
    work.mkdir(exist_ok=True)
    old = work / f"{old_tag}-{abi}.apk"
    old.write_bytes(get(url))
    data = mfdelta.diff(old.read_bytes(), new.read_bytes())
    if len(data) > MAX_RATIO * new.stat().st_size:
        print(f"skip {old_tag}->{abi}: patch {len(data)} too big")
        return None
    assert mfdelta.patch(old.read_bytes(), data) == new.read_bytes(), "patch does not rebuild the APK"
    from_sha = sha(old)
    old.unlink()  # dozens of old APKs would fill the runner's disk
    name = f"MangaFlow-{old_tag}-to-{new.name.split('-')[1]}-{abi}.mfdelta"
    out = new.parent / name
    out.write_bytes(data)
    print(f"{name}: {len(data) / 1e6:.1f} MB ({len(data) / new.stat().st_size:.0%} of the APK)")
    return {"from": old_tag.lstrip("v"), "abi": abi, "name": name, "size": len(data), "sha256": sha(out),
            "from_sha256": from_sha}


def version(tag: str) -> tuple[int, ...]:
    try:
        return tuple(int(x) for x in tag.lstrip("v").split("+")[0].split("."))
    except ValueError:
        return (0,)


def main() -> None:
    tag, rel = sys.argv[1], Path(sys.argv[2])
    apks = {abi: rel / f"MangaFlow-{tag}-{abi}.apk" for abi in ABIS if (rel / f"MangaFlow-{tag}-{abi}.apk").exists()}
    releases = [r for r in json.loads(get(f"https://api.github.com/repos/{REPO}/releases?per_page=100"))
                if not r.get("draft") and not r.get("prerelease") and r["tag_name"] != tag
                and FIRST_OTA <= version(r["tag_name"]) < version(tag)]
    releases.sort(key=lambda r: version(r["tag_name"]), reverse=True)
    jobs = []
    for i, r in enumerate(releases):
        assets = {a["name"]: a["browser_download_url"] for a in r.get("assets", [])}
        for abi, new in apks.items():
            if abi == "universal" and i >= KEEP_UNIVERSAL:
                continue
            url = assets.get(f"MangaFlow-{r['tag_name']}-{abi}.apk")
            if url:
                jobs.append((r["tag_name"], abi, url, str(new)))
    with ProcessPoolExecutor(max_workers=4) as pool:
        patches = [p for p in pool.map(make, jobs) if p]
    for p in patches:
        p["to_sha256"] = sha(apks[p["abi"]])
    manifest = {
        "format": "MFDELTA1",
        "version": tag.lstrip("v"),
        "apks": [{"abi": abi, "name": p.name, "size": p.stat().st_size, "sha256": sha(p)} for abi, p in apks.items()],
        "patches": patches,
    }
    (rel / "ota.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1))
    for f in (rel / ".old").glob("*"):
        f.unlink()
    print(f"ota.json: {len(patches)} patches")


if __name__ == "__main__":
    main()
