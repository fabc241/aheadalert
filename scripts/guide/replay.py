#!/usr/bin/env python3
"""Draws what the obstacle guide saw, from a diagnostic recording (MVP step 1.1), and compares scale methods.

For every recorded frame (image, raw depth map, camera pose, floor plane, ARKit feature points, scale used on
the phone) it writes a picture with one row per method:
  "phone"    – the scale a, b the phone actually used (fitted on the floor only);
  "features" – a scale fitted on the ARKit feature points (metric, wherever they are: floor, furniture, walls).
Each row has three panels:
  1. the camera image in portrait, samples coloured by what they were taken for:
     green = floor, red / orange / magenta = obstacle left / ahead / right,
     blue = above the floor but outside the walking corridor or beyond 2 m; feature points as small white dots;
  2. the depth map (bright = near);
  3. a top-down view (metres): the user at the bottom, grid every 0.5 m, the corridor and the 2 m limit,
     points coloured by height (green floor, yellow low, red high), ARKit feature points in cyan.
The caption gives the zones (as the phone would announce them) and "feat err": the median error of the
converted depth against the ARKit feature points (a measure of how wrong the metric scale is).
The geometry mirrors ObstacleAnalyzer.swift (same thresholds).

Usage (from mobile/): python3 scripts/guide/replay.py scripts/guide/logs/rec-<date> [every]
Output: <recording>/overlay/NNNN.png and a summary table on stdout.
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ALERT, MIN_FWD, CENTRE, SIDE = 2.0, 0.4, 0.30, 0.60
MIN_H, MAX_H, TOL, LOW_H, MIN_AREA = 0.10, 2.0, 0.08, 0.5, 0.02
FLOOR_MIN, FLOOR_MAX = 0.5, 3.5
ZONE_COLOURS = [(255, 40, 40), (255, 150, 0), (230, 0, 230)]  # left, ahead, right
RNG = np.random.default_rng(0)


class Frame:
    def __init__(self, rec, name):
        self.name = name
        self.meta = m = json.loads((rec / f"{name}.json").read_text())
        self.H, self.W = H, W = m["depthHeight"], m["depthWidth"]
        self.depth = np.fromfile(rec / f"{name}.depth", dtype=np.float32).reshape(H, W)
        self.photo = Image.open(rec / f"{name}.jpg").convert("RGB").resize((W, H))
        t = np.array(m["transform"], dtype=np.float64).reshape(4, 4)  # rows of this array are matrix columns
        self.R, self.origin = t[:3, :3].T, t[3, :3]
        k = np.array(m["intrinsics"]).reshape(3, 3)
        self.fx, self.fy, self.cx, self.cy = k[0, 0], k[1, 1], k[2, 0], k[2, 1]
        self.su, self.sv = m["imageWidth"] / W, m["imageHeight"] / H
        jj, ii = np.mgrid[0:H, 0:W]
        u, v = (ii + 0.5) * self.su, (jj + 0.5) * self.sv
        cam = np.stack([(u - self.cx) / self.fx, -(v - self.cy) / self.fy, -np.ones_like(u)], axis=-1)
        self.rays = cam @ self.R.T
        wd = m.get("walkDirection")
        fwd = np.array(wd, dtype=np.float64) if wd else -self.R[:, 2].copy()  # walking direction when recorded
        fwd[1] = 0
        self.fwd = fwd / np.linalg.norm(fwd)
        self.right = np.array([-self.fwd[2], 0, self.fwd[0]])
        self.floor_y = m["floorY"]
        self.pitch = math.degrees(math.asin(max(-1, min(1, -self.R[1, 2]))))
        self.features = self._features()

    def _features(self):
        """ARKit feature points in view: world point, z-depth Z, depth-map pixel and the model value there."""
        p = np.array(self.meta.get("features", []), dtype=np.float64).reshape(-1, 3)
        if not len(p):
            return None
        c = (p - self.origin) @ self.R  # camera coordinates
        Z = -c[:, 2]
        ok = Z > 0.15
        p, c, Z = p[ok], c[ok], Z[ok]
        u = self.cx + self.fx * c[:, 0] / Z
        v = self.cy - self.fy * c[:, 1] / Z
        i = np.floor(u / self.su).astype(int)
        j = np.floor(v / self.sv).astype(int)
        ok = (i >= 1) & (i < self.W - 1) & (j >= 1) & (j < self.H - 1)
        p, Z, i, j = p[ok], Z[ok], i[ok], j[ok]
        if not len(Z):
            return None
        # median of the 3×3 neighbourhood: the map is smooth, edges are not
        d = np.median(np.stack([self.depth[j + dj, i + di] for dj in (-1, 0, 1) for di in (-1, 0, 1)]), axis=0)
        return {"world": p, "Z": Z, "i": i, "j": j, "d": d}


def fit_features(f, tol=0.15):
    """RANSAC on (1/Z, d) of the feature points, then least squares on the inliers."""
    ft = f.features
    if ft is None or len(ft["Z"]) < 15:
        return None
    w, d = 1 / ft["Z"], ft["d"]
    n = len(w)
    best, best_n = None, 0
    for _ in range(300):
        i, j = RNG.integers(0, n, 2)
        if abs(w[j] - w[i]) < 0.1 * max(w[i], w[j]):
            continue
        a = (d[j] - d[i]) / (w[j] - w[i])
        if a <= 0:
            continue
        b = d[i] - a * w[i]
        inl = np.abs((d - b) / a - w) <= tol * w
        if inl.sum() > best_n:
            best, best_n = inl, inl.sum()
    if best is None or best_n < 12 or best_n < 0.4 * n:
        return None
    A = np.stack([w[best], np.ones(best_n)], axis=1)
    a, b = np.linalg.lstsq(A, d[best], rcond=None)[0]
    if a <= 0:
        return None
    return a, b, int(best_n), n


def classify(f, a, b):
    """Same rules as ObstacleAnalyzer.swift, on every pixel. Returns labels, top-down points and the zones."""
    labels = np.zeros((f.H, f.W), np.uint8)  # 0 nothing, 1 floor, 2-4 obstacle zone, 5 above floor elsewhere
    with np.errstate(divide="ignore", invalid="ignore"):
        z_floor = np.where(f.rays[..., 1] < -1e-3, (f.floor_y - f.origin[1]) / f.rays[..., 1], np.inf)
        inv = (f.depth - b) / a
        valid = inv > 0.125
        z = np.where(valid, 1 / np.where(valid, inv, 1), np.nan)
    rel = np.nan_to_num(z)[..., None] * f.rays
    ahead, lateral = rel @ f.fwd, rel @ f.right
    h = f.origin[1] + rel[..., 1] - f.floor_y
    cand = (z_floor >= FLOOR_MIN) & (z_floor <= FLOOR_MAX)
    with np.errstate(divide="ignore", invalid="ignore"):
        w_true = 1 / z_floor
    floor_ok = cand & (np.abs(inv - w_true) <= TOL * w_true)
    labels[floor_ok] = 1
    above = valid & (h >= MIN_H) & (h <= MAX_H)
    labels[above & ~floor_ok] = 5
    corridor = above & (ahead >= MIN_FWD) & (ahead <= ALERT) & (np.abs(lateral) <= SIDE)
    zone = np.where(np.abs(lateral) <= CENTRE, 1, np.where(lateral < 0, 0, 2))
    labels[corridor] = 2 + zone[corridor]

    pixel_area = (f.su / f.fx) * (f.sv / f.fy)
    zones = []
    for zi in range(3):
        m = corridor & (zone == zi)
        area = float((np.nan_to_num(z[m]) ** 2).sum() * pixel_area)
        if area < MIN_AREA or not m.any():
            zones.append(None)
            continue
        fw = np.sort(ahead[m])
        dist = fw[len(fw) // 10]
        hh = np.sort(h[m][ahead[m] <= dist + 0.3])
        top = hh[min(len(hh) - 1, len(hh) * 9 // 10)] if len(hh) else 0
        zones.append((float(dist), bool(top < LOW_H)))

    err = None
    if f.features is not None:
        ft = f.features
        inv_f = (ft["d"] - b) / a
        with np.errstate(divide="ignore", invalid="ignore"):
            err = float(np.median(np.abs(np.where(inv_f > 0, 1 / inv_f, 99) / ft["Z"] - 1)))
    pts = {"ahead": ahead[valid], "lateral": lateral[valid], "h": h[valid]}
    return labels, pts, zones, err


def zones_text(zones):
    out = []
    for name, z in zip(("sx", "davanti", "dx"), zones):
        out.append(f"{name} -" if z is None else f"{name} {z[0]:.2f}{' basso' if z[1] else ''}")
    return "  ".join(out)


def portrait(img):
    return img.transpose(Image.Transpose.ROTATE_270)  # sensor landscape → phone portrait


def panel_row(f, a, b, label):
    labels, pts, zones, err = classify(f, a, b)
    over = np.array(f.photo).astype(np.float32)
    colours = {1: (0, 220, 0), 2: ZONE_COLOURS[0], 3: ZONE_COLOURS[1], 4: ZONE_COLOURS[2], 5: (60, 120, 255)}
    for lab, col in colours.items():
        m = labels == lab
        over[m] = over[m] * 0.45 + np.array(col) * 0.55
    if f.features is not None:
        for i, j in zip(f.features["i"], f.features["j"]):
            over[max(0, j - 1):j + 2, max(0, i - 1):i + 2] = 255
    p1 = portrait(Image.fromarray(over.astype(np.uint8)))
    d = f.depth - f.depth.min()
    p2 = portrait(Image.fromarray((255 * d / max(d.max(), 1e-6)).astype(np.uint8)).convert("RGB"))

    size = p1.size[1]
    top = Image.new("RGB", (size, size), (20, 20, 20))
    dr = ImageDraw.Draw(top)
    scale = size / 3.2
    ox, oy = size / 2, size - 20
    for mm in np.arange(0.5, 3.01, 0.5):
        y = oy - mm * scale
        dr.line([(0, y), (size, y)], fill=(70, 70, 70) if mm != ALERT else (200, 200, 0))
        dr.text((4, y - 12), f"{mm:.1f} m", fill=(200, 200, 200))
    for lat in (-SIDE, -CENTRE, CENTRE, SIDE):
        x = ox + lat * scale
        dr.line([(x, oy), (x, oy - ALERT * scale)], fill=(110, 110, 110))
    for k in range(0, pts["ahead"].size, 3):
        fw, lat, hh = pts["ahead"][k], pts["lateral"][k], pts["h"][k]
        if not (-1.6 < lat < 1.6 and -0.2 < fw < 3.2):
            continue
        col = (0, 160, 0) if hh < MIN_H else (255, 220, 0) if hh < LOW_H else (255, 60, 60)
        dr.point((ox + lat * scale, oy - fw * scale), fill=col)
    if f.features is not None:
        rel = f.features["world"] - f.origin
        for fw, lat in zip(rel @ f.fwd, rel @ f.right):
            if -1.6 < lat < 1.6 and -0.2 < fw < 3.2:
                x, y = ox + lat * scale, oy - fw * scale
                dr.ellipse([x - 2, y - 2, x + 2, y + 2], fill=(0, 230, 255))
    dr.polygon([(ox, oy + 6), (ox - 7, oy + 18), (ox + 7, oy + 18)], fill=(255, 255, 255))

    e = "–" if err is None else f"{100 * err:.0f}%"
    phone = [None if z is None else (z["distance"], z["low"]) for z in f.meta["zones"]]
    walls = "".join(w for w, on in zip("LR", f.meta.get("walls", [])) if on) or "-"
    caption = (f"{label}: feat err {e} | PHONE SAID {zones_text(phone)} | walls {walls}"
               f"{' | walking' if f.meta.get('walkDirection') else ''}")
    row = Image.new("RGB", (p1.size[0] + p2.size[0] + size, p1.size[1] + 18), (0, 0, 0))
    row.paste(p1, (0, 18))
    row.paste(p2, (p1.size[0], 18))
    row.paste(top, (p1.size[0] + p2.size[0], 18))
    ImageDraw.Draw(row).text((4, 3), caption, fill=(255, 255, 255))
    return row, zones, err


def main():
    rec = Path(sys.argv[1])
    every = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    out = rec / "overlay"
    out.mkdir(exist_ok=True)
    names = sorted(p.stem for p in rec.glob("*.json"))[::every]
    print("frame | pitch | n feat | phone: err, zones | features: inliers, err, zones")
    for n in names:
        f = Frame(rec, n)
        m = f.meta
        rows = []
        line = f"{n} | {f.pitch:.0f}° | {0 if f.features is None else len(f.features['Z'])} | "
        if m["scaleOk"] and m["scaleA"] > 0:
            r, zones, err = panel_row(f, m["scaleA"], m["scaleB"], "phone (floor fit)")
            rows.append(r)
            line += f"{'–' if err is None else f'{100 * err:.0f}%'} {zones_text(zones)} | "
        else:
            line += "no scale | "
        fit = fit_features(f)
        if fit:
            r, zones, err = panel_row(f, fit[0], fit[1], f"features ({fit[2]}/{fit[3]} inliers)")
            rows.append(r)
            line += f"{fit[2]}/{fit[3]} {'–' if err is None else f'{100 * err:.0f}%'} {zones_text(zones)}"
        else:
            line += "no fit"
        print(line)
        if rows:
            w = max(r.size[0] for r in rows)
            img = Image.new("RGB", (w, sum(r.size[1] for r in rows)), (0, 0, 0))
            y = 0
            for r in rows:
                img.paste(r, (0, y))
                y += r.size[1]
            ImageDraw.Draw(img).text((w - 160, 3), f"{n}  pitch {f.pitch:.0f}°", fill=(255, 255, 0))
            img.save(out / f"{n}.png")


if __name__ == "__main__":
    main()
