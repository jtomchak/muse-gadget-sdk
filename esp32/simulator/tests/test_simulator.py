#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Headless smoke and deterministic framebuffer tests for the UI simulator."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

WIDTH = HEIGHT = 412
HERE = Path(__file__).resolve().parent
SCENARIOS = tuple(sorted((HERE / "scenarios").glob("*.txt")))


def read_ppm(path: Path, allow_black: bool = False) -> bytes:
    raw = path.read_bytes()
    header = f"P6\n{WIDTH} {HEIGHT}\n255\n".encode()
    assert raw.startswith(header), f"{path}: wrong PPM header"
    pixels = raw[len(header) :]
    assert len(pixels) == WIDTH * HEIGHT * 3, f"{path}: truncated framebuffer"
    assert allow_black or len(set(pixels)) > 8, f"{path}: framebuffer has too few colours"
    return pixels


def render(binary: Path, scenario: Path, output: Path, allow_black: bool = False) -> tuple[str, subprocess.CompletedProcess[str]]:
    env = {**os.environ, "SDL_VIDEODRIVER": "dummy", "SDL_AUDIODRIVER": "dummy"}
    proc = subprocess.run(
        [
            str(binary),
            "--headless",
            "--scenario",
            str(scenario),
            "--run-ms",
            "200",
            "--screenshot",
            str(output),
        ],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    assert proc.returncode == 0, f"{scenario.name}:\n{proc.stdout}\n{proc.stderr}"
    pixels = read_ppm(output, allow_black)
    return hashlib.sha256(pixels).hexdigest(), proc


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--width", type=int, default=412)
    args = parser.parse_args()
    global WIDTH, HEIGHT
    WIDTH = HEIGHT = args.width
    binary = args.binary.resolve()
    assert binary.is_file(), binary
    assert SCENARIOS, "no simulator scenarios found"

    with tempfile.TemporaryDirectory(prefix="muse-simulator-test-") as tmp:
        tmp_path = Path(tmp)
        hashes: dict[str, str] = {}
        for scenario in SCENARIOS:
            first, _ = render(binary, scenario, tmp_path / f"{scenario.stem}-1.ppm")
            second, _ = render(binary, scenario, tmp_path / f"{scenario.stem}-2.ppm")
            assert first == second, f"{scenario.name}: framebuffer is not deterministic"
            hashes[scenario.stem] = first

        assert len(set(hashes.values())) == len(hashes), f"scenarios rendered identically: {hashes}"

        def inspect(script: str, allow_black: bool = False) -> dict:
            scenario = tmp_path / "check.txt"
            scenario.write_text(script)
            _, proc = render(binary, scenario, tmp_path / "check.ppm", allow_black)
            return json.loads(next(line[9:] for line in proc.stdout.splitlines()
                                   if line.startswith("@preview ")))

        # These observe the production widgets and render loop, not just policy helpers.
        feedback = inspect("face=idle\npress=true\n")
        assert feedback["state"] == "PREPARING MIC", feedback
        released = inspect("face=idle\npress=true\npress=false\n")
        assert released["state"] == "READY", released
        idle = inspect("face=idle\nadvance=1000\n")
        battery = inspect("face=idle\nbattery=80\nusb=false\nadvance=1000\n")
        audio = inspect("face=listening\nadvance=1000\n")
        assert battery["avatar_frames"] < idle["avatar_frames"], (battery, idle)
        assert audio["avatar_frames"] < idle["avatar_frames"], (audio, idle)
        dimmed = inspect("face=idle\nbattery=80\nusb=false\nbrightness=80\nadvance=21000\n")
        assert dimmed["brightness"] == 30, dimmed
        wake = inspect("face=idle\nbattery=80\nusb=false\nbrightness=80\nadvance=21000\n"
                       "tool=next\n")
        assert wake["brightness"] == 80, wake
        requested = inspect("face=idle\npage_request=1\n")
        assert requested["page"] == 1, requested
        standby = inspect("face=idle\nbrightness=80\nasleep=true\n")
        assert standby["clock_visible"] and standby["brightness"] == 8 and not standby["dark"], standby
        later = inspect("face=idle\nasleep=true\nadvance=61000\n")
        assert later["clock"] != standby["clock"], (standby, later)
        awake = inspect("face=idle\nbrightness=80\nasleep=true\nadvance=1000\nasleep=false\n")
        assert not awake["clock_visible"] and awake["brightness"] == 80, awake
        screen_off = inspect("face=idle\nclock=false\nasleep=true\n", allow_black=True)
        assert screen_off["dark"] and not screen_off["clock_visible"], screen_off
        # Start the brew timer offline, let the screen sleep, then expire it.
        done = inspect("face=idle\nwifi=off\npage=1\ntool=next\ntool=next\ntool=next\n"
                       "tool=act\nasleep=true\nadvance=181000\n")
        assert done["tool_value"] == "00:00 DONE" and not done["dark"], done
        assert done["page"] == 1 and done["pages"] == 3, done
        paused = inspect("face=idle\nwifi=off\npage=1\ntool=next\ntool=next\n"
                         "tool=act\nadvance=10000\ntool=act\nadvance=60000\n")
        assert paused["tool_value"] == "24:50", paused
        offline = inspect("face=idle\nwifi=off\nadvance=1000\n")
        assert offline["state"] == "WI-FI OFF", offline

        # Showing shutdown must not lock subsequent preview state selections.
        after_off = tmp_path / "after-off.txt"
        after_off.write_text("face=off\n" + (HERE / "scenarios/listening.txt").read_text())
        recovered, _ = render(binary, after_off, tmp_path / "after-off.ppm")
        assert recovered == hashes["listening"], "Off prevented the next preview state"

        invalid = tmp_path / "invalid.txt"
        for setting in ("face=definitely-not-a-mode", "level=nan"):
            invalid.write_text(f"{setting}\n")
            proc = subprocess.run(
                [str(binary), "--headless", "--scenario", str(invalid)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=10,
            )
            assert proc.returncode == 2
            assert "unsupported or invalid setting" in proc.stderr

    for name, digest in sorted(hashes.items()):
        print(f"{name}: {digest}")


if __name__ == "__main__":
    main()
