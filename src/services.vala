namespace Singularity.Apps.Maps {

    public class Net {
        private static Soup.Session? session;

        public static Soup.Session get () {
            if (session == null) {
                session = new Soup.Session ();
                session.user_agent = "SingularityMaps/0.1 (+https://github.com/singularityos-lab)";
                session.timeout = 20;
            }
            return session;
        }

        public static async Json.Node fetch_json (string url) throws Error {
            var msg = new Soup.Message ("GET", url);
            string? lang = Intl.get_language_names ()[0];
            if (lang != null && lang != "C") msg.request_headers.append ("Accept-Language", lang.split (".")[0].replace ("_", "-") + ",en;q=0.5");
            var bytes = yield get ().send_and_read_async (msg, Priority.DEFAULT, null);
            if (msg.status_code != 200) throw new IOError.FAILED (_("The service answered with an error (HTTP %u).").printf (msg.status_code));
            var parser = new Json.Parser ();
            parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
            return parser.get_root ();
        }
    }

    public class Search {
        public static string category_label (string key, string value) {
            switch (value) {
                case "restaurant": return _("Restaurant");
                case "cafe": return _("Café");
                case "bar": case "pub": return _("Bar");
                case "hotel": return _("Hotel");
                case "museum": return _("Museum");
                case "station": return _("Station");
                case "supermarket": return _("Supermarket");
                case "pharmacy": return _("Pharmacy");
                case "hospital": return _("Hospital");
                case "school": return _("School");
                case "university": return _("University");
                case "park": return _("Park");
                case "city": return _("City");
                case "town": return _("Town");
                case "village": return _("Village");
                case "country": return _("Country");
                case "state": return _("Region");
            }
            if (key == "highway") return _("Street");
            if (key == "building" || key == "house") return _("Address");
            return value.replace ("_", " ");
        }

        public static Gee.List<Place> parse_photon (Json.Node root) {
            var list = new Gee.ArrayList<Place> ();
            var features = root.get_object ().get_array_member ("features");
            foreach (var f in features.get_elements ()) {
                var o = f.get_object ();
                var props = o.get_object_member ("properties");
                var coords = o.get_object_member ("geometry").get_array_member ("coordinates");
                double lon = coords.get_double_element (0), lat = coords.get_double_element (1);
                string name = props.get_string_member_with_default ("name", "");
                string street = props.get_string_member_with_default ("street", "");
                string number = props.get_string_member_with_default ("housenumber", "");
                if (name == "" && street != "") name = number != "" ? street + " " + number : street;
                string[] parts = {};
                if (street != "" && !name.contains (street)) parts += number != "" ? street + " " + number : street;
                foreach (string k in new string[] { "postcode", "city", "state", "country" }) {
                    string v = props.get_string_member_with_default (k, "");
                    if (v != "" && v != name) parts += v;
                }
                var p = new Place (name != "" ? name : _("Unnamed Place"), string.joinv (", ", parts), lat, lon);
                p.category = category_label (props.get_string_member_with_default ("osm_key", ""), props.get_string_member_with_default ("osm_value", ""));
                p.osm_type = props.get_string_member_with_default ("osm_type", "");
                p.osm_id = props.get_int_member_with_default ("osm_id", 0);
                if (props.has_member ("extent")) {
                    var e = props.get_array_member ("extent");
                    if (e.get_length () == 4) p.extent = { e.get_double_element (0), e.get_double_element (1), e.get_double_element (2), e.get_double_element (3) };
                }
                list.add (p);
            }
            return list;
        }

        public static async Gee.List<Place> query (string text, double lat, double lon) throws Error {
            double la, lo;
            if (Geo.parse_coords (text, out la, out lo)) {
                var l = new Gee.ArrayList<Place> ();
                l.add (new Place (Geo.format_coords (la, lo), _("Coordinates"), la, lo));
                return l;
            }
            string lang = Intl.get_language_names ()[0].split ("_")[0];
            string[] supported = { "en", "de", "fr", "it" };
            string param = "";
            foreach (string s in supported) if (s == lang) param = "&lang=" + lang;
            char[] b1 = new char[32];
            char[] b2 = new char[32];
            string url = "https://photon.komoot.io/api/?limit=12&q=%s&lat=%s&lon=%s%s".printf (
                Uri.escape_string (text, null, false), lat.format (b1, "%.4f"), lon.format (b2, "%.4f"), param);
            return parse_photon (yield Net.fetch_json (url));
        }

        public static Place parse_reverse (Json.Node root, double lat, double lon) {
            var o = root.get_object ();
            var addr = o.has_member ("address") ? o.get_object_member ("address") : null;
            string name = o.get_string_member_with_default ("name", "");
            string road = addr != null ? addr.get_string_member_with_default ("road", "") : "";
            string num = addr != null ? addr.get_string_member_with_default ("house_number", "") : "";
            if (name == "") name = road != "" ? (num != "" ? road + " " + num : road) : Geo.format_coords (lat, lon);
            string detail = o.get_string_member_with_default ("display_name", "");
            if (detail.has_prefix (name + ", ")) detail = detail.substring (name.length + 2);
            var p = new Place (name, detail, lat, lon);
            p.category = category_label (o.get_string_member_with_default ("category", ""), o.get_string_member_with_default ("type", ""));
            string t = o.get_string_member_with_default ("osm_type", "");
            p.osm_type = t.length > 0 ? t.substring (0, 1).up () : "";
            p.osm_id = o.get_int_member_with_default ("osm_id", 0);
            return p;
        }

        public static async Place reverse (double lat, double lon, int zoom) throws Error {
            char[] b1 = new char[32];
            char[] b2 = new char[32];
            string url = "https://nominatim.openstreetmap.org/reverse?format=jsonv2&addressdetails=1&zoom=%d&lat=%s&lon=%s".printf (
                zoom.clamp (3, 18), lat.format (b1, "%.6f"), lon.format (b2, "%.6f"));
            var root = yield Net.fetch_json (url);
            if (root.get_object ().has_member ("error")) return new Place (Geo.format_coords (lat, lon), "", lat, lon);
            return parse_reverse (root, lat, lon);
        }
    }

    public enum Mode {
        CAR,
        BIKE,
        FOOT;

        public string profile () {
            switch (this) {
                case BIKE: return "routed-bike";
                case FOOT: return "routed-foot";
                default: return "routed-car";
            }
        }

        public string label () {
            switch (this) {
                case BIKE: return _("Bike");
                case FOOT: return _("Walk");
                default: return _("Car");
            }
        }
    }

    public class Step : Object {
        public string text = "";
        public double distance;
        public string icon = "";
    }

    public class Route : Object {
        public double distance;
        public double duration;
        public double[] points = {};
        public Gee.ArrayList<Step> steps = new Gee.ArrayList<Step> ();
        public double south = 90;
        public double north = -90;
        public double west = 180;
        public double east = -180;
    }

    public class Router {
        private static string ordinal (int n) {
            switch (n) {
                case 1: return _("first");
                case 2: return _("second");
                case 3: return _("third");
                case 4: return _("fourth");
                default: return n.to_string ();
            }
        }

        public static string instruction (Json.Object step, out string icon) {
            var man = step.get_object_member ("maneuver");
            string type = man.get_string_member_with_default ("type", "");
            string mod = man.get_string_member_with_default ("modifier", "");
            string road = step.get_string_member_with_default ("name", "");
            string on_road = road != "" ? _(" onto %s").printf (road) : "";
            icon = "go-up-symbolic";
            string dir;
            switch (mod) {
                case "left": dir = _("left"); icon = "maps-turn-left-symbolic"; break;
                case "slight left": dir = _("slightly left"); icon = "maps-turn-slight-left-symbolic"; break;
                case "sharp left": dir = _("sharp left"); icon = "maps-turn-left-symbolic"; break;
                case "right": dir = _("right"); icon = "maps-turn-right-symbolic"; break;
                case "slight right": dir = _("slightly right"); icon = "maps-turn-slight-right-symbolic"; break;
                case "sharp right": dir = _("sharp right"); icon = "maps-turn-right-symbolic"; break;
                case "uturn": dir = _("around"); icon = "maps-uturn-symbolic"; break;
                default: dir = _("straight"); icon = "go-up-symbolic"; break;
            }
            switch (type) {
                case "depart": icon = "maps-start-symbolic"; return road != "" ? _("Head out on %s").printf (road) : _("Head out");
                case "arrive": icon = "maps-arrive-symbolic"; return _("You have arrived");
                case "roundabout":
                case "rotary":
                    int exit = (int) man.get_int_member_with_default ("exit", 0);
                    icon = "maps-roundabout-symbolic";
                    return exit > 0 ? _("At the roundabout take the %s exit%s").printf (ordinal (exit), on_road) : _("Enter the roundabout");
                case "merge": return _("Merge %s%s").printf (dir, on_road);
                case "fork": return _("Keep %s%s").printf (dir, on_road);
                case "end of road": return _("At the end of the road turn %s%s").printf (dir, on_road);
                case "continue":
                case "new name":
                    icon = "go-up-symbolic";
                    return road != "" ? _("Continue on %s").printf (road) : _("Continue");
                case "on ramp": return _("Take the ramp%s").printf (on_road);
                case "off ramp": return _("Take the exit%s").printf (on_road);
                default: return mod == "straight" || mod == "" ? _("Go straight%s").printf (on_road) : _("Turn %s%s").printf (dir, on_road);
            }
        }

        public static Route parse (Json.Node root) throws Error {
            var o = root.get_object ();
            if (o.get_string_member_with_default ("code", "") != "Ok") throw new IOError.NOT_FOUND (_("No route was found between these places."));
            var r0 = o.get_array_member ("routes").get_object_element (0);
            var route = new Route ();
            route.distance = r0.get_double_member ("distance");
            route.duration = r0.get_double_member ("duration");
            var coords = r0.get_object_member ("geometry").get_array_member ("coordinates");
            double[] pts = new double[coords.get_length () * 2];
            for (uint i = 0; i < coords.get_length (); i++) {
                var c = coords.get_array_element (i);
                double lon = c.get_double_element (0), lat = c.get_double_element (1);
                pts[i * 2] = lat;
                pts[i * 2 + 1] = lon;
                route.south = double.min (route.south, lat);
                route.north = double.max (route.north, lat);
                route.west = double.min (route.west, lon);
                route.east = double.max (route.east, lon);
            }
            route.points = pts;
            foreach (var leg in r0.get_array_member ("legs").get_elements ()) {
                foreach (var s in leg.get_object ().get_array_member ("steps").get_elements ()) {
                    var so = s.get_object ();
                    var st = new Step ();
                    st.text = instruction (so, out st.icon);
                    st.distance = so.get_double_member ("distance");
                    route.steps.add (st);
                }
            }
            return route;
        }

        public static async Route find (Place from, Place to, Mode mode) throws Error {
            char[] a = new char[32];
            char[] b = new char[32];
            char[] c = new char[32];
            char[] d = new char[32];
            string url = "https://routing.openstreetmap.de/%s/route/v1/driving/%s,%s;%s,%s?overview=full&geometries=geojson&steps=true".printf (
                mode.profile (), from.lon.format (a, "%.6f"), from.lat.format (b, "%.6f"), to.lon.format (c, "%.6f"), to.lat.format (d, "%.6f"));
            return parse (yield Net.fetch_json (url));
        }
    }

    public class Favorites : Object {
        public Gee.ArrayList<Place> places = new Gee.ArrayList<Place> ();
        private string path;

        public signal void changed ();

        public Favorites (string? file = null) {
            path = file ?? Path.build_filename (Environment.get_user_data_dir (), "singularity", "maps", "places.json");
            load ();
        }

        private void load () {
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                foreach (var n in parser.get_root ().get_array ().get_elements ()) places.add (Place.from_json (n.get_object ()));
            } catch (Error e) {
            }
        }

        private void save () {
            var arr = new Json.Array ();
            foreach (var p in places) arr.add_element (p.to_json ());
            var root = new Json.Node (Json.NodeType.ARRAY);
            root.set_array (arr);
            var gen = new Json.Generator ();
            gen.root = root;
            gen.pretty = true;
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            try {
                gen.to_file (path);
            } catch (Error e) {
            }
            changed ();
        }

        public bool contains (Place p) {
            foreach (var f in places) if (f.key () == p.key ()) return true;
            return false;
        }

        public void toggle (Place p) {
            foreach (var f in places) {
                if (f.key () == p.key ()) {
                    places.remove (f);
                    save ();
                    return;
                }
            }
            places.add (p);
            save ();
        }
    }

    public class Locator : Object {
        private DBusConnection? bus = null;
        private string? client_path = null;
        private uint subscription = 0;

        public async void locate (out double lat, out double lon, out double accuracy) throws Error {
            lat = lon = accuracy = 0;
            string? fixed_location = Environment.get_variable ("SINGULARITY_LOCATION");
            if (fixed_location != null && Geo.parse_coords (fixed_location, out lat, out lon)) {
                accuracy = 10;
                return;
            }
            bus = yield Bus.get (BusType.SYSTEM);
            var reply = yield bus.call ("org.freedesktop.GeoClue2", "/org/freedesktop/GeoClue2/Manager",
                "org.freedesktop.GeoClue2.Manager", "GetClient", null, new VariantType ("(o)"), DBusCallFlags.NONE, 10000);
            reply.get ("(o)", out client_path);
            yield set_prop ("DesktopId", new Variant.string ("dev.sinty.maps"));
            yield set_prop ("RequestedAccuracyLevel", new Variant.uint32 (8));
            double r_lat = 0, r_lon = 0, r_acc = 0;
            Error? failure = null;
            SourceFunc callback = locate.callback;
            bool done = false;
            subscription = bus.signal_subscribe ("org.freedesktop.GeoClue2", "org.freedesktop.GeoClue2.Client", "LocationUpdated",
                client_path, null, DBusSignalFlags.NONE, (conn, sender, path, iface, name, parameters) => {
                    string location_path;
                    parameters.get ("(oo)", null, out location_path);
                    bus.call.begin ("org.freedesktop.GeoClue2", location_path, "org.freedesktop.DBus.Properties", "GetAll",
                        new Variant ("(s)", "org.freedesktop.GeoClue2.Location"), new VariantType ("(a{sv})"), DBusCallFlags.NONE, 5000, null, (o, res) => {
                            try {
                                var props = bus.call.end (res).get_child_value (0);
                                r_lat = props.lookup_value ("Latitude", VariantType.DOUBLE).get_double ();
                                r_lon = props.lookup_value ("Longitude", VariantType.DOUBLE).get_double ();
                                r_acc = props.lookup_value ("Accuracy", VariantType.DOUBLE).get_double ();
                            } catch (Error e) {
                                failure = e;
                            }
                            if (!done) {
                                done = true;
                                Idle.add ((owned) callback);
                            }
                        });
                });
            bool timed_out = false;
            var timeout = Timeout.add_seconds (20, () => {
                timed_out = true;
                if (!done) {
                    done = true;
                    failure = new IOError.TIMED_OUT (_("Your location could not be found."));
                    Idle.add ((owned) callback);
                }
                return Source.REMOVE;
            });
            yield bus.call ("org.freedesktop.GeoClue2", client_path, "org.freedesktop.GeoClue2.Client", "Start", null, null, DBusCallFlags.NONE, 10000);
            yield;
            if (subscription != 0) bus.signal_unsubscribe (subscription);
            subscription = 0;
            bus.call.begin ("org.freedesktop.GeoClue2", client_path, "org.freedesktop.GeoClue2.Client", "Stop", null, null, DBusCallFlags.NONE, 5000, null);
            if (!timed_out) Source.remove (timeout);
            if (failure != null) throw failure;
            lat = r_lat;
            lon = r_lon;
            accuracy = r_acc;
        }

        private async void set_prop (string name, Variant value) throws Error {
            yield bus.call ("org.freedesktop.GeoClue2", client_path, "org.freedesktop.DBus.Properties", "Set",
                new Variant ("(ssv)", "org.freedesktop.GeoClue2.Client", name, value), null, DBusCallFlags.NONE, 5000);
        }
    }
}
