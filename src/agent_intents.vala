namespace Singularity.Apps.Maps {

    internal class MapsIntents : Object {

        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key).strip () : "";
        }

        private static bool has_coords (Json.Object args, string prefix) {
            return args.has_member (prefix + "lat") && args.has_member (prefix + "lon");
        }

        private static double coord (Json.Object args, string key, double min, double max) throws Error {
            double v = args.get_double_member (key);
            if (v.is_nan () || v < min || v > max) throw new IOError.INVALID_ARGUMENT ("%s must be between %g and %g", key, min, max);
            return v;
        }

        private static string fmt (double v) {
            return v.format (new char[32], "%.6f");
        }

        private static void place (Json.Builder b, Place p, double from_lat = double.NAN, double from_lon = double.NAN) {
            b.begin_object ();
            b.set_member_name ("name").add_string_value (p.name);
            if (p.detail != "") b.set_member_name ("address").add_string_value (p.detail);
            if (p.category != "") b.set_member_name ("kind").add_string_value (p.category);
            b.set_member_name ("lat").add_double_value (p.lat);
            b.set_member_name ("lon").add_double_value (p.lon);
            if (!from_lat.is_nan ()) b.set_member_name ("distance").add_string_value (Geo.format_distance (Geo.distance (from_lat, from_lon, p.lat, p.lon)));
            b.end_object ();
        }

        private static void center (MapsApp app, out double lat, out double lon) {
            app.agent_window ().agent_map ().center (out lat, out lon);
        }

        private static async Place resolve (MapsApp app, Json.Object args, string prefix, string name_key) throws Error {
            if (has_coords (args, prefix)) {
                double lat = coord (args, prefix + "lat", -90, 90);
                double lon = coord (args, prefix + "lon", -180, 180);
                try {
                    var p = yield Search.reverse (lat, lon, 18);
                    p.lat = lat;
                    p.lon = lon;
                    return p;
                } catch (Error e) {
                    return new Place (Geo.format_coords (lat, lon), "", lat, lon);
                }
            }
            string q = text (args, name_key);
            if (q == "") throw new IOError.INVALID_ARGUMENT ("give %s or %slat and %slon", name_key, prefix, prefix);
            double lat, lon;
            center (app, out lat, out lon);
            var found = yield Search.query (q, lat, lon);
            if (found.size == 0) throw new IOError.NOT_FOUND ("%s was not found on the map", q);
            return found[0];
        }

        private static async void settle (MapView map) {
            for (int i = 0; i < 40 && map.flying; i++) {
                Timeout.add (50, settle.callback);
                yield;
            }
        }

        private static Mode mode_arg (Json.Object args) throws Error {
            switch (text (args, "mode")) {
                case "":
                case "car": return Mode.CAR;
                case "bike": return Mode.BIKE;
                case "foot":
                case "walk": return Mode.FOOT;
                default: throw new IOError.INVALID_ARGUMENT ("mode is car, bike or foot");
            }
        }

        private static string mode_id (Mode m) {
            switch (m) {
                case Mode.BIKE: return "bike";
                case Mode.FOOT: return "foot";
                default: return "car";
            }
        }

        private static Json.Node view (MapsApp app) {
            var w = app.agent_window ();
            var map = w.agent_map ();
            double lat, lon;
            map.center (out lat, out lon);
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("center_lat").add_double_value (lat);
            b.set_member_name ("center_lon").add_double_value (lon);
            b.set_member_name ("zoom").add_double_value (Math.round (map.zoom * 10) / 10);
            b.set_member_name ("layer").add_string_value (map.tiles.source.id);
            if (map.pin != null) {
                b.set_member_name ("shown_place");
                place (b, map.pin);
            }
            var r = w.agent_route ();
            if (r != null && map.route != null && w.agent_origin () != null && w.agent_destination () != null) {
                b.set_member_name ("route").begin_object ();
                b.set_member_name ("from").add_string_value (w.agent_origin ().name);
                b.set_member_name ("to").add_string_value (w.agent_destination ().name);
                b.set_member_name ("mode").add_string_value (mode_id (w.agent_mode ()));
                b.set_member_name ("time").add_string_value (Geo.format_duration (r.duration));
                b.set_member_name ("distance").add_string_value (Geo.format_distance (r.distance));
                b.end_object ();
            }
            b.end_object ();
            return b.get_root ();
        }

        private static async void dispatch (MapsApp app, string name, Json.Object args, owned Singularity.AppIntentReply reply) {
            app.hold ();
            try {
                reply (yield work (app, name, args), null);
            } catch (Error e) {
                reply (null, e);
            } finally {
                app.release ();
            }
        }

        private static async Json.Node work (MapsApp app, string name, Json.Object args) throws Error {
            switch (name) {
                case "search": {
                    string q = text (args, "query");
                    if (q == "") throw new IOError.INVALID_ARGUMENT ("give what to search for");
                    double lat, lon;
                    if (has_coords (args, "near_")) {
                        lat = coord (args, "near_lat", -90, 90);
                        lon = coord (args, "near_lon", -180, 180);
                    } else {
                        center (app, out lat, out lon);
                    }
                    var found = yield Search.query (q, lat, lon);
                    int limit = args.has_member ("limit") ? (int) args.get_int_member ("limit").clamp (1, 12) : 8;
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("places").begin_array ();
                    int n = 0;
                    foreach (var p in found) {
                        if (n++ >= limit) break;
                        place (b, p, lat, lon);
                    }
                    b.end_array ();
                    if (found.size == 0) b.set_member_name ("note").add_string_value ("nothing was found; try other words or a wider area");
                    b.end_object ();
                    return b.get_root ();
                }
                case "here": {
                    if (!has_coords (args, "")) throw new IOError.INVALID_ARGUMENT ("give lat and lon");
                    double lat = coord (args, "lat", -90, 90);
                    double lon = coord (args, "lon", -180, 180);
                    var p = yield Search.reverse (lat, lon, args.has_member ("zoom") ? (int) args.get_int_member ("zoom") : 18);
                    p.lat = lat;
                    p.lon = lon;
                    var b = new Json.Builder ();
                    place (b, p);
                    return b.get_root ();
                }
                case "show": {
                    var w = app.agent_window ();
                    var map = w.agent_map ();
                    double before_lat, before_lon;
                    map.center (out before_lat, out before_lon);
                    double before_zoom = map.zoom;
                    var p = yield resolve (app, args, "", "place");
                    w.show_place (p, true);
                    yield settle (map);
                    if (map.pin != p) throw new IOError.FAILED ("%s is not shown on the map", p.name);
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("shown");
                    place (b, p);
                    b.set_member_name ("undo").add_string_value ("maps_move with lat %s, lon %s, zoom %g".printf (fmt (before_lat), fmt (before_lon), Math.round (before_zoom)));
                    b.end_object ();
                    return b.get_root ();
                }
                case "move": {
                    if (!has_coords (args, "")) throw new IOError.INVALID_ARGUMENT ("give lat and lon");
                    double lat = coord (args, "lat", -90, 90);
                    double lon = coord (args, "lon", -180, 180);
                    var map = app.agent_window ().agent_map ();
                    double before_lat, before_lon;
                    map.center (out before_lat, out before_lon);
                    double before_zoom = map.zoom;
                    double z = args.has_member ("zoom") ? args.get_double_member ("zoom").clamp (1, MAX_ZOOM) : map.zoom;
                    app.agent_window ().agent_view (lat, lon, z);
                    yield settle (map);
                    if (map.flying) map.set_center (lat, lon, z);
                    double now_lat, now_lon;
                    map.center (out now_lat, out now_lon);
                    if (Geo.distance (now_lat, now_lon, lat, lon) > 50 || (map.zoom - z).abs () > 0.05) throw new IOError.FAILED ("the map did not move there");
                    var root = view (app);
                    root.get_object ().set_string_member ("undo", "maps_move with lat %s, lon %s, zoom %g".printf (fmt (before_lat), fmt (before_lon), Math.round (before_zoom)));
                    return root;
                }
                case "route": {
                    var w = app.agent_window ();
                    Place from;
                    if (has_coords (args, "from_") || text (args, "from") != "") {
                        from = yield resolve (app, args, "from_", "from");
                    } else {
                        double lat, lon, acc;
                        try {
                            yield new Locator ().locate (out lat, out lon, out acc);
                        } catch (Error e) {
                            throw new IOError.NOT_FOUND ("the current location is not available (%s); give from", e.message);
                        }
                        from = new Place (_("My Location"), "", lat, lon);
                    }
                    var to = yield resolve (app, args, "to_", "to");
                    var m = mode_arg (args);
                    var r = yield Router.find (from, to, m);
                    w.agent_directions (from, to, m);
                    for (int i = 0; i < 100 && (w.agent_route () == null || w.agent_map ().route == null || w.agent_map ().pin != to); i++) {
                        Timeout.add (100, work.callback);
                        yield;
                    }
                    if (w.agent_map ().route == null) throw new IOError.FAILED ("the route is not drawn on the map");
                    if (w.agent_origin () != from || w.agent_destination () != to) throw new IOError.FAILED ("the route is not shown in Maps");
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("from");
                    place (b, from);
                    b.set_member_name ("to");
                    place (b, to);
                    b.set_member_name ("mode").add_string_value (mode_id (m));
                    b.set_member_name ("time").add_string_value (Geo.format_duration (r.duration));
                    b.set_member_name ("seconds").add_double_value (Math.round (r.duration));
                    b.set_member_name ("distance").add_string_value (Geo.format_distance (r.distance));
                    b.set_member_name ("meters").add_double_value (Math.round (r.distance));
                    int steps = args.has_member ("steps") ? (int) args.get_int_member ("steps").clamp (0, 200) : 20;
                    b.set_member_name ("directions").begin_array ();
                    int n = 0;
                    foreach (var st in r.steps) {
                        if (n++ >= steps) break;
                        b.add_string_value (st.distance > 0 ? "%s (%s)".printf (st.text, Geo.format_distance (st.distance)) : st.text);
                    }
                    b.end_array ();
                    if (r.steps.size > steps) b.set_member_name ("more_directions").add_int_value (r.steps.size - steps);
                    b.end_object ();
                    return b.get_root ();
                }
                case "locate": {
                    double lat, lon, acc;
                    try {
                        yield new Locator ().locate (out lat, out lon, out acc);
                    } catch (Error e) {
                        throw new IOError.NOT_FOUND ("the location is not available; Location Services may be off (%s)", e.message);
                    }
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("lat").add_double_value (lat);
                    b.set_member_name ("lon").add_double_value (lon);
                    b.set_member_name ("accuracy_meters").add_double_value (Math.round (acc));
                    b.end_object ();
                    return b.get_root ();
                }
                case "favorite": {
                    var favs = app.favorites;
                    bool add = !args.has_member ("add") || args.get_boolean_member ("add");
                    Place? p = null;
                    if (!add && text (args, "place") != "" && !has_coords (args, "")) {
                        string want = text (args, "place").casefold ();
                        foreach (var f in favs.places) if (f.name.casefold () == want) p = f;
                        if (p == null) throw new IOError.NOT_FOUND ("%s is not a favorite place; see maps_favorites", text (args, "place"));
                    } else {
                        p = yield resolve (app, args, "", "place");
                    }
                    bool was = favs.contains (p);
                    if (was != add) favs.toggle (p);
                    if (favs.contains (p) != add) throw new IOError.FAILED ("the favorites did not change");
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name (add ? "added" : "removed");
                    place (b, p);
                    if (was == add) b.set_member_name ("already").add_boolean_value (true);
                    else b.set_member_name ("undo").add_string_value ("maps_favorite with lat %s, lon %s, add %s".printf (fmt (p.lat), fmt (p.lon), add ? "false" : "true"));
                    b.end_object ();
                    return b.get_root ();
                }
                default:
                    throw new IOError.NOT_SUPPORTED ("%s", name);
            }
        }

        internal static void install (MapsApp app) {
            var agent = app.agent;
            agent.add_intent ("maps_view", "What the Maps window shows now: the center, the zoom, the map layer, the place shown and the route, if any.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args) => {
                    return view (app);
                });
            agent.add_async_intent ("maps_search", "Search places by name, address or kind (for example pharmacy), near the map center or near given coordinates. Results come from OpenStreetMap.",
                "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"near_lat\":{\"type\":\"number\"},\"near_lon\":{\"type\":\"number\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"query\"]}",
                Singularity.AppIntentRisk.READ, (args, reply) => {
                    dispatch.begin (app, "search", args, (owned) reply);
                });
            agent.add_async_intent ("maps_here", "Tell what is at some coordinates: the address or the name of the place.",
                "{\"type\":\"object\",\"properties\":{\"lat\":{\"type\":\"number\"},\"lon\":{\"type\":\"number\"}},\"required\":[\"lat\",\"lon\"]}",
                Singularity.AppIntentRisk.READ, (args, reply) => {
                    dispatch.begin (app, "here", args, (owned) reply);
                });
            agent.add_async_intent ("maps_show", "Show a place in Maps with a pin and its details, found by name or given as coordinates.",
                "{\"type\":\"object\",\"properties\":{\"place\":{\"type\":\"string\"},\"lat\":{\"type\":\"number\"},\"lon\":{\"type\":\"number\"}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    dispatch.begin (app, "show", args, (owned) reply);
                });
            agent.add_async_intent ("maps_move", "Move the map to some coordinates and zoom (1 is the whole world, 18 is a street).",
                "{\"type\":\"object\",\"properties\":{\"lat\":{\"type\":\"number\"},\"lon\":{\"type\":\"number\"},\"zoom\":{\"type\":\"number\"}},\"required\":[\"lat\",\"lon\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    dispatch.begin (app, "move", args, (owned) reply);
                });
            agent.add_async_intent ("maps_route", "Plan a route by car, bike or on foot and show it in Maps. Gives the travel time, the distance and the turn by turn directions. Without from it starts at the current location.",
                "{\"type\":\"object\",\"properties\":{\"to\":{\"type\":\"string\"},\"to_lat\":{\"type\":\"number\"},\"to_lon\":{\"type\":\"number\"},\"from\":{\"type\":\"string\"},\"from_lat\":{\"type\":\"number\"},\"from_lon\":{\"type\":\"number\"},\"mode\":{\"type\":\"string\",\"enum\":[\"car\",\"bike\",\"foot\"]},\"steps\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    dispatch.begin (app, "route", args, (owned) reply);
                });
            agent.add_async_intent ("maps_locate", "The current location of this computer, when Location Services are on.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args, reply) => {
                    dispatch.begin (app, "locate", args, (owned) reply);
                });
            agent.add_intent ("maps_favorites", "The favorite places saved in Maps.",
                "{\"type\":\"object\",\"properties\":{}}", Singularity.AppIntentRisk.READ, (args) => {
                    var b = new Json.Builder ();
                    b.begin_object ();
                    b.set_member_name ("places").begin_array ();
                    foreach (var p in app.favorites.places) place (b, p);
                    b.end_array ();
                    b.end_object ();
                    return b.get_root ();
                });
            agent.add_async_intent ("maps_favorite", "Add a place to the favorites, or remove it with add false. The place is found by name or given as coordinates.",
                "{\"type\":\"object\",\"properties\":{\"place\":{\"type\":\"string\"},\"lat\":{\"type\":\"number\"},\"lon\":{\"type\":\"number\"},\"add\":{\"type\":\"boolean\"}}}",
                Singularity.AppIntentRisk.UNDOABLE, (args, reply) => {
                    dispatch.begin (app, "favorite", args, (owned) reply);
                });
            agent.add_intent ("maps_layer", "Change the map layer. See maps_view for the current one.",
                "{\"type\":\"object\",\"properties\":{\"layer\":{\"type\":\"string\"}},\"required\":[\"layer\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    string id = text (args, "layer");
                    var w = app.agent_window ();
                    string before = w.agent_map ().tiles.source.id;
                    TileSource? src = null;
                    string[] ids = {};
                    foreach (var s in TileSource.all ()) {
                        ids += s.id;
                        if (s.id == id || s.name.casefold () == id.casefold ()) src = s;
                    }
                    if (src == null) throw new IOError.INVALID_ARGUMENT ("the layers are %s", string.joinv (", ", ids));
                    w.agent_layer (src);
                    if (w.agent_map ().tiles.source != src) throw new IOError.FAILED ("the layer did not change");
                    var root = view (app);
                    root.get_object ().set_string_member ("undo", "maps_layer with layer " + before);
                    return root;
                });
        }
    }
}
