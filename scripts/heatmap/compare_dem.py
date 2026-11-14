"""Compare the 3DEP ImageServer (what CourseBuilder calls) against the lidar surface on a 1 m grid over the green."""
import gzip, json, sys, time, urllib.parse, urllib.request
import numpy as np
from matplotlib.path import Path
from pyproj import Transformer
from scipy.interpolate import RBFInterpolator

course_path, points_path = sys.argv[1], sys.argv[2]
course = json.load(gzip.open(course_path, "rt"))
vals = next(f for f in course["features"] if f["id"] == 16)["polygon"]["values"]
ll, cur = [], [0, 0]
for i in range(0, len(vals), 3):
    cur = [cur[0] + vals[i], cur[1] + vals[i + 1]]
    ll.append((cur[0] / 365000, cur[1] / 365000))
ll = np.array(ll)

to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32613", always_xy=True)
to_ll = Transformer.from_crs("EPSG:32613", "EPSG:4326", always_xy=True)
e, n = to_utm.transform(ll[:, 1], ll[:, 0])
green = np.column_stack([e, n])
gpath = Path(green)

xs = np.arange(np.floor(e.min()), np.ceil(e.max()) + 1, 1.0)
ys = np.arange(np.floor(n.min()), np.ceil(n.max()) + 1, 1.0)
X, Y = np.meshgrid(xs, ys)
grid = np.column_stack([X.ravel(), Y.ravel()])
inside = gpath.contains_points(grid)
pts = grid[inside]
print(f"{len(pts)} grid points at 1 m inside the green", file=sys.stderr)

# lidar surface, same fit as heatmap.py
p = np.load(points_path)
g = p[p[:, 3] == 2]
ge, gn = Transformer.from_crs("EPSG:3857", "EPSG:32613", always_xy=True).transform(g[:, 0], g[:, 1])
gxy = np.column_stack([ge, gn])
near = gpath.contains_points(gxy, radius=12.0) | gpath.contains_points(gxy, radius=-12.0)
rbf = RBFInterpolator(gxy[near], g[near, 2], kernel="thin_plate_spline", smoothing=60.0)
lidar = rbf(pts)

# 3DEP getSamples, as USGSElevationClient does it
lon, lat = to_ll.transform(pts[:, 0], pts[:, 1])
dem = np.full(len(pts), np.nan)
URL = "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/getSamples"
for s in range(0, len(pts), 200):
    geom = {"points": [[a, b] for a, b in zip(lon[s:s + 200], lat[s:s + 200])], "spatialReference": {"wkid": 4326}}
    body = urllib.parse.urlencode({"geometry": json.dumps(geom), "geometryType": "esriGeometryMultipoint",
                                   "returnFirstValueOnly": "true", "f": "json"}).encode()
    for attempt in range(5):
        try:
            r = json.loads(urllib.request.urlopen(urllib.request.Request(URL, data=body), timeout=90).read())
            break
        except Exception as ex:
            print("retry", ex, file=sys.stderr); time.sleep(2 * (attempt + 1))
    for sm in r["samples"]:
        dem[s + sm["locationId"]] = float(sm["value"])

d = dem - lidar
d0 = d - np.nanmean(d)
print(f"3DEP minus lidar: mean offset {np.nanmean(d) * 100:.1f} cm, after removing offset RMS {np.sqrt(np.nanmean(d0 ** 2)) * 100:.1f} cm, "
      f"max {np.nanmax(np.abs(d0)) * 100:.1f} cm", file=sys.stderr)
print(f"relief: lidar {(lidar.max() - lidar.min()) * 39.37:.1f} in, 3DEP {(np.nanmax(dem) - np.nanmin(dem)) * 39.37:.1f} in", file=sys.stderr)

# slopes from each on the 1 m grid
def slopes(vals):
    Z = np.full(X.shape, np.nan); Z.ravel()[np.flatnonzero(inside)] = vals
    gy, gx = np.gradient(Z, 1.0)
    return np.hypot(gx, gy).ravel()[inside] * 100
sl, sd = slopes(lidar), slopes(dem)
ok = ~np.isnan(sl) & ~np.isnan(sd)
print(f"slope %: lidar mean {sl[ok].mean():.2f}, 3DEP mean {sd[ok].mean():.2f}, RMS diff {np.sqrt(np.mean((sl[ok] - sd[ok]) ** 2)):.2f} pts", file=sys.stderr)
