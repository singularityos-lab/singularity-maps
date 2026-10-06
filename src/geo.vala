namespace Singularity.Apps.Maps {

    public const int TILE = 256;
    public const int MAX_ZOOM = 19;

    public class Geo {
        public static double lon_to_x (double lon, double zoom) {
            return (lon + 180.0) / 360.0 * TILE * Math.pow (2, zoom);
        }

        public static double lat_to_y (double lat, double zoom) {
            double l = lat.clamp (-85.05112878, 85.05112878) * Math.PI / 180.0;
            return (1 - Math.log (Math.tan (l) + 1 / Math.cos (l)) / Math.PI) / 2 * TILE * Math.pow (2, zoom);
        }

        public static double x_to_lon (double x, double zoom) {
            return x / (TILE * Math.pow (2, zoom)) * 360.0 - 180.0;
        }

        public static double y_to_lat (double y, double zoom) {
            double n = Math.PI - 2 * Math.PI * y / (TILE * Math.pow (2, zoom));
            return 180.0 / Math.PI * Math.atan (0.5 * (Math.exp (n) - Math.exp (-n)));
        }

        public static double distance (double lat1, double lon1, double lat2, double lon2) {
            double r = 6371008.8;
            double p1 = lat1 * Math.PI / 180, p2 = lat2 * Math.PI / 180;
            double dp = (lat2 - lat1) * Math.PI / 180, dl = (lon2 - lon1) * Math.PI / 180;
            double a = Math.sin (dp / 2) * Math.sin (dp / 2) + Math.cos (p1) * Math.cos (p2) * Math.sin (dl / 2) * Math.sin (dl / 2);
            return 2 * r * Math.atan2 (Math.sqrt (a), Math.sqrt (1 - a));
        }

        public static double meters_per_pixel (double lat, double zoom) {
            return 156543.03392 * Math.cos (lat * Math.PI / 180) / Math.pow (2, zoom);
        }

        public static bool metric () {
            string? loc = null;
            foreach (string v in new string[] { "LC_ALL", "LC_MEASUREMENT", "LANG" }) {
                string? e = Environment.get_variable (v);
                if (e != null && e != "") {
                    loc = e;
                    break;
                }
            }
            if (loc == null) return true;
            string l = loc.down ();
            return !(l.has_prefix ("en_us") || l.has_prefix ("en_lr") || l.has_prefix ("my_mm"));
        }

        public static string format_distance (double meters) {
            if (metric ()) {
                if (meters < 1000) return _("%d m").printf ((int) (Math.round (meters / 10) * 10));
                if (meters < 10000) return _("%s km").printf (dec (meters / 1000, 1));
                return _("%d km").printf ((int) Math.round (meters / 1000));
            }
            double feet = meters * 3.28084;
            if (feet < 1000) return _("%d ft").printf ((int) (Math.round (feet / 10) * 10));
            double miles = meters / 1609.344;
            if (miles < 10) return _("%s mi").printf (dec (miles, 1));
            return _("%d mi").printf ((int) Math.round (miles));
        }

        private static string dec (double v, int digits) {
            char[] buf = new char[32];
            string s = v.format (buf, "%." + digits.to_string () + "f");
            string? point = Posix.nl_langinfo (Posix.NLItem.RADIXCHAR);
            return point != null && point != "." ? s.replace (".", point) : s;
        }

        public static string format_duration (double seconds) {
            int mins = (int) Math.round (seconds / 60);
            if (mins < 1) return _("less than a minute");
            if (mins < 60) return ngettext ("%d minute", "%d minutes", mins).printf (mins);
            int h = mins / 60, m = mins % 60;
            if (m == 0) return ngettext ("%d hour", "%d hours", h).printf (h);
            return _("%d h %d min").printf (h, m);
        }

        public static string format_coords (double lat, double lon) {
            char[] b1 = new char[32];
            char[] b2 = new char[32];
            return "%s, %s".printf (lat.format (b1, "%.5f"), lon.format (b2, "%.5f"));
        }

        public static bool parse_coords (string text, out double lat, out double lon) {
            lat = lon = 0;
            string t = text.strip ().replace (";", ",");
            string[] parts = t.split (",");
            if (parts.length != 2) {
                parts = t.split (" ");
                string[] cleaned = {};
                foreach (string p in parts) if (p.strip () != "") cleaned += p.strip ();
                parts = cleaned;
                if (parts.length != 2) return false;
            }
            double a = 0, b = 0;
            if (!double.try_parse (parts[0].strip (), out a) || !double.try_parse (parts[1].strip (), out b)) return false;
            if (a < -90 || a > 90 || b < -180 || b > 180) return false;
            lat = a;
            lon = b;
            return true;
        }
    }

    public class Place : Object {
        public string name = "";
        public string detail = "";
        public string category = "";
        public double lat;
        public double lon;
        public string osm_type = "";
        public int64 osm_id;
        public double[]? extent;

        public Place (string name, string detail, double lat, double lon) {
            this.name = name;
            this.detail = detail;
            this.lat = lat;
            this.lon = lon;
        }

        public string key () {
            return osm_id != 0 ? "%s%lld".printf (osm_type, osm_id) : Geo.format_coords (lat, lon);
        }

        public Json.Node to_json () {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("name").add_string_value (name);
            b.set_member_name ("detail").add_string_value (detail);
            b.set_member_name ("category").add_string_value (category);
            b.set_member_name ("lat").add_double_value (lat);
            b.set_member_name ("lon").add_double_value (lon);
            b.set_member_name ("osm_type").add_string_value (osm_type);
            b.set_member_name ("osm_id").add_int_value (osm_id);
            b.end_object ();
            return b.get_root ();
        }

        public static Place from_json (Json.Object o) {
            var p = new Place (o.get_string_member_with_default ("name", ""), o.get_string_member_with_default ("detail", ""),
                o.get_double_member_with_default ("lat", 0), o.get_double_member_with_default ("lon", 0));
            p.category = o.get_string_member_with_default ("category", "");
            p.osm_type = o.get_string_member_with_default ("osm_type", "");
            p.osm_id = o.get_int_member_with_default ("osm_id", 0);
            return p;
        }
    }
}
