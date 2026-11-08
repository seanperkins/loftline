import Foundation
import LoftLineKit

/// The JavaScript side of the gadget API: a friendly `loftline` object over the native functions
/// in `__loftlineNative` (see `GadgetHost`). Written for LoftLine.
enum GadgetAPI {
    static let prelude = #"""
    var loftline = (function (n) {
      "use strict";
      function num(v, what) {
        if (typeof v !== "number" || !isFinite(v)) throw new Error(what + " must be a number");
        return v;
      }
      function pt(p, what) {
        if (Array.isArray(p) && p.length >= 2) return [num(p[0], what), num(p[1], what)];
        if (p && typeof p === "object" && "x" in p && "y" in p) return [num(p.x, what), num(p.y, what)];
        throw new Error(what + " must be [x, y] or {x, y}");
      }
      function idList(v) {
        if (v === undefined || v === null) return [];
        if (typeof v === "string") return [v];
        if (Array.isArray(v)) return v.map(function (s) { return typeof s === "object" && s ? s.id : s; });
        if (typeof v === "object" && v.id) return [v.id];
        throw new Error("expected a shape id, a shape, or a list of them");
      }

      function PathBuilder() { this.start = null; this.segments = []; this.closed = false; }
      PathBuilder.prototype.moveTo = function (x, y) {
        if (this.start) throw new Error("moveTo starts a path; use a new loftline.path() for the next one");
        this.start = [num(x, "x"), num(y, "y")]; return this;
      };
      PathBuilder.prototype._need = function () { if (!this.start) throw new Error("call moveTo first"); };
      PathBuilder.prototype.lineTo = function (x, y) {
        this._need(); this.segments.push({ line: [num(x, "x"), num(y, "y")] }); return this;
      };
      PathBuilder.prototype.arcTo = function (x, y, cx, cy, clockwise) {
        this._need();
        this.segments.push({ arc: [num(x, "x"), num(y, "y")], center: [num(cx, "cx"), num(cy, "cy")], clockwise: !!clockwise });
        return this;
      };
      PathBuilder.prototype.curveTo = function (c1x, c1y, c2x, c2y, x, y) {
        this._need();
        this.segments.push({ cubic: [num(x, "x"), num(y, "y")], c1: [num(c1x, "c1x"), num(c1y, "c1y")], c2: [num(c2x, "c2x"), num(c2y, "c2y")] });
        return this;
      };
      PathBuilder.prototype.close = function () { this.closed = true; return this; };
      PathBuilder.prototype.spec = function () {
        this._need();
        return { start: this.start, segments: this.segments, closed: this.closed };
      };

      function spec(p) {
        if (p instanceof PathBuilder) return p.spec();
        if (Array.isArray(p)) {  // a bare point list
          var pts = p.map(function (q) { return pt(q, "point"); });
          return { start: pts[0], segments: pts.slice(1).map(function (q) { return { line: q }; }), closed: false };
        }
        return p;
      }

      function regular(cx, cy, radii, count, rotationDeg) {
        var pts = [], n = radii.length * count, rot = (rotationDeg || 0) * Math.PI / 180;
        for (var i = 0; i < n; i++) {
          var a = rot + Math.PI / 2 + i * 2 * Math.PI / n, r = radii[i % radii.length];
          pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
        }
        return pts;
      }

      var api = {
        units: n.units,
        material: n.material,
        params: n.params,
        variables: n.variables,
        name: n.gadgetName,
        inch: n.units === "inch" ? 1 : 25.4,
        mm: n.units === "inch" ? 1 / 25.4 : 1,

        selection: function () { return n.shapes(true); },
        shapes: function () { return n.shapes(false); },
        layers: function () { return n.layers(); },
        tools: function () { return n.tools(); },

        log: function () { n.log(Array.prototype.map.call(arguments, String).join(" ")); },
        message: function (text) { n.message(String(text)); },

        path: function () { return new PathBuilder(); },
        addShape: function (paths, opts) {
          if (!Array.isArray(paths) || (paths.length && typeof paths[0][0] === "number")) paths = [paths];
          return n.addShape(paths.map(spec), opts || {});
        },
        polyline: function (points, opts) {
          opts = opts || {};
          var s = spec(points); s.closed = !!opts.closed;
          if (s.segments.length < 1) throw new Error("polyline needs at least two points");
          return n.addShape([s], opts);
        },
        rectangle: function (x, y, w, h, opts) {
          opts = opts || {};
          return n.primitive("rectangle", [x, y, w, h, opts.cornerRadius || 0], opts);
        },
        circle: function (cx, cy, r, opts) { return n.primitive("circle", [cx, cy, r], opts || {}); },
        ellipse: function (cx, cy, rx, ry, opts) { return n.primitive("ellipse", [cx, cy, rx, ry], opts || {}); },
        polygon: function (cx, cy, radius, sides, opts) {
          opts = opts || {};
          if (!(sides >= 3)) throw new Error("polygon needs at least 3 sides");
          var o = Object.assign({}, opts, { closed: true });
          return api.polyline(regular(cx, cy, [radius], Math.floor(sides), opts.rotation), o);
        },
        star: function (cx, cy, outer, inner, points, opts) {
          opts = opts || {};
          if (!(points >= 3)) throw new Error("star needs at least 3 points");
          var o = Object.assign({}, opts, { closed: true });
          return api.polyline(regular(cx, cy, [outer, inner], Math.floor(points), opts.rotation), o);
        },

        layer: function (name, color) { return n.layer(String(name), color); },
        deleteShapes: function (ids) { n.deleteShapes(idList(ids)); },
        transform: function (ids, m) { n.transform(idList(ids), m); },
        move: function (ids, dx, dy) { n.transform(idList(ids), [1, 0, 0, 1, num(dx, "dx"), num(dy, "dy")]); },
        rotate: function (ids, degrees, cx, cy) {
          var a = num(degrees, "degrees") * Math.PI / 180, c = Math.cos(a), s = Math.sin(a);
          cx = cx || 0; cy = cy || 0;
          n.transform(idList(ids), [c, s, -s, c, cx - c * cx + s * cy, cy - s * cx - c * cy]);
        },
        scale: function (ids, sx, sy, cx, cy) {
          if (sy === undefined) sy = sx;
          cx = cx || 0; cy = cy || 0;
          n.transform(idList(ids), [sx, 0, 0, sy, cx - sx * cx, cy - sy * cy]);
        },
        select: function (ids) { n.select(idList(ids)); },

        addToolpath: function (kind, ids, opts) { return n.addToolpath(String(kind), idList(ids), opts || {}); },
        setVariable: function (name, value) { n.setVariable(String(name), value); }
      };
      return Object.freeze(api);
    })(__loftlineNative);
    // One-release alias: gadgets written before the rename call kerf.*.
    var kerf = loftline;
    var console = { log: loftline.log, warn: loftline.log, error: loftline.log };
    """#

    /// Short API reference shown in Gadgets > Gadget API Reference and written to the
    /// gadgets folder.
    static let reference = """
    LOFTLINE GADGETS
    A gadget is a JavaScript file (.js) in the Gadgets folder. Gadgets > Open Gadgets Folder
    shows it; Gadgets > Reload Gadgets picks up new files. The whole run is one undo step, and
    if the script throws, nothing is changed.

    HEADER (leading // comments)
      // @name Hole Grid
      // @description Draws a grid of holes.
      // @needs-selection                       (optional: refuse to run with nothing selected)
      // @param rows integer 3 "Rows"
      // @param pitch length 1.5 "Spacing"      (length defaults are inches; scaled in mm jobs)
      // @param depth number 0.25 "Depth"
      // @param side choice outside|inside|on "Side"   (first option is the default)
      // @param label text "Hello" "Label"
      // @param drill bool true "Add a drilling toolpath"
    Values arrive as loftline.params.<name>, in document units.

    READ
      loftline.units                "inch" or "mm"
      loftline.inch, loftline.mm        one inch / one millimeter in document units
      loftline.material             { width, height, thickness, zZero: "top"|"spoilboard", safeZ }
      loftline.variables            document variables { name: value }
      loftline.selection()          selected shapes; loftline.shapes() every shape. Each is
                                { id, name, layer, layerId, kind, closed, bounds: { minX, minY,
                                  maxX, maxY, width, height, centerX, centerY },
                                  paths: [{ closed, length, points: [[x, y], ...] }], radius?, text? }
      loftline.layers()             [{ id, name, visible, locked, color }]
      loftline.tools()              [{ id, name, number, kind, diameter }]  (diameter in document units)

    DRAW (each returns the new shape id; opts: { layer: "Name", name: "Shape name" })
      loftline.rectangle(x, y, w, h, { cornerRadius })
      loftline.circle(cx, cy, r)            loftline.ellipse(cx, cy, rx, ry)
      loftline.polygon(cx, cy, r, sides, { rotation })
      loftline.star(cx, cy, outerR, innerR, points, { rotation })
      loftline.polyline([[x, y], ...], { closed: true })
      loftline.addShape([path, ...])        path = loftline.path().moveTo(x, y).lineTo(x, y)
                                        .arcTo(x, y, cx, cy, clockwise).curveTo(c1x, c1y, c2x, c2y, x, y)
                                        .close()   (several paths make one shape, e.g. a ring)
      loftline.layer(name, "#RRGGBB")       find or create a layer, returns its id

    EDIT
      loftline.move(ids, dx, dy)   loftline.rotate(ids, degrees, cx, cy)   loftline.scale(ids, sx, sy, cx, cy)
      loftline.transform(ids, [a, b, c, d, tx, ty])   loftline.deleteShapes(ids)   loftline.select(ids)
      loftline.setVariable(name, value)

    TOOLPATHS
      loftline.addToolpath(kind, ids, { name, tool, depth, side, enabled })
        kind: profile, pocket, drill, holeMill, engrave, chamfer, vcarve, prism, fluting,
              texture, moulding, straightInlay ...
        tool: a tool name (or part of one), number or id from the tool database
        depth: cut depth (profile, pocket, drill)   side: outside | inside | on (profile)

    OUTPUT
      loftline.log(...) / console.log(...)  shown after the run
      loftline.message(text)                shown after the run

    Gadgets run with no file, network or system access and are stopped after 10 seconds.
    """
}
