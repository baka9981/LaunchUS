#!/usr/bin/env python3
"""Release and beta in one Sparkle feed, for publish.sh.

A feed holds the release first (no channel, every Mac sees it) and then, while one is being
tested, a beta: the same kind of item marked <sparkle:channel>beta</sparkle:channel>, which only
Macs with 接收 Beta 版 on are offered. Anything reading "the first item" still finds the release.

  appcast.py info  FEED                      release and beta: "short build" lines, "-" for none
  appcast.py merge LIVE NEW --stable|--beta  print the feed with NEW as the release or the beta
  appcast.py promote LIVE                    print the feed with the beta made the release
  appcast.py withdraw LIVE                   print the feed without the beta

LIVE may be a missing or empty file (the first release).
"""
import copy
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
S = "{" + SPARKLE_NS + "}"
ET.register_namespace("sparkle", SPARKLE_NS)


def load(path):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return None
    return ET.fromstring(text) if text.strip() else None


def items(root):
    """(release item, beta item), either None."""
    release = beta = None
    for item in [] if root is None else root.findall("channel/item"):
        channel = (item.findtext(S + "channel") or "").strip()
        if channel == "beta":
            beta = beta if beta is not None and newer(beta, item) else item
        elif not channel:
            release = release if release is not None and newer(release, item) else item
    return release, beta


def build(item):
    enc = item.find("enclosure")
    b = item.findtext(S + "version") or (enc.get(S + "version") if enc is not None else "") or "0"
    return [int(x) if x.isdigit() else 0 for x in re.split(r"[.\-]", b.strip())]


def newer(a, b):
    return build(a) >= build(b)


def short(item):
    enc = item.find("enclosure")
    return (item.findtext(S + "shortVersionString") or (enc.get(S + "shortVersionString") if enc is not None else "") or "").strip()


def as_channel(item, channel):
    item = copy.deepcopy(item)
    for old in item.findall(S + "channel"):
        item.remove(old)
    if channel:
        tag = ET.SubElement(item, S + "channel")
        tag.text = channel
        tag.tail = item[-2].tail if len(item) > 1 else None
    return item


def write(template, release, beta):
    """The feed with just these items, release first."""
    root = copy.deepcopy(template)
    channel = root.find("channel")
    for old in channel.findall("item"):
        channel.remove(old)
    for item in (release, beta):
        if item is not None:
            channel.append(item)
    ET.indent(root, space="    ")
    return '<?xml version="1.0" standalone="yes"?>\n' + ET.tostring(root, encoding="unicode") + "\n"


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd = argv[0]
    live = load(argv[1])
    release, beta = items(live)
    if cmd == "info":
        for item in (release, beta):
            print(f"{short(item)} {'.'.join(map(str, build(item)))}" if item is not None else "-")
        return
    if cmd == "merge":
        new = load(argv[2])
        new_item = items(new)[0]
        if new_item is None:
            sys.exit(f"{argv[2]} has no version")
        if "--beta" in argv:
            if release is not None and not build(new_item) > build(release):
                sys.exit(f"Beta {short(new_item)} isn't newer than the release {short(release)}")
            if beta is not None and build(new_item) < build(beta):
                sys.exit(f"Beta {short(new_item)} is older than the beta out now, {short(beta)}")
            print(write(new, release, as_channel(new_item, "beta")), end="")
        else:
            # A beta ahead of this release stays for the Macs testing it; one behind is done.
            keep = beta if beta is not None and build(beta) > build(new_item) else None
            print(write(new, new_item, keep), end="")
        return
    if cmd == "promote":
        if beta is None:
            sys.exit("There is no beta to promote")
        print(write(live, as_channel(beta, None), None), end="")
        return
    if cmd == "withdraw":
        print(write(live, release, None), end="")
        return
    sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
