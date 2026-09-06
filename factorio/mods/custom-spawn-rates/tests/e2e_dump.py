#!/usr/bin/env python3
"""End-to-end test for custom-spawn-rates via `factorio --dump-data`.

Builds an isolated Factorio user dir (temp mod dir + config with redirected
write-data, so the live server install is never touched), encodes a
mod-settings.dat with known test values, runs the real data stage, and
asserts on the dumped data.raw JSON.

Needs: the Factorio binary (default /factorio/bin/x64/factorio) and
python3 stdlib only. The mod-settings codec is reused from
.cache/factorio-data-codec (downloaded + checksum-verified on demand,
same pin as tools/sync-mod-settings).

Usage:
  python3 tests/e2e_dump.py [--factorio-bin PATH] [--keep-tmp]
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MOD_SRC = os.path.dirname(SCRIPT_DIR)
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(MOD_SRC)))
LIVE_CONFIG = "/factorio/config/config.ini"
DEFAULT_BIN = "/factorio/bin/x64/factorio"

CODEC_URL = ("https://codeberg.org/whitequark/factorio-data-codec/raw/commit/"
             "8efae46aef48b6b51b12d855af3406b76336f092/factorio_data.py")
CODEC_SHA256 = ("2ec54ed12d3d769e1cc014caaa05c5332f26f26c80f4b47ab2cbada3e71946c4")
CODEC_PY = os.path.join(REPO_ROOT, ".cache", "factorio-data-codec",
                        "factorio_data.py")

# Values under test: every op family, plus blank-means-untouched.
SPAWN_BITER = "-small-biter; medium-biter 0.2=0.0,0.6=0.4 # tune"
TECH_VALUE = ("# e2e tech tweaks\n"
              "steel-processing: trigger type=craft-item,item=iron-plate,count=200"
              "; automation: count 50; prereq electronics"
              "; effect {type=unlock-recipe,recipe=iron-chest},{type=unlock-recipe,recipe=copper-cable}"
              "; -prereq automation-science-pack,electronics"
              "; logistics: prerequisites automation"
              "; -ingredient automation-science-pack")

failures = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name
          + ("" if cond or not detail else f"\n      {detail}"))
    if not cond:
        failures.append(name)


def ensure_codec():
    if (os.path.isfile(CODEC_PY) and
            hashlib.sha256(open(CODEC_PY, "rb").read()).hexdigest()
            == CODEC_SHA256):
        return
    print("fetching mod-settings codec...")
    os.makedirs(os.path.dirname(CODEC_PY), exist_ok=True)
    tmp = CODEC_PY + ".tmp"
    urllib.request.urlretrieve(CODEC_URL, tmp)
    digest = hashlib.sha256(open(tmp, "rb").read()).hexdigest()
    if digest != CODEC_SHA256:
        os.unlink(tmp)
        sys.exit("error: codec checksum mismatch (upstream changed?)")
    os.rename(tmp, CODEC_PY)


def game_version(bin_path):
    out = subprocess.run([bin_path, "--version"], capture_output=True,
                         text=True).stdout
    m = re.search(r"Version:\s*(\d+)\.(\d+)\.(\d+)", out)
    if not m:
        sys.exit(f"error: cannot parse version from: {out.strip()}")
    return [int(m.group(1)), int(m.group(2)), int(m.group(3)), 0]


def main():
    factorio_bin = DEFAULT_BIN
    keep_tmp = False
    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg == "--factorio-bin":
            factorio_bin = args[i + 1]
        elif arg == "--keep-tmp":
            keep_tmp = True
    if not os.path.isfile(factorio_bin):
        sys.exit(f"error: no Factorio binary at {factorio_bin} "
                 "(pass --factorio-bin PATH)")

    ensure_codec()
    version = game_version(factorio_bin)

    tmp = tempfile.mkdtemp(prefix="csr-e2e-")
    mods = os.path.join(tmp, "mods")
    user = os.path.join(tmp, "user")
    os.makedirs(mods)
    shutil.copytree(MOD_SRC, os.path.join(mods, "custom-spawn-rates"))

    # Phase 1 runs with space-age on so the Gleba nests exist; phase 2
    # re-runs base-only with mod defaults (regression test).
    with open(os.path.join(mods, "mod-list.json"), "w") as f:
        json.dump({"mods": [
            {"name": "base", "enabled": True},
            {"name": "space-age", "enabled": True},
            {"name": "elevated-rails", "enabled": True},
            {"name": "quality", "enabled": True},
            {"name": "custom-spawn-rates", "enabled": True},
        ]}, f)

    env_path = os.path.join(tmp, "envelope.json")
    dat_path = os.path.join(mods, "mod-settings.dat")

    def write_dat(startup):
        # Encode mod-settings.dat from a JSON envelope (same shape the
        # codec itself produces). Missing keys fall back to mod defaults.
        envelope = {
            "!type": "ModSettings", "version": version,
            "has_quality": False,
            "data": {"startup": startup, "runtime-global": {},
                       "runtime-per-user": {}},
        }
        json.dump(envelope, open(env_path, "w"))
        subprocess.run([sys.executable, CODEC_PY, env_path, dat_path],
                       check=True, capture_output=True)

    with open(LIVE_CONFIG) as f:
        config = f.read()
    config = re.sub(r"(?m)^write-data=.*$", f"write-data={user}", config)
    config_path = os.path.join(tmp, "config.ini")
    open(config_path, "w").write(config)

    def dump_data():
        proc = subprocess.run(
            [factorio_bin, "-c", config_path, "--mod-directory", mods,
             "--dump-data"],
            capture_output=True, text=True, timeout=600)
        return proc.returncode, proc.stdout + proc.stderr

    write_dat({
        "custom-spawn-rates-biter-spawner": {"value": SPAWN_BITER},
        "custom-spawn-rates-spitter-spawner": {"value": ""},
        "custom-spawn-rates-gleba-spawner":
            {"value": "medium-strafer-pentapod 0.5=0.2"},
        "custom-spawn-rates-gleba-spawner-small":
            {"value": "-small-wriggler-pentapod"},
        "custom-spawn-rates-extra": {"value": ""},
        "custom-spawn-rates-tech": {"value": TECH_VALUE},
    })
    print(f"running {factorio_bin} --dump-data ...")
    returncode, log = dump_data()
    check("factorio --dump-data exits 0", returncode == 0,
          log[-2000:] if returncode else "")
    if returncode != 0:
        print(f"tmp dir kept at {tmp}")
        sys.exit(1)
    check("spawn setting applied in data stage",
          'removed "small-biter" from biter-spawner' in log, log[-2000:])
    check("tech setting applied in data stage",
          "research trigger set" in log and "count set to 50" in log,
          log[-2000:])

    dump = os.path.join(user, "script-output", "data-raw-dump.json")
    check("data-raw-dump.json written", os.path.isfile(dump))
    if not os.path.isfile(dump):
        print(f"tmp dir kept at {tmp}")
        sys.exit(1)
    data = json.load(open(dump))

    units = {u[0]: u[1] for u in
             data["unit-spawner"]["biter-spawner"]["result_units"]}
    check("spawn remove: no small-biter in biter-spawner",
          "small-biter" not in units, sorted(units))
    check("spawn set: medium-biter table replaced",
          units.get("medium-biter") == [[0.2, 0.0], [0.6, 0.4]],
          units.get("medium-biter"))
    check("spawn order preserved after remove",
          list(units) == ["medium-biter", "big-biter", "behemoth-biter"],
          list(units))
    spitter = [u[0] for u in
               data["unit-spawner"]["spitter-spawner"]["result_units"]]
    check("blank setting leaves nest untouched",
          "small-spitter" in spitter, spitter[:5])
    gleba_small = [u[0] for u in
                   data["unit-spawner"]["gleba-spawner-small"]["result_units"]]
    check("gleba remove works",
          gleba_small == ["medium-wriggler-pentapod",
                          "big-wriggler-pentapod"],
          gleba_small)
    gleba = {u[0]: u[1] for u in
             data["unit-spawner"]["gleba-spawner"]["result_units"]}
    check("gleba set works",
          gleba.get("medium-strafer-pentapod") == [[0.5, 0.2]],
          gleba.get("medium-strafer-pentapod"))

    steel = data["technology"]["steel-processing"]
    check("trigger set with converted count",
          steel.get("research_trigger") == {"type": "craft-item",
                                            "item": "iron-plate",
                                            "count": 200},
          steel.get("research_trigger"))
    check("trigger set clears unit", steel.get("unit") is None,
          steel.get("unit"))
    check("trigger set preserves prerequisites",
          steel.get("prerequisites") == ["automation-science-pack"],
          steel.get("prerequisites"))

    auto = data["technology"]["automation"]
    check("count set on lab tech",
          (auto.get("unit") or {}).get("count") == 50, auto.get("unit"))
    check("prereq add then list-remove works",
          auto.get("prerequisites") == [] or auto.get("prerequisites") == {},
          auto.get("prerequisites"))

    logi = data["technology"]["logistics"]
    check("prerequisites wholesale replace works",
          logi.get("prerequisites") == ["automation"],
          logi.get("prerequisites"))
    logi_ing = (logi.get("unit") or {}).get("ingredients")
    check("ingredient remove works",
          logi_ing == [] or logi_ing == {}, logi_ing)
    auto_fx = auto.get("effects") or []
    auto_unlocks = sorted(e.get("recipe") for e in auto_fx
                           if e.get("type") == "unlock-recipe" and
                           e.get("recipe") in ("iron-chest", "copper-cable"))
    check("effect add works (braced list in one op)",
          auto_unlocks == ["copper-cable", "iron-chest"], auto_fx)

    # Phase 2: shipped defaults on a base-only install (regression test —
    # Space Age unit names as defaults used to hard-fail map load here).
    write_dat({})
    print("re-running --dump-data with mod defaults ...")
    returncode, log = dump_data()
    check("defaults load on base-only install (exit 0)", returncode == 0,
          log[-2000:] if returncode else "")
    if returncode == 0:
        vanilla = json.load(open(dump))
        vanilla_units = [u[0] for u in
                         vanilla["unit-spawner"]["biter-spawner"]["result_units"]]
        check("defaults leave biter-spawner vanilla",
              "small-biter" in vanilla_units
              and not any("pentapod" in u for u in vanilla_units),
              vanilla_units)

    print(f"\n{len(failures)} failed")
    if failures or keep_tmp:
        print(f"tmp dir kept at {tmp}")
    else:
        shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(1 if failures else 0)


main()
