#!/usr/bin/env python3
"""Convert the modeler's Zlib JSON R6 animation format to Roblox .rbxmx."""
import argparse
import json
import math
import zlib
from pathlib import Path
from xml.etree.ElementTree import Element, SubElement, ElementTree

PARTS = ("Torso", "Right Arm", "Left Arm", "Right Leg", "Left Leg", "Head")
PARENTS = {"Torso": "HumanoidRootPart", "Right Arm": "Torso", "Left Arm": "Torso",
           "Right Leg": "Torso", "Left Leg": "Torso", "Head": "Torso"}
ROT_NAMES = ("R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22")

def item(parent, cls, ref):
    return SubElement(parent, "Item", {"class": cls, "referent": ref})

def prop(parent, tag, name, value):
    node = SubElement(parent, tag, {"name": name})
    node.text = str(value)
    return node

def pose(parent, name, values, easing_style, easing_direction, ref):
    node = item(parent, "Pose", ref)
    props = SubElement(node, "Properties")
    cf = SubElement(props, "CoordinateFrame", {"name": "CFrame"})
    for axis, value in zip(("X", "Y", "Z"), values[:3]):
        SubElement(cf, axis).text = repr(value)
    for axis, value in zip(ROT_NAMES, values[3:]):
        SubElement(cf, axis).text = repr(value)
    prop(props, "string", "Name", name)
    prop(props, "float", "Weight", 1)
    styles = {"Linear": 0, "Constant": 1, "Elastic": 2, "Cubic": 3, "Bounce": 4, "CubicV2": 5, "ConstantV2": 6, "LinearV2": 7}
    directions = {"In": 0, "Out": 1, "InOut": 2}
    if easing_style not in styles or easing_direction not in directions:
        raise ValueError(f"Unsupported pose easing: {easing_style}/{easing_direction}")
    prop(props, "token", "EasingStyle", styles[easing_style])
    prop(props, "token", "EasingDirection", directions[easing_direction])
    return node

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--name", help="KeyframeSequence name (defaults to output filename stem)")
    args = parser.parse_args()
    try:
        data = json.loads(zlib.decompress(args.source.read_bytes()))
    except (zlib.error, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"Source is not valid zlib-compressed UTF-8 JSON: {exc}") from exc
    frames = data["kfs"]
    if not frames:
        raise ValueError("Animation has no keyframes")
    duration = float(data["t"])
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("Animation duration must be a finite positive number")
    previous = -1.0
    for frame in frames:
        t = float(frame["t"])
        if (not math.isfinite(t) or t < 0 or t <= previous
                or not set(frame["kf"]).issubset(PARTS) or not frame["kf"]):
            raise ValueError("Frame order/part set is invalid")
        previous = t
        for name in frame["kf"]:
            source_pose = frame["kf"][name]
            vals = source_pose[0]
            if len(vals) != 12 or not all(math.isfinite(v) for v in vals):
                raise ValueError(f"Invalid CFrame for {name} at {t}")
            # CFrame constructor consumes translation then row-major rotation.
            a = vals[3:]
            rows = (a[0:3], a[3:6], a[6:9])
            for i in range(3):
                for j in range(3):
                    dot = sum(rows[i][k] * rows[j][k] for k in range(3))
                    if abs(dot - (1 if i == j else 0)) > 0.02:
                        raise ValueError(f"Non-orthonormal rotation {name} at {t}")
            determinant = a[0]*(a[4]*a[8]-a[5]*a[7]) - a[1]*(a[3]*a[8]-a[5]*a[6]) + a[2]*(a[3]*a[7]-a[4]*a[6])
            if abs(determinant - 1) > 0.05:
                raise ValueError(f"Rotation determinant invalid for {name} at {t}")
    if abs(previous - duration) > 1e-6:
        raise ValueError(f"Declared duration {duration} does not match last keyframe {previous}")

    root = Element("roblox", {"version": "4", "xmlns:xmime": "http://www.w3.org/2005/05/xmlmime"})
    seq = item(root, "KeyframeSequence", "RBX0")
    props = SubElement(seq, "Properties")
    prop(props, "bool", "Loop", "true")
    prop(props, "string", "Name", args.name or args.output.stem)
    prop(props, "token", "Priority", 2)  # Movement
    ids = 1
    for frame in frames:
        kf = item(seq, "Keyframe", f"RBX{ids}"); ids += 1
        kp = SubElement(kf, "Properties")
        prop(kp, "float", "Time", repr(float(frame["t"])))
        prop(kp, "string", "Name", "")
        # Neutral structural root, as used by Roblox animation hierarchies.
        nodes = {"HumanoidRootPart": pose(kf, "HumanoidRootPart", [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1], "Linear", "Out", f"RBX{ids}")}; ids += 1
        if "Torso" not in frame["kf"]:
            # Keep the R6 parent chain valid without adding a transform to the source.
            nodes["Torso"] = pose(nodes["HumanoidRootPart"], "Torso", [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1], "Linear", "Out", f"RBX{ids}"); ids += 1
        for name in ("Torso", "Head", "Right Arm", "Left Arm", "Right Leg", "Left Leg"):
            if name not in frame["kf"]:
                continue
            parent_name = PARENTS[name]
            source_pose = frame["kf"][name]
            vals = source_pose[0]
            nodes[name] = pose(nodes[parent_name], name, vals, source_pose[1], source_pose[2], f"RBX{ids}"); ids += 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    ElementTree(root).write(args.output, encoding="utf-8", xml_declaration=True)
    print(f"Converted {args.source} -> {args.output}: {len(frames)} keyframes, {duration:.6f}s, {data.get('export_info', {}).get('fps')} FPS")

if __name__ == "__main__":
    main()
