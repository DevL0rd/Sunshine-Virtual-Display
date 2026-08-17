#!/usr/bin/env python3
import argparse
import json
import pathlib
import re


managed = ["capture", "encoder", "nvenc_twopass", "output_name", "global_prep_cmd"]


def key_for(line):
    match = re.match(r"^\s*([A-Za-z0-9_]+)\s*=", line)
    return match.group(1) if match else None


def write(path, lines):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "\n".join(lines)
    if text:
        text += "\n"
    path.write_text(text, encoding="utf-8")


parser = argparse.ArgumentParser()
parser.add_argument("action", choices=["install", "uninstall"])
parser.add_argument("config")
parser.add_argument("state")
parser.add_argument("home")
parser.add_argument("virtual_output", nargs="?")
parser.add_argument("--adopt-existing", action="store_true")
args = parser.parse_args()
config = pathlib.Path(args.config)
state = pathlib.Path(args.state)
lines = config.read_text(encoding="utf-8").splitlines() if config.exists() else []
if args.action == "install":
    if not state.exists():
        originals = {key: None for key in managed}
        if not args.adopt_existing:
            for line in lines:
                key = key_for(line)
                if key in originals and originals[key] is None:
                    originals[key] = line
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(json.dumps({"config_existed": config.exists(), "originals": originals}, indent=2) + "\n", encoding="utf-8")
    else:
        saved = json.loads(state.read_text(encoding="utf-8"))
        originals = saved.setdefault("originals", {})
        changed = False
        for managed_key in managed:
            if managed_key not in originals:
                originals[managed_key] = next((line for line in lines if key_for(line) == managed_key), None)
                changed = True
        if changed:
            state.write_text(json.dumps(saved, indent=2) + "\n", encoding="utf-8")
    lines = [line for line in lines if key_for(line) not in managed]
    home = args.home.rstrip("/")
    lines.extend([
        "capture = kms",
        "encoder = nvenc",
        "nvenc_twopass = disabled",
        f"output_name = {args.virtual_output}",
        f'global_prep_cmd = [{{"do":"{home}/.local/bin/sunshine-vdisplay-up","undo":"{home}/.local/bin/sunshine-vdisplay-down"}}]',
    ])
    write(config, lines)
else:
    if not state.exists():
        raise SystemExit(0)
    saved = json.loads(state.read_text(encoding="utf-8"))
    lines = [line for line in lines if key_for(line) not in managed]
    for key in managed:
        original = saved["originals"].get(key)
        if original is not None:
            lines.append(original)
    if lines or saved["config_existed"]:
        write(config, lines)
    elif config.exists():
        config.unlink()
    state.unlink()
