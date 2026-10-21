## Lane LENS-1: the pro camera's lens (NOT RETAIL: an OpenBFME addition; the original game's camera has a field of
## view and nothing else). docs/PRO_CAMERA.md has the model; pro_camera.gd uses it, pro_lens_effect.gd draws it.
##
## A full-frame camera: a 36 x 24 mm sensor. A picture of aspect 3:2 or wider is 36 mm wide on it, a narrower one 24 mm
## tall, as a camera's crop modes take the largest frame of their aspect (sensor). A focal length f gives a picture w mm
## wide a horizontal field of view of 2 atan(w / 2f): 39 mm frames 50 degrees on the full width. Depth of field is the
## thin lens: a point at distance D, focused at S with aperture f/N, blurs to a circle of (f / N) * f / (S - f) * |D -
## S| / D mm on the sensor. Distances need a scale: `units_per_metre` world units to the metre (UNITS_PER_METRE, 10,
## makes a soldier about 20 units tall the 2 m he would be), so wide apertures blur as a real lens would at that size.
## Static functions only: load this script and call them.
extends RefCounted

const SENSOR := Vector2(36.0, 24.0)       # mm, full frame
const UNITS_PER_METRE := 10.0             # world units to the metre (OpenBFME's maps: a soldier ~20 units tall)
# the effect's default cap on a blur circle's diameter, as a share of the image width
const MAX_BLUR := 0.06
# the blur counted as sharp, as a share of the frame's diagonal (0.029 mm on full frame)
const SHARP := 1.0 / 1500.0


## The largest frame of `aspect` (width / height) on the sensor, in mm.
static func sensor(aspect: float) -> Vector2:
	if aspect >= SENSOR.x / SENSOR.y:
		return Vector2(SENSOR.x, SENSOR.x / aspect)
	return Vector2(SENSOR.y * aspect, SENSOR.y)


## An image of `aspect` holding a centred frame of aspect `frame` (0: the image is the frame), in mm on the sensor's
## scale: the frame keeps its crop of the sensor and the image shows more around it.
static func image_size(aspect: float, frame: float = 0.0) -> Vector2:
	if frame <= 0.0:
		return sensor(aspect)
	var f := sensor(frame)
	return Vector2(f.x, f.x / aspect) if aspect <= frame else Vector2(f.y * aspect, f.y)


## The horizontal field of view (degrees) of focal length `focal` mm over an image `width` mm wide.
static func fov_from_focal(focal: float, width: float = SENSOR.x) -> float:
	return 2.0 * rad_to_deg(atan(width / 2.0 / focal))


## The focal length (mm) that gives a horizontal field of view of `fov` degrees over an image `width` mm wide.
static func focal_from_fov(fov: float, width: float = SENSOR.x) -> float:
	return width / 2.0 / tan(deg_to_rad(fov) / 2.0)


## The blur circle's diameter in pixels of a point `distance` world units away along the view, for a lens of `focal` mm
## at f/`aperture` focused at `focus` world units, on an image `image_mm` wide drawn `image_pixels` wide. Uncapped (the
## effect caps it at its `max_blur` of the width); 0 without an aperture.
static func blur_pixels(distance: float, focus: float, focal: float, aperture: float,
		image_mm: float, image_pixels: float, units_per_metre: float = UNITS_PER_METRE) -> float:
	if aperture <= 0.0:
		return 0.0
	var mm := 1000.0 / units_per_metre
	var d := maxf(distance * mm, 1e-3)
	var s := maxf(focus * mm, focal * 1.001)
	return (focal / aperture) * focal / (s - focal) * absf(d - s) / d * image_pixels / image_mm


## (near, far) world units between which the blur stays under SHARP of the diagonal of a frame of `aspect`; far is INF
## at and beyond the hyperfocal distance. (0, INF) without an aperture.
static func sharp_range(focus: float, focal: float, aperture: float, aspect: float,
		units_per_metre: float = UNITS_PER_METRE) -> Vector2:
	if aperture <= 0.0:
		return Vector2(0.0, INF)
	var mm := 1000.0 / units_per_metre
	var c := sensor(aspect).length() * SHARP
	var s := maxf(focus * mm, focal * 1.001)
	var hyperfocal := focal * focal / (aperture * c) + focal
	var near := s * (hyperfocal - focal) / (hyperfocal + s - 2.0 * focal)
	var far := s * (hyperfocal - focal) / (hyperfocal - s) if s < hyperfocal else INF
	return Vector2(near, far) / mm


## The frame of aspect `ratio` centred in an image `size` pixels (the whole image for 0), in pixels: where a framed
## picture lies inside the window.
static func frame_rect(size: Vector2i, ratio: float) -> Rect2i:
	if ratio <= 0.0:
		return Rect2i(Vector2i.ZERO, size)
	if float(size.x) / size.y > ratio:
		var fw := roundi(size.y * ratio)
		return Rect2i((size.x - fw) / 2, 0, fw, size.y)
	var fh := roundi(size.x / ratio)
	return Rect2i(0, (size.y - fh) / 2, size.x, fh)
