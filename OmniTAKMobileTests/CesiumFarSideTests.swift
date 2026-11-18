//
//  CesiumFarSideTests.swift
//  OmniTAKMobileTests
//
//  Markers on the 3D globe skip the depth test at any distance, so one never sinks into terrain or a
//  building. The price was that a marker on the far side of the Earth was drawn through the planet:
//  at whole-earth zoom with the camera over Africa, the operator's marker at 117 W showed over
//  north-west Africa. The page now hides what the planet itself hides, once per frame in which the
//  camera or a marker has moved (Cesium's horizon test, EllipsoidalOccluder), the way the Android
//  page does. These run the page's own function in JavaScriptCore against a stand-in for the few
//  Cesium calls it makes; the horizon test in the stand-in is Cesium's, ported.
//

import XCTest
import JavaScriptCore
@testable import OmniTAK

final class CesiumFarSideTests: XCTestCase {

    /// The Cesium the page's function talks to, and a few helpers. `Cesium.checks` counts horizon tests.
    private static let standIn = #"""
    var Cesium = {
      Cartesian3: {
        clone: function(c, r) { r = r || {x: 0, y: 0, z: 0}; r.x = c.x; r.y = c.y; r.z = c.z; return r; },
        equals: function(a, b) { return a === b || (!!a && !!b && a.x === b.x && a.y === b.y && a.z === b.z); }
      },
      Ellipsoid: { WGS84: { radii: {x: 6378137.0, y: 6378137.0, z: 6356752.314245179} } },
      checks: 0
    };
    // Cesium's EllipsoidalOccluder: the horizon test in the ellipsoid's scaled space.
    Cesium.EllipsoidalOccluder = function(ellipsoid, cameraPosition) {
      this._r = ellipsoid.radii; this._cv = null; this._vh = 0;
      Object.defineProperty(this, 'cameraPosition', { set: function(p) {
        this._cv = this._scaled(p);
        this._vh = this._cv.x * this._cv.x + this._cv.y * this._cv.y + this._cv.z * this._cv.z - 1.0;
      } });
      this.cameraPosition = cameraPosition;
    };
    Cesium.EllipsoidalOccluder.prototype._scaled = function(p) { return {x: p.x / this._r.x, y: p.y / this._r.y, z: p.z / this._r.z}; };
    Cesium.EllipsoidalOccluder.prototype.isPointVisible = function(occludee) {
      Cesium.checks++;
      var cv = this._cv, s = this._scaled(occludee);
      var vt = {x: s.x - cv.x, y: s.y - cv.y, z: s.z - cv.z};
      var vtDotVc = -(vt.x * cv.x + vt.y * cv.y + vt.z * cv.z);
      var vtMagnitudeSquared = vt.x * vt.x + vt.y * vt.y + vt.z * vt.z;
      var occluded = this._vh < 0 ? vtDotVc > 0
        : (vtDotVc > this._vh && (vtDotVc * vtDotVc) / vtMagnitudeSquared > this._vh);
      return !occluded;
    };
    function ecef(latDeg, lonDeg, h) {
      var a = 6378137.0, f = 1 / 298.257223563, e2 = f * (2 - f);
      var lat = latDeg * Math.PI / 180, lon = lonDeg * Math.PI / 180;
      var n = a / Math.sqrt(1 - e2 * Math.sin(lat) * Math.sin(lat));
      return {x: (n + h) * Math.cos(lat) * Math.cos(lon), y: (n + h) * Math.cos(lat) * Math.sin(lon),
              z: (n * (1 - e2) + h) * Math.sin(lat)};
    }
    // an entity at a place; `sets` counts how often its visibility is written; `label` makes it a named shape
    function entity(lat, lon, named, height) {
      var p = ecef(lat, lon, height || 0);
      var e = {position: {getValue: function(t) { return p; }}, _show: true, sets: 0};
      Object.defineProperty(e, 'show', {get: function() { return this._show; }, set: function(v) { this._show = v; this.sets++; }});
      if (named) e.label = {};
      return e;
    }
    function viewer(lat, lon, h) { return {camera: {positionWC: ecef(lat, lon, h)}, clock: {currentTime: 0}}; }
    var _state = {entities: new Map(), drawings: new Map(), measurements: new Map()};
    var spokane = entity(47.6588, -117.426), cairo = entity(30.04, 31.24), dakar = entity(14.7, -17.5);
    var coeur = entity(47.6777, -116.7805), seattle = entity(47.6062, -122.3321);
    _state.entities.set('self', spokane); _state.entities.set('cairo', cairo); _state.entities.set('dakar', dakar);
    """#

    private func context() throws -> JSContext {
        let html = CesiumMainMap.html
        let begin = try XCTUnwrap(html.range(of: "// FAR-SIDE-BEGIN"), "marker FAR-SIDE missing from cesium_scene.html")
        let end = try XCTUnwrap(html.range(of: "// FAR-SIDE-END"), "marker FAR-SIDE missing from cesium_scene.html")
        let start = try XCTUnwrap(html[begin.upperBound...].firstIndex(of: "\n"))
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail("page script threw: \(String(describing: error))") }
        context.evaluateScript(Self.standIn)
        context.evaluateScript(String(html[start..<end.lowerBound]))
        return context
    }

    private func shown(_ c: JSContext, _ name: String) -> Bool { c.evaluateScript("\(name).show").toBool() }
    private func number(_ c: JSContext, _ expression: String) -> Int { Int(c.evaluateScript(expression).toInt32()) }

    // MARK: - What the planet hides

    func testAMarkerOnTheFarSideOfThePlanetIsHiddenAndOnesInFrontAreShown() throws {
        // the camera over Africa at whole-earth zoom (the report: the marker at 117 W showed over the Sahara)
        let c = try context()
        c.evaluateScript("_cullFarSide(viewer(0, 20, 20000000));")
        XCTAssertFalse(shown(c, "spokane"), "Spokane is on the other side of the Earth")
        XCTAssertTrue(shown(c, "cairo"))
        XCTAssertTrue(shown(c, "dakar"))
    }

    func testTheHorizonFollowsTheCameraDownToStreetLevelAndBackOut() throws {
        let c = try context()
        c.evaluateScript("_state.entities.set('coeur', coeur); _state.entities.set('seattle', seattle);")
        // 3.2 km over Spokane: the horizon is about 200 km away
        c.evaluateScript("_cullFarSide(viewer(47.6588, -117.426, 3219));")
        XCTAssertTrue(shown(c, "spokane"))
        XCTAssertTrue(shown(c, "coeur"), "49 km away")
        XCTAssertFalse(shown(c, "seattle"), "366 km away, over the horizon")
        XCTAssertFalse(shown(c, "cairo"))
        // back out to the whole earth over Africa
        c.evaluateScript("_cullFarSide(viewer(0, 20, 20000000));")
        XCTAssertFalse(shown(c, "spokane"))
        XCTAssertTrue(shown(c, "cairo"))
        // and over North America from far out: Spokane again, Cairo behind
        c.evaluateScript("_cullFarSide(viewer(40, -100, 20000000));")
        XCTAssertTrue(shown(c, "spokane"))
        XCTAssertTrue(shown(c, "seattle"))
        XCTAssertFalse(shown(c, "cairo"))
    }

    // MARK: - When it works

    func testNothingIsCheckedWhileTheCameraAndTheMarkersAreStill() throws {
        let c = try context()
        c.evaluateScript("_cullFarSide(viewer(0, 20, 20000000));")
        let first = number(c, "Cesium.checks")
        XCTAssertEqual(first, 3, "one horizon test per marker")
        // the same camera (a new object with the same numbers): nothing is checked again
        c.evaluateScript("_cullFarSide(viewer(0, 20, 20000000));")
        XCTAssertEqual(number(c, "Cesium.checks"), first)
        // the camera moves: everything is
        c.evaluateScript("_cullFarSide(viewer(0, 21, 20000000));")
        XCTAssertEqual(number(c, "Cesium.checks"), first + 3)
    }

    func testAMarkerThatWasAddedOrMovedIsCheckedEvenIfTheCameraIsStill() throws {
        let c = try context()
        c.evaluateScript("_cullFarSide(viewer(0, 20, 20000000));")
        // a new marker on the far side: unseen until the page says something changed
        c.evaluateScript("var newcomer = entity(47.6, -122.3); _state.entities.set('new', newcomer); _state.horizonDirty = true;")
        c.evaluateScript("_cullFarSide(viewer(0, 20, 20000000));")
        XCTAssertFalse(shown(c, "newcomer"))
        XCTAssertEqual(number(c, "Cesium.checks"), 3 + 4, "the three again and the new one")
        // and the page does say so when it adds or moves a marker or a shape
        let html = CesiumMainMap.html
        let upsert = try XCTUnwrap(html.range(of: "upsertEntity(arg){")), setEntities = try XCTUnwrap(html.range(of: "setEntities(arg){"))
        XCTAssertTrue(html[upsert.lowerBound..<setEntities.lowerBound].contains("_state.horizonDirty=true"))
        let drawing = try XCTUnwrap(html.range(of: "upsertDrawing(arg){")), setDrawings = try XCTUnwrap(html.range(of: "setDrawings(arg){"))
        XCTAssertTrue(html[drawing.lowerBound..<setDrawings.lowerBound].contains("_state.horizonDirty=true"))
    }

    func testVisibilityIsWrittenOnlyWhenItChanges() throws {
        let c = try context()
        c.evaluateScript("_cullFarSide(viewer(0, 20, 20000000));")
        XCTAssertEqual(number(c, "spokane.sets"), 1, "hidden once")
        XCTAssertEqual(number(c, "cairo.sets"), 0, "was shown and stays shown: not written")
        XCTAssertEqual(number(c, "dakar.sets"), 0)
        // a small move that changes nothing
        c.evaluateScript("_cullFarSide(viewer(0, 21, 20000000));")
        XCTAssertEqual(number(c, "spokane.sets"), 1)
        XCTAssertEqual(number(c, "cairo.sets"), 0)
        // Spokane comes round the horizon: written once more
        c.evaluateScript("_cullFarSide(viewer(40, -100, 20000000));")
        XCTAssertEqual(number(c, "spokane.sets"), 2)
    }

    // MARK: - Shapes

    func testOnlyAShapeThatCarriesANameIsHiddenWithTheHorizon() throws {
        // a geofence's name is a label that skips the depth test like a marker; a shape without a name is
        // clamped to the ground, which the planet hides by itself
        let c = try context()
        c.evaluateScript("""
        var fenceName = entity(47.6588, -117.426, true), ring = entity(47.6588, -117.426, false), noPosition = {show: true};
        _state.drawings.set('fence-label', fenceName); _state.drawings.set('ring', ring); _state.drawings.set('poly', noPosition);
        _cullFarSide(viewer(0, 20, 20000000));
        """)
        XCTAssertFalse(shown(c, "fenceName"), "its name is on the far side")
        XCTAssertTrue(shown(c, "ring"), "no name: left to the planet")
        XCTAssertEqual(number(c, "ring.sets"), 0)
        XCTAssertTrue(shown(c, "noPosition"))
        c.evaluateScript("_cullFarSide(viewer(47.6588, -117.426, 3219));")
        XCTAssertTrue(shown(c, "fenceName"), "over Spokane it is in front")
    }

    // MARK: - Measurements and aircraft

    func testAMeasurementsVertexDotsAreHiddenWithTheHorizonAndItsLineIsLeftToThePlanet() throws {
        // the dots and their distance labels skip the depth test like a marker; the line is clamped to the ground
        let c = try context()
        c.evaluateScript("""
        var dotHere = entity(47.6588, -117.426), dotThere = entity(47.66, -117.42), line = entity(47.6588, -117.426);
        _state.measurements.set('meas-1', {entity: line, vertexEntities: [dotHere, dotThere]});
        _state.measurements.set('meas-2', {entity: line});
        _cullFarSide(viewer(0, 20, 20000000));
        """)
        XCTAssertFalse(shown(c, "dotHere"))
        XCTAssertFalse(shown(c, "dotThere"))
        XCTAssertTrue(shown(c, "line"))
        XCTAssertEqual(number(c, "line.sets"), 0)
        c.evaluateScript("_cullFarSide(viewer(47.6588, -117.426, 3219));")
        XCTAssertTrue(shown(c, "dotHere"))
        // a measurement the page adds is checked at once
        let html = CesiumMainMap.html
        let upsert = try XCTUnwrap(html.range(of: "upsertMeasurement(arg){")), setMeasurements = try XCTUnwrap(html.range(of: "setMeasurements(arg){"))
        XCTAssertTrue(html[upsert.lowerBound..<setMeasurements.lowerBound].contains("_state.horizonDirty=true"))
    }

    func testAnAircraftHighAboveTheHorizonIsStillSeenWhereAMarkerOnTheGroundIsNot() throws {
        // 3.2 km up the ground horizon is about 200 km away; a jet at 10 km is above the horizon of its own for another 350 km
        let c = try context()
        c.evaluateScript("""
        var jet = entity(47.6, -121.0, false, 10000), onTheGround = entity(47.6, -121.0, false, 0);
        _state.entities.set('jet', jet); _state.entities.set('ground', onTheGround);
        _cullFarSide(viewer(47.6588, -117.426, 3219));
        """)
        XCTAssertTrue(shown(c, "jet"), "about 280 km away, 10 km up")
        XCTAssertFalse(shown(c, "onTheGround"), "the same place on the ground is over the horizon")
    }

    // MARK: - The page runs it

    func testThePageRunsTheCullBeforeEveryFrameAndAFailureCannotStopTheRenderLoop() {
        // an exception in a preRender listener would stop Cesium's render loop
        XCTAssertTrue(CesiumMainMap.html.contains("v.scene.preRender.addEventListener(function(){try{_cullFarSide(v)}catch(e){}})"))
    }
}
