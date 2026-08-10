import subprocess, json, base64, re

r = subprocess.run(["/Applications/CuaDriver.app/Contents/MacOS/cua-driver", "call", "get_desktop_state", "{}"],
                  capture_output=True, text=True, timeout=30)
data = json.loads(r.stdout)
png_b64 = data.get("screenshot_png_b64")
screen_w = data.get("screen_width")
screen_h = data.get("screen_height")
scale = data.get("scale_factor")
print(f"screen: {screen_w}x{screen_h} (scale={scale})")
png_bytes = base64.b64decode(png_b64)
with open("/tmp/desktop.png", "wb") as f:
    f.write(png_bytes)
print(f"saved /tmp/desktop.png ({len(png_bytes)} bytes)")

# Find Fungi popover bounds via Swift CGWindowListCopyWindowInfo
swift = '''
import Cocoa
import CoreGraphics
let options: CGWindowListOption = [.optionAll]
let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
for info in windowList {
    let ownerName = info[kCGWindowOwnerName as String] as? String ?? "?"
    let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    if ownerName.lowercased().contains("fungi"),
       let x = bounds["X"], let y = bounds["Y"],
       let w = bounds["Width"], let h = bounds["Height"], h > 100 {
        print("FOUND:\\(Int(x)),\\(Int(y)),\\(Int(w)),\\(Int(h))")
    }
}
'''
with open("/tmp/find_fungi.swift", "w") as f:
    f.write(swift)
r = subprocess.run(["swift", "/tmp/find_fungi.swift"], capture_output=True, text=True, timeout=10)

x, y, w, h = 1284, 26, 566, 686  # default
for line in r.stdout.splitlines():
    if line.startswith("FOUND:"):
        parts = line.replace("FOUND:", "").split(",")
        x, y, w, h = int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])
        print(f"Fungi popover at: ({x},{y}) {w}x{h}")
        break
else:
    print(f"No Fungi popover found, using default ({x},{y}) {w}x{h}")

from PIL import Image
img = Image.open("/tmp/desktop.png")
print(f"PIL image: {img.size}, mode={img.mode}")
popover = img.crop((x, y, x+w, y+h))
popover.save("/tmp/fungi-popover.png")
print(f"saved /tmp/fungi-popover.png ({popover.size})")
