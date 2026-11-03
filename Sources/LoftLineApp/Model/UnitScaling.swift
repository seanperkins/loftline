import CADCore
import CAMCore
import Foundation

// Length scaling for parameter structs. Used to (a) rescale inch-based defaults for mm documents
// and (b) convert a whole project when the user switches document units in Job Setup.
// Angles, ratios, counts and seeds are never scaled.

extension DepthSettings {
    func scaled(by f: Double) -> DepthSettings {
        var d = self
        d.startDepth *= f; d.cutDepth *= f; d.passDepth = passDepth.map { $0 * f }; d.finalPassDepth *= f
        d.customPasses = customPasses.map { $0.map { $0 * f } }
        d.overcut = overcut.map { $0 * f }
        return d
    }
}

extension RampSettings {
    func scaled(by f: Double) -> RampSettings { var r = self; r.length *= f; return r }
}

extension TabSettings {
    func scaled(by f: Double) -> TabSettings {
        var t = self; t.length *= f; t.thickness *= f; t.spacing = t.spacing.map { $0 * f }; return t
    }
}

extension LeadSettings {
    func scaled(by f: Double) -> LeadSettings { var l = self; l.distance *= f; l.overcut *= f; return l }
}

extension ProfileParameters {
    func scaled(by f: Double) -> ProfileParameters {
        var p = self
        p.depth = depth.scaled(by: f); p.allowance *= f; p.tabs = tabs.scaled(by: f)
        p.ramp = ramp.scaled(by: f); p.lead = lead.scaled(by: f)
        p.lastPass?.allowance *= f
        return p
    }
}

extension PocketParameters {
    func scaled(by f: Double) -> PocketParameters {
        var p = self
        p.depth = depth.scaled(by: f); p.allowance *= f; p.ramp = ramp.scaled(by: f)
        return p
    }
}

extension DrillParameters {
    func scaled(by f: Double) -> DrillParameters {
        var p = self
        p.startDepth *= f; p.cutDepth *= f; p.peckDepth *= f; p.retractHeight *= f
        return p
    }
}

extension FlutingParameters {
    func scaled(by f: Double) -> FlutingParameters { var p = self; p.depth = depth.scaled(by: f); return p }
}

extension TextureParameters {
    func scaled(by f: Double) -> TextureParameters {
        var p = self
        p.maxDepth *= f; p.spacing *= f; p.minStrokeLength *= f; p.maxStrokeLength *= f
        return p
    }
}

extension VCarveParameters {
    func scaled(by f: Double) -> VCarveParameters {
        var p = self
        p.startDepth *= f; p.flatDepth = flatDepth.map { $0 * f }; p.passDepth = passDepth.map { $0 * f }
        p.openVectorDepth = openVectorDepth.map { $0 * f }
        return p
    }
}

extension InlayParameters {
    func scaled(by f: Double) -> InlayParameters {
        var p = self
        p.pocketDepth *= f; p.maleStartDepth *= f; p.glueGap *= f; p.maleBoundaryMargin *= f
        p.surfaceClearance = surfaceClearance.map { $0 * f }
        return p
    }
}

extension PhotoVCarveParameters {
    func scaled(by f: Double) -> PhotoVCarveParameters {
        var p = self
        p.origin = Vec2(origin.x * f, origin.y * f); p.width *= f; p.lineSpacing *= f; p.minDepth *= f; p.startDepth *= f
        return p
    }

    /// Picture as large as fits in 80% of the material, centred, keeping the image's aspect.
    func fitted(in job: JobSetup) -> PhotoVCarveParameters {
        var p = self
        let aspect = image?.aspect ?? 1
        p.width = min(job.width * 0.8, job.height * 0.8 / aspect)
        p.origin = Vec2((job.width - p.width) / 2, (job.height - p.width * aspect) / 2)
        return p
    }
}

extension Relief3DParameters {
    func scaled(by f: Double) -> Relief3DParameters {
        var p = self
        p.resolution *= f
        p.roughing.allowance *= f
        p.roughing.passDepth = roughing.passDepth.map { $0 * f }
        p.finishing.stepover = finishing.stepover.map { $0 * f }
        return p
    }
}

extension EngraveParameters {
    func scaled(by f: Double) -> EngraveParameters { var p = self; p.depth = depth.scaled(by: f); return p }
}

extension ChamferParameters {
    func scaled(by f: Double) -> ChamferParameters {
        var p = self
        p.width *= f; p.depth = depth.map { $0 * f }; p.tipClearance *= f; p.startDepth *= f
        p.passDepth = passDepth.map { $0 * f }
        return p
    }
}

extension FacingParameters {
    func scaled(by f: Double) -> FacingParameters {
        var p = self
        p.depth = depth.scaled(by: f); p.overhang = overhang.map { $0 * f }
        return p
    }
}

extension HoleMillParameters {
    func scaled(by f: Double) -> HoleMillParameters {
        var p = self
        p.startDepth *= f; p.cutDepth *= f; p.holeDiameter = holeDiameter.map { $0 * f }
        p.helixPitch = helixPitch.map { $0 * f }; p.threadPitch *= f
        return p
    }
}

extension PrismParameters {
    func scaled(by f: Double) -> PrismParameters {
        var p = self
        p.maxDepth = maxDepth.map { $0 * f }; p.passDepth = passDepth.map { $0 * f }
        return p
    }
}

extension ToolOverride {
    func scaled(by f: Double) -> ToolOverride {
        var o = self
        o.feedRate = feedRate.map { $0 * f }; o.plungeRate = plungeRate.map { $0 * f }
        o.stepdown = stepdown.map { $0 * f }; o.stepover = stepover.map { $0 * f }
        return o
    }
}

extension StraightInlayParameters {
    func scaled(by f: Double) -> StraightInlayParameters {
        var p = self
        p.pocketDepth *= f; p.plugDepth *= f; p.clearance *= f; p.passDepth = passDepth.map { $0 * f }
        return p
    }
}

extension MouldingParameters {
    func scaled(by f: Double) -> MouldingParameters {
        var p = self
        p.startDepth *= f; p.stepover = stepover.map { $0 * f }
        return p
    }
}

extension AnyOperation {
    func scaled(by f: Double) -> AnyOperation {
        let op = scaledParameters(by: f)
        guard setup.toolOverride != nil || setup.arrayCopy != nil else { return op }
        var s = op.setup
        s.toolOverride = setup.toolOverride?.scaled(by: f)
        s.arrayCopy?.spacingX *= f
        s.arrayCopy?.spacingY *= f
        return op.with(setup: s)
    }

    private func scaledParameters(by f: Double) -> AnyOperation {
        switch self {
        case .profile(var o): o.params = o.params.scaled(by: f); return .profile(o)
        case .pocket(var o): o.params = o.params.scaled(by: f); return .pocket(o)
        case .drill(var o): o.params = o.params.scaled(by: f); return .drill(o)
        case .vcarve(var o): o.params = o.params.scaled(by: f); return .vcarve(o)
        case .inlay(var o): o.params = o.params.scaled(by: f); return .inlay(o)
        case .fluting(var o): o.params = o.params.scaled(by: f); return .fluting(o)
        case .texture(var o): o.params = o.params.scaled(by: f); return .texture(o)
        case .relief3D(var o): o.params = o.params.scaled(by: f); return .relief3D(o)
        case .photoVCarve(var o): o.params = o.params.scaled(by: f); return .photoVCarve(o)
        case .engrave(var o): o.params = o.params.scaled(by: f); return .engrave(o)
        case .chamfer(var o): o.params = o.params.scaled(by: f); return .chamfer(o)
        case .holeMill(var o): o.params = o.params.scaled(by: f); return .holeMill(o)
        case .prism(var o): o.params = o.params.scaled(by: f); return .prism(o)
        case .merge(var o): o.params.children = o.params.children.map { $0.scaled(by: f) }; return .merge(o)
        case .straightInlay(var o): o.params = o.params.scaled(by: f); return .straightInlay(o)
        case .moulding(var o): o.params = o.params.scaled(by: f); return .moulding(o)
        case .facing(var o): o.params = o.params.scaled(by: f); return .facing(o)
        }
    }
}

extension PlacedModel {
    func scaled(by f: Double) -> PlacedModel {
        var m = self
        m.mesh.vertices = mesh.vertices.map { $0 * f }
        m.offset = offset * f; m.depth *= f; m.zTop *= f
        m.reliefSplit = reliefSplit?.scaled(by: f)
        return m
    }
}

extension Document {
    /// Same design expressed in `target` units (geometry, job, grid and models rescaled).
    func converted(to target: LengthUnit) -> Document {
        guard target != units else { return self }
        let f = units.factor(to: target)
        var d = self
        d.units = target
        d.job = job.scaled(by: f)
        d.gridSpacing = gridSpacing * f
        // User variables are plain numbers (a count or a ratio as often as a length) and keep their value.
        d.shapes = shapes.map { $0.transformed(.scale(f, f)) }
        d.models = models.map { $0.scaled(by: f) }
        d.keepOutZones = keepOutZones?.map { z in
            var s = z
            s.outline = z.outline.map { $0 * f }; s.height *= f
            return s
        }
        for i in d.layers.indices {
            if let s = d.layers[i].sheet { d.layers[i].sheet = SheetSlot(number: s.number, offset: s.offset * f) }
            if let k = d.layers[i].keepOut { d.layers[i].keepOut = LayerKeepOut(height: k.height * f) }
        }
        d.otherSheets = otherSheets?.map { var s = $0; s.job = $0.job.scaled(by: f); return s }
        d.images = images?.map { var i = $0; i.rect = Rect2(min: $0.rect.min * f, max: $0.rect.max * f); return i }
        d.guides = guides?.map { GuideLine(isVertical: $0.isVertical, position: $0.position * f) }
        d.dimensions = dimensions?.map { dim in
            var c = dim
            c.points = dim.points.map { $0 * f }
            c.offset = dim.offset * f
            return c
        }
        return d
    }
}

extension LoftLineProject {
    /// Converts the design and every operation's lengths to `target` units.
    func converted(to target: LengthUnit) -> LoftLineProject {
        guard target != document.units else { return self }
        let f = document.units.factor(to: target)
        var p = self
        p.document = document.converted(to: target)
        p.operations = operations.map { $0.scaled(by: f) }
        return p
    }
}

extension ReliefSplit {
    func scaled(by f: Double) -> ReliefSplit {
        var s = self
        s.splitDepth = splitDepth.map { $0 * f }
        s.web *= f
        return s
    }
}
