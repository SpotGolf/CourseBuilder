"""Render an elevation + slope heat map of Broadlands hole 1's green from USGS 3DEP LiDAR ground returns."""
import gzip, json, sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.path import Path
from matplotlib.colors import LinearSegmentedColormap, BoundaryNorm, ListedColormap
from matplotlib.patches import Polygon as MplPolygon, FancyArrowPatch
from pyproj import Transformer
from scipy.interpolate import RBFInterpolator

course_path, points_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
SMOOTHING = float(sys.argv[4]) if len(sys.argv) > 4 else 60.0
M2IN = 39.3701

# --- course geometry -------------------------------------------------------
course = json.load(gzip.open(course_path, "rt"))
features = {f["id"]: f for f in course["features"]}
hole = course["subCourses"][0]["holes"][0]

def decode(values):
    out, cur = [], [0, 0, 0]
    for i in range(0, len(values), 3):
        cur = [cur[j] + (values[i + j] or 0) for j in range(3)]
        out.append((cur[0] / 365000, cur[1] / 365000, cur[2] * 0.3048))
    return np.array(out)

to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32613", always_xy=True)
def utm(lat_lon):
    e, n = to_utm.transform(lat_lon[:, 1], lat_lon[:, 0])
    return np.column_stack([e, n])

green_ll = decode(features[16]["polygon"]["values"])
green = utm(green_ll)
origin = green.mean(axis=0)
green -= origin

def polygon_area(p):
    x, y = p[:, 0], p[:, 1]
    return abs(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1))) / 2
others = {fid: utm(decode(features[fid]["polygon"]["values"])) - origin
          for fid in hole["features"] if fid != 16}
centerline = utm(decode(features[hole["centerline"]]["polygon"]["values"])) - origin

# --- LiDAR ground points ---------------------------------------------------
pts = np.load(points_path)
ground = pts[pts[:, 3] == 2]
merc_to_utm = Transformer.from_crs("EPSG:3857", "EPSG:32613", always_xy=True)
ge, gn = merc_to_utm.transform(ground[:, 0], ground[:, 1])
gxy = np.column_stack([ge, gn]) - origin
gz = ground[:, 2]

# keep returns within 12 m of the green so the fit is stable at its edge
gpath = Path(green)
near = gpath.contains_points(gxy, radius=12.0) | gpath.contains_points(gxy, radius=-12.0)
gxy, gz = gxy[near], gz[near]
inside = gpath.contains_points(gxy)
print(f"{len(gz)} ground returns near green, {inside.sum()} on the putting surface "
      f"({inside.sum() / polygon_area(green):.2f}/m²)", file=sys.stderr)

rbf = RBFInterpolator(gxy, gz, kernel="thin_plate_spline", smoothing=SMOOTHING)
resid = gz - rbf(gxy)
print(f"fit residual RMS {np.sqrt(np.mean(resid ** 2)) * 100:.1f} cm", file=sys.stderr)

# --- grid --------------------------------------------------------------------
STEP = 0.1
pad = 2.0
xs = np.arange(green[:, 0].min() - pad, green[:, 0].max() + pad, STEP)
ys = np.arange(green[:, 1].min() - pad, green[:, 1].max() + pad, STEP)
X, Y = np.meshgrid(xs, ys)
Z = rbf(np.column_stack([X.ravel(), Y.ravel()])).reshape(X.shape)
mask = gpath.contains_points(np.column_stack([X.ravel(), Y.ravel()])).reshape(X.shape)

dzdy, dzdx = np.gradient(Z, STEP)
slope_pct = np.hypot(dzdx, dzdy) * 100

zg = np.where(mask, Z, np.nan)
low = np.nanmin(zg)
rel_in = (zg - low) * M2IN
sl = np.where(mask, slope_pct, np.nan)
print(f"relief {np.nanmax(rel_in):.1f} in, slope mean {np.nanmean(sl):.2f}% max {np.nanmax(sl):.2f}%", file=sys.stderr)

# Compare the CourseBuilder perimeter elevations against the LiDAR surface.
perim_lidar = rbf(green)
print(f"JSON perimeter vs LiDAR: mean diff {np.mean(green_ll[:, 2] - perim_lidar) * 100:.1f} cm, "
      f"JSON range {green_ll[:, 2].min() / 0.3048:.0f}-{green_ll[:, 2].max() / 0.3048:.0f} ft", file=sys.stderr)

# --- styling -----------------------------------------------------------------
SURFACE = "#fcfcfb"; INK = "#0b0b0b"; INK2 = "#52514e"; GRID = "#d9d8d3"
blue = LinearSegmentedColormap.from_list("seq_blue", [
    "#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"])
slope_bounds = [0, 1, 2, 3, 4, 5]
slope_cmap = ListedColormap(["#fde7dc", "#f7b392", "#eb6834", "#b8461b", "#7a2a0c"])
slope_norm = BoundaryNorm(slope_bounds, slope_cmap.N)

plt.rcParams.update({"font.family": "DejaVu Sans", "text.color": INK, "axes.labelcolor": INK2,
                     "xtick.color": INK2, "ytick.color": INK2, "axes.edgecolor": GRID})
fig, axes = plt.subplots(1, 2, figsize=(15, 8.4), facecolor=SURFACE)
extent = [xs[0], xs[-1], ys[0], ys[-1]]
view = [green[:, 0].min() - 9, green[:, 0].max() + 9, green[:, 1].min() - 9, green[:, 1].max() + 9]

def context(ax):
    ax.set_facecolor(SURFACE)
    for fid, poly in others.items():
        kind = features[fid]["type"]
        if kind == "bunker":
            ax.add_patch(MplPolygon(poly, closed=True, facecolor="#efe6cf", edgecolor="#b9a878", lw=1, zorder=1))
            c = poly.mean(axis=0)
            if view[0] < c[0] < view[1] and view[2] < c[1] < view[3]:
                ax.text(c[0], c[1], "bunker", ha="center", va="center", fontsize=8, color=INK2, zorder=2)
        elif kind == "fairway":
            ax.add_patch(MplPolygon(poly, closed=True, facecolor="#eef3ea", edgecolor="#c9d6c0", lw=1, zorder=0))
    ax.add_patch(MplPolygon(green, closed=True, fill=False, edgecolor=INK, lw=1.5, zorder=6))
    # approach direction from the hole's centerline
    a, b = centerline[-2], centerline[-1]
    d = (b - a) / np.linalg.norm(b - a)
    entry = green[np.argmin(green @ d)]
    start = entry - d * 7.5
    ax.add_patch(FancyArrowPatch(start, entry - d * 1.0, arrowstyle="-|>", mutation_scale=14,
                                 color=INK2, lw=1.5, zorder=7))
    ax.text(start[0], start[1] + 1.0, "approach", ha="center", va="bottom", fontsize=9, color=INK2, zorder=7)
    # scale bar + north arrow
    sx, sy = view[0] + 1.5, view[2] + 1.5
    ax.plot([sx, sx + 5], [sy, sy], color=INK, lw=2, solid_capstyle="butt", zorder=7)
    ax.text(sx + 2.5, sy + 0.6, "5 m (16 ft)", ha="center", va="bottom", fontsize=8, color=INK2)
    nx, ny = view[1] - 2, view[3] - 4.5
    ax.add_patch(FancyArrowPatch((nx, ny), (nx, ny + 3), arrowstyle="-|>", mutation_scale=12, color=INK, lw=1.5))
    ax.text(nx, ny + 3.6, "N", ha="center", va="bottom", fontsize=10, fontweight="bold")
    ax.set_xlim(view[0], view[1]); ax.set_ylim(view[2], view[3])
    ax.set_aspect("equal")
    ax.set_xticks([]); ax.set_yticks([])
    for s in ax.spines.values():
        s.set_visible(False)

# Panel 1: elevation
ax = axes[0]
context(ax)
vmax = np.ceil(np.nanmax(rel_in))
im = ax.imshow(rel_in, origin="lower", extent=extent, cmap=blue, vmin=0, vmax=vmax, zorder=3, interpolation="bilinear")
levels = np.arange(0, vmax + 0.01, 1.0)
cs = ax.contour(X, Y, rel_in, levels=levels, colors=[SURFACE], linewidths=0.6, alpha=0.9, zorder=4)
major = levels[levels % 3 == 0]
cs3 = ax.contour(X, Y, rel_in, levels=major, colors=["#1f1f1e"], linewidths=0.8, zorder=4)
ax.clabel(cs3, fmt=lambda v: f'{v:.0f}"', fontsize=8.5, colors=INK, inline_spacing=4)
# fall-line arrows (downhill), length scaled by slope
AS = 2.0
inner = gpath.contains_points(np.column_stack([X.ravel(), Y.ravel()]), radius=-1.6).reshape(X.shape) & mask
ii = np.arange(0, len(ys), int(AS / STEP)); jj = np.arange(0, len(xs), int(AS / STEP))
J, I = np.meshgrid(jj, ii)
keep = inner[I, J]
I, J = I[keep], J[keep]
u, v = -dzdx[I, J], -dzdy[I, J]
ax.quiver(X[I, J], Y[I, J], u, v, color=INK, angles="xy", scale_units="xy", scale=1 / 40, width=0.003,
          headwidth=3.6, headlength=4, headaxislength=3.6, pivot="middle", alpha=0.8, zorder=5)
ax.set_title("Elevation above the green's low point", loc="left", fontsize=13, pad=10)
cb = fig.colorbar(im, ax=ax, fraction=0.04, pad=0.02, ticks=levels[::3])
cb.set_label("inches above low point", color=INK2)
cb.outline.set_visible(False)
ax.text(0.0, -0.035, 'White lines every 1", dark lines every 3". Arrows point downhill (fall line); longer = steeper.',
        transform=ax.transAxes, fontsize=8.5, color=INK2, va="top")

# Panel 2: slope
ax = axes[1]
context(ax)
im2 = ax.imshow(np.clip(sl, 0, 4.999), origin="lower", extent=extent, cmap=slope_cmap, norm=slope_norm, zorder=3, interpolation="nearest")
ax.set_title("Slope (steepness)", loc="left", fontsize=13, pad=10)
cb2 = fig.colorbar(im2, ax=ax, fraction=0.04, pad=0.02, ticks=[0.5, 1.5, 2.5, 3.5, 4.5])
cb2.ax.set_yticklabels(["<1%", "1–2%", "2–3%", "3–4%", "4%+"])
cb2.ax.tick_params(length=0)
cb2.set_label("percent grade", color=INK2)
cb2.outline.set_visible(False)
frac = [np.mean((sl[mask] >= a) & (sl[mask] < b)) * 100 for a, b in zip(slope_bounds[:-1], slope_bounds[1:-1] + [np.inf])]
ax.text(0.0, -0.035, "Share of surface:  " + "   ".join(
    f"{lab} {f:.0f}%" for lab, f in zip(["<1%", "1–2%", "2–3%", "3–4%", "4%+"], frac)),
    transform=ax.transAxes, fontsize=8.5, color=INK2, va="top")

area_m2 = polygon_area(green)
fig.suptitle("Broadlands Golf Course — Hole 1 green", x=0.035, y=0.985, ha="left", fontsize=17, fontweight="bold")
fig.text(0.035, 0.925,
         f"Putting surface {area_m2:.0f} m² ({area_m2 * 10.7639:,.0f} ft²)  ·  total relief {np.nanmax(rel_in):.1f}\"  ·  "
         f"mean slope {np.nanmean(sl):.1f}%  ·  low point {low / 0.3048:,.1f} ft (NAVD88)",
         fontsize=10.5, color=INK2)
fig.text(0.035, 0.018,
         f"Green outline: SpotGolf CourseData (OSM w1258997504). Elevation: USGS 3DEP lidar, CO_DRCOG_2_2020 (QL2), "
         f"{inside.sum()} ground returns on the green, thin-plate-spline surface (fit RMS {np.sqrt(np.mean(resid ** 2)) * 100:.1f} cm). "
         "Survey predates any later green renovation.",
         fontsize=7.5, color=INK2)
fig.subplots_adjust(left=0.03, right=0.97, top=0.88, bottom=0.08, wspace=0.08)
fig.savefig(out_path, dpi=170, facecolor=SURFACE)
print("wrote", out_path, file=sys.stderr)
