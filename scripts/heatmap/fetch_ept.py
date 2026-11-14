"""Download every USGS EPT node that overlaps a Web Mercator bbox and keep the points inside it."""
import gzip, json, math, os, sys, urllib.request
import numpy as np
import laspy

BASE = "https://s3-us-west-2.amazonaws.com/usgs-lidar-public/CO_DRCOG_2_2020"
course_path, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)

# Hole 1's green, decoded from CourseDataSwift's delta-encoded CoordinatePath (1/365,000 degree units).
course = json.load(gzip.open(course_path, "rt"))
green = next(f for f in course["features"] if f["id"] == 16)["polygon"]["values"]
pts, cur = [], [0, 0]
for i in range(0, len(green), 3):
    cur = [cur[0] + green[i], cur[1] + green[i + 1]]
    pts.append((cur[0] / 365000, cur[1] / 365000))
R = 6378137.0
def merc(lat, lon):
    return R * math.radians(lon), R * math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
xy = [merc(p[0], p[1]) for p in pts]
pad = 12.0  # meters (Mercator meters; ~9 m on the ground at this latitude)
bx0 = min(x for x, _ in xy) - pad; bx1 = max(x for x, _ in xy) + pad
by0 = min(y for _, y in xy) - pad; by1 = max(y for _, y in xy) + pad

def get(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()

ept = json.loads(get(BASE + "/ept.json"))
b = ept["bounds"]

def node_bounds(d, x, y, z):
    size = (b[3] - b[0]) / 2 ** d
    return b[0] + x * size, b[1] + y * size, b[0] + (x + 1) * size, b[1] + (y + 1) * size

def overlaps(d, x, y, z):
    x0, y0, x1, y1 = node_bounds(d, x, y, z)
    return x0 <= bx1 and x1 >= bx0 and y0 <= by1 and y1 >= by0

hier_cache = {}
def hierarchy(key):
    if key not in hier_cache:
        hier_cache[key] = json.loads(get(f"{BASE}/ept-hierarchy/{key}.json"))
    return hier_cache[key]

nodes = []
def walk(d, x, y, z, hkey):
    key = f"{d}-{x}-{y}-{z}"
    h = hierarchy(hkey)
    if key not in h:
        return
    if h[key] == -1:
        hkey = key
        h = hierarchy(key)
    nodes.append(key)
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                c = (d + 1, 2 * x + dx, 2 * y + dy, 2 * z + dz)
                if overlaps(*c):
                    walk(*c, hkey)

walk(0, 0, 0, 0, "0-0-0-0")
print(f"{len(nodes)} nodes overlap the green", file=sys.stderr)

chunks = []
for key in nodes:
    path = os.path.join(out_dir, key + ".laz")
    if not os.path.exists(path):
        open(path, "wb").write(get(f"{BASE}/ept-data/{key}.laz"))
    las = laspy.read(path)
    m = (las.x >= bx0) & (las.x <= bx1) & (las.y >= by0) & (las.y <= by1)
    if m.any():
        chunks.append(np.column_stack([las.x[m], las.y[m], las.z[m], las.classification[m]]))
    print(key, int(m.sum()), file=sys.stderr)

allp = np.vstack(chunks)
np.save(os.path.join(out_dir, "points.npy"), allp)
print(f"saved {len(allp)} points; classes {np.unique(allp[:, 3], return_counts=True)}", file=sys.stderr)
