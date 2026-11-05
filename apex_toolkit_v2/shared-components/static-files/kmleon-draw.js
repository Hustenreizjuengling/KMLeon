/* KMLeon draw helper (the only custom JavaScript in the toolkit).
 *
 * Lets the user click a Point / LineString / Polygon into an APEX Map region and
 * writes the result as a GeoJSON geometry into a page item. Everything else -
 * preview layers, validation, saving - is native APEX: the preview map simply
 * refreshes from the item on change.
 */
window.kmleonDraw = (function () {
    "use strict";
    var map = null, mode = null, coords = [], item = null, regionId = null;

    function geometry() {
        if (mode === "Point")      { return coords.length ? { type: "Point", coordinates: coords[0] } : null; }
        if (mode === "LineString") { return coords.length > 1 ? { type: "LineString", coordinates: coords.slice() } : null; }
        if (mode === "Polygon")    { return coords.length > 2 ? { type: "Polygon", coordinates: [coords.concat([coords[0]])] } : null; }
        return null;
    }
    // while a line/polygon is still incomplete, show the clicked vertices as points
    function publish() {
        var g = geometry() || (coords.length ? { type: "MultiPoint", coordinates: coords.slice() } : null);
        apex.item(item).setValue(g ? JSON.stringify(g) : "");
    }
    function onClick(e) {
        if (!mode) { return; }
        var c = [ +e.lngLat.lng.toFixed(6), +e.lngLat.lat.toFixed(6) ];
        if (mode === "Point") { coords = [c]; } else { coords.push(c); }
        publish();
    }
    function attach() {
        var r = apex.region(regionId), m = r && r.getMapObject && r.getMapObject();
        if (!m || m === map) { return !!m; }
        map = m;
        map.on("click", onClick);
        map.on("dblclick", function (e) {
            if (mode && mode !== "Point") { e.preventDefault(); window.kmleonDraw.finish(); }
        });
        return true;
    }
    function markButtons() {
        document.querySelectorAll("[data-draw]").forEach(function (b) {
            var on = b.getAttribute("data-draw") === mode;
            b.classList.toggle("is-active", on);
            b.setAttribute("aria-pressed", on ? "true" : "false");
        });
    }
    function load(text) {
        try {
            var g = JSON.parse(text);
            if (g.type === "Point")      { mode = "Point";      coords = [g.coordinates]; }
            if (g.type === "LineString") { mode = "LineString"; coords = g.coordinates.slice(); }
            if (g.type === "Polygon")    { mode = "Polygon";    coords = g.coordinates[0].slice(0, -1); }
        } catch (e) { /* not a geometry we can edit vertex-wise: start fresh */ }
        mode = null;
    }
    return {
        init: function (opts) {
            regionId = opts.region; item = opts.item;
            load(apex.item(item).getValue());
            apex.jQuery("#" + regionId).on("spatialmapinitialized", attach);
            (function retry(n) { if (!attach() && n > 0) { setTimeout(function () { retry(n - 1); }, 400); } })(25);
        },
        mode: function (m) {
            if (m !== mode) { coords = []; }
            mode = m;
            if (map && map.doubleClickZoom) { map.doubleClickZoom[m && m !== "Point" ? "disable" : "enable"](); }
            markButtons();
            if (m) {
                apex.message.showPageSuccess(m === "Point" ? "Click on the map to place the point."
                                                           : "Click the vertices on the map; double-click to finish.");
            }
        },
        undo:   function () { coords.pop(); publish(); },
        clear:  function () { coords = []; publish(); this.mode(null); },
        finish: function () { publish(); this.mode(null); }
    };
})();
