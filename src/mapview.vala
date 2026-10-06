using Gtk;

namespace Singularity.Apps.Maps {

    public class TileSource : Object {
        public string id;
        public string name;
        public string url;
        public string attribution;
        public int max_zoom;

        public TileSource (string id, string name, string url, string attribution, int max_zoom) {
            this.id = id;
            this.name = name;
            this.url = url;
            this.attribution = attribution;
            this.max_zoom = max_zoom;
        }

        public static TileSource[] all () {
            return {
                new TileSource ("osm", _("Map"), "https://tile.openstreetmap.org/{z}/{x}/{y}.png", "© OpenStreetMap contributors", 19),
                new TileSource ("topo", _("Terrain"), "https://tile.opentopomap.org/{z}/{x}/{y}.png", "© OpenStreetMap contributors, SRTM · © OpenTopoMap (CC-BY-SA)", 17),
                new TileSource ("cycle", _("Transport"), "https://tile.memomaps.de/tilegen/{z}/{x}/{y}.png", "© OpenStreetMap contributors · © MeMoMaps", 18)
            };
        }
    }

    public class TileCache : Object {
        private Soup.Session session;
        private Gee.HashMap<string, Gdk.Texture> memory = new Gee.HashMap<string, Gdk.Texture> ();
        private Gee.LinkedList<string> order = new Gee.LinkedList<string> ();
        private Gee.HashSet<string> pending = new Gee.HashSet<string> ();
        private Gee.HashSet<string> failed = new Gee.HashSet<string> ();
        private Gee.LinkedList<string> queue = new Gee.LinkedList<string> ();
        private int active;
        private string dir;
        public TileSource source;

        public signal void tile_ready ();

        public TileCache (TileSource source) {
            this.source = source;
            session = (Soup.Session) Object.new (typeof (Soup.Session), "max-conns", 8, "user-agent", "SingularityMaps/0.1 (+https://github.com/singularityos-lab)");
            dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity-maps", "tiles");
        }

        public void set_source (TileSource s) {
            source = s;
            memory.clear ();
            order.clear ();
            queue.clear ();
            failed.clear ();
        }

        private string key (int z, int x, int y) {
            return "%s/%d/%d/%d".printf (source.id, z, x, y);
        }

        public Gdk.Texture? peek (int z, int x, int y) {
            return memory[key (z, x, y)];
        }

        public Gdk.Texture? get_tile (int z, int x, int y) {
            string k = key (z, x, y);
            var t = memory[k];
            if (t != null) {
                order.remove (k);
                order.add (k);
                return t;
            }
            if (!pending.contains (k) && !failed.contains (k)) {
                pending.add (k);
                queue.add (k);
                pump ();
            }
            return null;
        }

        public void reset_queue () {
            foreach (string k in queue) pending.remove (k);
            queue.clear ();
        }

        private void remember (string k, Gdk.Texture t) {
            memory[k] = t;
            order.add (k);
            while (order.size > 600) {
                string old = order.poll_head ();
                memory.unset (old);
            }
        }

        private void pump () {
            while (active < 6 && queue.size > 0) {
                string k = queue.poll_tail ();
                active++;
                fetch.begin (k, (o, r) => {
                    fetch.end (r);
                    active--;
                    pump ();
                });
            }
        }

        private async void fetch (string k) {
            string[] p = k.split ("/");
            string path = Path.build_filename (dir, p[0], p[1], p[2], p[3] + ".png");
            var file = File.new_for_path (path);
            try {
                var info = yield file.query_info_async ("time::modified", FileQueryInfoFlags.NONE);
                var age = new DateTime.now_utc ().difference (info.get_modification_date_time ());
                var bytes = (yield file.load_bytes_async (null, null));
                var tex = Gdk.Texture.from_bytes (bytes);
                remember (k, tex);
                pending.remove (k);
                tile_ready ();
                if (age < TimeSpan.DAY * 7) return;
            } catch (Error e) {
            }
            string url = source.url.replace ("{z}", p[1]).replace ("{x}", p[2]).replace ("{y}", p[3]);
            try {
                var msg = new Soup.Message ("GET", url);
                var bytes = yield session.send_and_read_async (msg, Priority.LOW, null);
                if (msg.status_code != 200) {
                    failed.add (k);
                    pending.remove (k);
                    return;
                }
                var tex = Gdk.Texture.from_bytes (bytes);
                remember (k, tex);
                DirUtils.create_with_parents (Path.get_dirname (path), 0755);
                yield file.replace_contents_async (bytes.get_data (), null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
                tile_ready ();
            } catch (Error e) {
            }
            pending.remove (k);
        }
    }

    public class MapView : Widget {
        public double zoom { get; private set; default = 3; }
        public double center_x;
        public double center_y;
        public TileCache tiles;
        public Place? pin;
        public double[]? route;
        public double location_lat = double.NAN;
        public double location_lon = double.NAN;
        public double location_accuracy;
        public Gee.ArrayList<Place> markers = new Gee.ArrayList<Place> ();

        private double drag_cx;
        private double drag_cy;
        private double vx;
        private double vy;
        private int64 last_motion;
        private double last_dx;
        private double last_dy;
        private uint kinetic_id;
        private uint zoom_anim;
        private double pointer_x;
        private double pointer_y;

        public signal void point_selected (double lat, double lon, double x, double y);
        public signal void marker_selected (Place place);
        public signal void moved ();

        public MapView (TileSource source) {
            add_css_class ("maps-view");
            focusable = true;
            tiles = new TileCache (source);
            tiles.tile_ready.connect (() => queue_draw ());
            set_center (41.9, 12.5, 5);
            var drag = new GestureDrag ();
            drag.drag_begin.connect ((x, y) => {
                stop_kinetic ();
                drag_cx = center_x;
                drag_cy = center_y;
                last_motion = get_monotonic_time ();
                last_dx = last_dy = 0;
                vx = vy = 0;
                grab_focus ();
            });
            drag.drag_update.connect ((dx, dy) => {
                int64 now = get_monotonic_time ();
                double dt = (now - last_motion) / 1000000.0;
                if (dt > 0) {
                    vx = vx * 0.3 + ((dx - last_dx) / dt) * 0.7;
                    vy = vy * 0.3 + ((dy - last_dy) / dt) * 0.7;
                }
                last_motion = now;
                last_dx = dx;
                last_dy = dy;
                center_x = drag_cx - dx;
                center_y = drag_cy - dy;
                wrap ();
                queue_draw ();
                moved ();
            });
            drag.drag_end.connect ((dx, dy) => {
                if ((get_monotonic_time () - last_motion) > 80000) return;
                if (Math.fabs (vx) + Math.fabs (vy) > 200) start_kinetic ();
            });
            add_controller (drag);
            var click = new GestureClick ();
            click.button = 0;
            click.released.connect ((n, x, y) => {
                if (Math.fabs (last_dx) + Math.fabs (last_dy) > 4) {
                    last_dx = last_dy = 0;
                    return;
                }
                if (n == 2 && click.get_current_button () == Gdk.BUTTON_PRIMARY) {
                    animate_zoom (Math.round (zoom) + 1, x, y);
                    return;
                }
                foreach (var m in markers) {
                    double mx, my;
                    to_screen (m.lat, m.lon, out mx, out my);
                    if (Math.fabs (x - mx) < 14 && y > my - 34 && y < my + 4) {
                        marker_selected (m);
                        return;
                    }
                }
                if (click.get_current_button () == Gdk.BUTTON_SECONDARY || n == 1) {
                    double lat, lon;
                    to_geo (x, y, out lat, out lon);
                    if (click.get_current_button () == Gdk.BUTTON_SECONDARY) point_selected (lat, lon, x, y);
                }
            });
            add_controller (click);
            var press = new GestureLongPress ();
            press.pressed.connect ((x, y) => {
                double lat, lon;
                to_geo (x, y, out lat, out lon);
                point_selected (lat, lon, x, y);
            });
            add_controller (press);
            var scroll = new EventControllerScroll (EventControllerScrollFlags.VERTICAL | EventControllerScrollFlags.DISCRETE);
            scroll.scroll.connect ((dx, dy) => {
                stop_kinetic ();
                animate_zoom (Math.round (zoom) + (dy < 0 ? 1 : -1), pointer_x, pointer_y);
                return true;
            });
            add_controller (scroll);
            var smooth = new EventControllerScroll (EventControllerScrollFlags.BOTH_AXES);
            smooth.scroll.connect ((dx, dy) => {
                if (smooth.get_unit () == Gdk.ScrollUnit.WHEEL) return false;
                set_zoom_at (zoom - dy * 0.01, pointer_x, pointer_y);
                return true;
            });
            add_controller (smooth);
            var motion = new EventControllerMotion ();
            motion.motion.connect ((x, y) => {
                pointer_x = x;
                pointer_y = y;
            });
            add_controller (motion);
            var pinch = new GestureZoom ();
            double start = 0;
            pinch.begin.connect (() => start = zoom);
            pinch.scale_changed.connect ((s) => {
                double cx, cy;
                pinch.get_bounding_box_center (out cx, out cy);
                set_zoom_at (start + Math.log2 (s), cx, cy);
            });
            add_controller (pinch);
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                double step = 120;
                switch (keyval) {
                    case Gdk.Key.Left: pan (-step, 0); return true;
                    case Gdk.Key.Right: pan (step, 0); return true;
                    case Gdk.Key.Up: pan (0, -step); return true;
                    case Gdk.Key.Down: pan (0, step); return true;
                    case Gdk.Key.plus:
                    case Gdk.Key.equal:
                    case Gdk.Key.KP_Add:
                        zoom_in ();
                        return true;
                    case Gdk.Key.minus:
                    case Gdk.Key.KP_Subtract:
                        zoom_out ();
                        return true;
                }
                return false;
            });
            add_controller (keys);
        }

        public override void measure (Orientation o, int for_size, out int minimum, out int natural, out int mb, out int nb) {
            minimum = 100;
            natural = 800;
            mb = nb = -1;
        }

        private void pan (double dx, double dy) {
            center_x += dx;
            center_y += dy;
            wrap ();
            queue_draw ();
            moved ();
        }

        private void wrap () {
            double world = TILE * Math.pow (2, zoom);
            center_x = ((center_x % world) + world) % world;
            center_y = center_y.clamp (0, world);
        }

        private void stop_kinetic () {
            if (kinetic_id != 0) remove_tick_callback (kinetic_id);
            kinetic_id = 0;
        }

        private void start_kinetic () {
            stop_kinetic ();
            int64 prev = get_monotonic_time ();
            kinetic_id = add_tick_callback ((w, clock) => {
                int64 now = clock.get_frame_time ();
                double dt = (now - prev) / 1000000.0;
                prev = now;
                center_x -= vx * dt;
                center_y -= vy * dt;
                double decay = Math.pow (0.04, dt);
                vx *= decay;
                vy *= decay;
                wrap ();
                queue_draw ();
                moved ();
                if (Math.fabs (vx) + Math.fabs (vy) < 20) {
                    kinetic_id = 0;
                    return Source.REMOVE;
                }
                return Source.CONTINUE;
            });
        }

        public void set_center (double lat, double lon, double z) {
            zoom = z.clamp (1, tiles.source.max_zoom);
            center_x = Geo.lon_to_x (lon, zoom);
            center_y = Geo.lat_to_y (lat, zoom);
            queue_draw ();
            moved ();
        }

        public void fly_to (double lat, double lon, double z) {
            stop_kinetic ();
            if (zoom_anim != 0) remove_tick_callback (zoom_anim);
            double z0 = zoom;
            double lat0, lon0;
            center (out lat0, out lon0);
            double z1 = z.clamp (1, tiles.source.max_zoom);
            int64 start = -1;
            zoom_anim = add_tick_callback ((w, clock) => {
                if (start < 0) start = clock.get_frame_time ();
                double t = double.min (1, (clock.get_frame_time () - start) / 450000.0);
                double e = t < 0.5 ? 2 * t * t : 1 - Math.pow (-2 * t + 2, 2) / 2;
                double zz = z0 + (z1 - z0) * e;
                double la = lat0 + (lat - lat0) * e;
                double lo = lon0 + (lon - lon0) * e;
                zoom = zz;
                center_x = Geo.lon_to_x (lo, zoom);
                center_y = Geo.lat_to_y (la, zoom);
                queue_draw ();
                moved ();
                if (t >= 1) {
                    zoom_anim = 0;
                    return Source.REMOVE;
                }
                return Source.CONTINUE;
            });
        }

        public double left_inset;

        public void fit (double south, double west, double north, double east) {
            double w = double.max (get_width () - left_inset, 300), h = double.max (get_height (), 300);
            double z = double.min (tiles.source.max_zoom, 18);
            while (z > 1) {
                double dx = Geo.lon_to_x (east, z) - Geo.lon_to_x (west, z);
                double dy = Geo.lat_to_y (south, z) - Geo.lat_to_y (north, z);
                if (dx < w * 0.8 && dy < h * 0.7) break;
                z -= 0.25;
            }
            z = Math.floor (z * 4) / 4;
            double cx = (Geo.lon_to_x (west, z) + Geo.lon_to_x (east, z)) / 2 - left_inset / 2;
            double cy = (Geo.lat_to_y (south, z) + Geo.lat_to_y (north, z)) / 2;
            fly_to (Geo.y_to_lat (cy, z), Geo.x_to_lon (cx, z), z);
        }

        public void center (out double lat, out double lon) {
            lat = Geo.y_to_lat (center_y, zoom);
            lon = Geo.x_to_lon (center_x, zoom);
        }

        public void to_geo (double x, double y, out double lat, out double lon) {
            double wx = center_x + x - get_width () / 2.0;
            double wy = center_y + y - get_height () / 2.0;
            lat = Geo.y_to_lat (wy, zoom);
            lon = Geo.x_to_lon (wx, zoom);
            while (lon < -180) lon += 360;
            while (lon > 180) lon -= 360;
        }

        public void to_screen (double lat, double lon, out double x, out double y) {
            double world = TILE * Math.pow (2, zoom);
            double wx = Geo.lon_to_x (lon, zoom);
            double dx = wx - center_x;
            if (dx > world / 2) dx -= world;
            if (dx < -world / 2) dx += world;
            x = get_width () / 2.0 + dx;
            y = get_height () / 2.0 + Geo.lat_to_y (lat, zoom) - center_y;
        }

        public void set_zoom_at (double z, double x, double y) {
            double nz = z.clamp (1, tiles.source.max_zoom);
            if (nz == zoom) return;
            double lat, lon;
            to_geo (x, y, out lat, out lon);
            zoom = nz;
            double wx = Geo.lon_to_x (lon, zoom);
            double wy = Geo.lat_to_y (lat, zoom);
            center_x = wx - (x - get_width () / 2.0);
            center_y = wy - (y - get_height () / 2.0);
            wrap ();
            queue_draw ();
            moved ();
        }

        public void animate_zoom (double target, double x, double y) {
            double t1 = target.clamp (1, tiles.source.max_zoom);
            if (zoom_anim != 0) remove_tick_callback (zoom_anim);
            double z0 = zoom;
            int64 start = -1;
            zoom_anim = add_tick_callback ((w, clock) => {
                if (start < 0) start = clock.get_frame_time ();
                double t = double.min (1, (clock.get_frame_time () - start) / 220000.0);
                double e = 1 - Math.pow (1 - t, 3);
                set_zoom_at (z0 + (t1 - z0) * e, x, y);
                if (t >= 1) {
                    zoom_anim = 0;
                    return Source.REMOVE;
                }
                return Source.CONTINUE;
            });
        }

        public void zoom_in () {
            animate_zoom (Math.round (zoom) + 1, get_width () / 2.0, get_height () / 2.0);
        }

        public void zoom_out () {
            animate_zoom (Math.round (zoom) - 1, get_width () / 2.0, get_height () / 2.0);
        }

        public void set_source (TileSource s) {
            tiles.set_source (s);
            if (zoom > s.max_zoom) set_zoom_at (s.max_zoom, get_width () / 2.0, get_height () / 2.0);
            queue_draw ();
        }

        public override void snapshot (Snapshot snap) {
            int w = get_width (), h = get_height ();
            var bg = Gdk.RGBA ();
            bg.parse ("#e8e4dc");
            snap.append_color (bg, Graphene.Rect ().init (0, 0, w, h));
            int z = (int) Math.floor (zoom + 0.0001);
            z = z.clamp (0, tiles.source.max_zoom);
            double scale = Math.pow (2, zoom - z);
            double cx = center_x / scale, cy = center_y / scale;
            double tsize = TILE * scale;
            int n = 1 << z;
            double left = cx - w / 2.0 / scale;
            double top = cy - h / 2.0 / scale;
            int tx1 = (int) Math.floor (left / TILE);
            int ty1 = (int) Math.floor (top / TILE);
            int tx2 = (int) Math.floor ((left + w / scale) / TILE);
            int ty2 = (int) Math.floor ((top + h / scale) / TILE);
            tiles.reset_queue ();
            double ccx = (tx1 + tx2) / 2.0, ccy = (ty1 + ty2) / 2.0;
            var order = new Gee.ArrayList<int> ();
            for (int ty = ty1; ty <= ty2; ty++) for (int tx = tx1; tx <= tx2; tx++) order.add ((ty - ty1) * 1000 + (tx - tx1));
            order.sort ((a, b) => {
                double da = Math.pow (a % 1000 + tx1 - ccx, 2) + Math.pow (a / 1000 + ty1 - ccy, 2);
                double db = Math.pow (b % 1000 + tx1 - ccx, 2) + Math.pow (b / 1000 + ty1 - ccy, 2);
                return da < db ? 1 : (da > db ? -1 : 0);
            });
            foreach (int code in order) {
                int ty = ty1 + code / 1000;
                int tx = tx1 + code % 1000;
                if (ty < 0 || ty >= n) continue;
                int wx = ((tx % n) + n) % n;
                double sx = (tx * TILE - left) * scale;
                double sy = (ty * TILE - top) * scale;
                var rect = Graphene.Rect ().init ((float) Math.floor (sx), (float) Math.floor (sy), (float) Math.ceil (tsize + 0.5), (float) Math.ceil (tsize + 0.5));
                var tex = tiles.get_tile (z, wx, ty);
                if (tex != null) {
                    snap.append_scaled_texture (tex, Gsk.ScalingFilter.LINEAR, rect);
                    continue;
                }
                for (int up = 1; up <= 4 && z - up >= 0; up++) {
                    int f = 1 << up;
                    var parent = tiles.peek (z - up, wx / f, ty / f);
                    if (parent == null) continue;
                    double sub = TILE / (double) f;
                    double ox = (wx % f) * sub, oy = (ty % f) * sub;
                    snap.save ();
                    snap.push_clip (rect);
                    var big = Graphene.Rect ().init ((float) (rect.origin.x - ox * tsize / sub), (float) (rect.origin.y - oy * tsize / sub), (float) (tsize * f), (float) (tsize * f));
                    snap.append_scaled_texture (parent, Gsk.ScalingFilter.LINEAR, big);
                    snap.pop ();
                    snap.restore ();
                    break;
                }
            }
            var cr = snap.append_cairo (Graphene.Rect ().init (0, 0, w, h));
            draw_overlay (cr, w, h);
        }

        private void draw_overlay (Cairo.Context cr, int w, int h) {
            var accent = Gdk.RGBA ();
            if (!get_style_context ().lookup_color ("accent_bg_color", out accent)) accent.parse ("#3584e4");
            if (route != null && route.length >= 4) {
                cr.new_path ();
                for (int i = 0; i + 1 < route.length; i += 2) {
                    double x, y;
                    to_screen (route[i], route[i + 1], out x, out y);
                    if (i == 0) cr.move_to (x, y);
                    else cr.line_to (x, y);
                }
                cr.set_line_join (Cairo.LineJoin.ROUND);
                cr.set_line_cap (Cairo.LineCap.ROUND);
                cr.set_source_rgba (1, 1, 1, 0.9);
                cr.set_line_width (9);
                cr.stroke_preserve ();
                cr.set_source_rgba (accent.red * 0.85, accent.green * 0.85, accent.blue * 0.85, 1);
                cr.set_line_width (6);
                cr.stroke ();
                double x, y;
                to_screen (route[0], route[1], out x, out y);
                cr.arc (x, y, 6, 0, 2 * Math.PI);
                cr.set_source_rgb (1, 1, 1);
                cr.fill_preserve ();
                cr.set_source_rgba (accent.red, accent.green, accent.blue, 1);
                cr.set_line_width (3);
                cr.stroke ();
            }
            if (!location_lat.is_nan ()) {
                double x, y;
                to_screen (location_lat, location_lon, out x, out y);
                double r = location_accuracy / Geo.meters_per_pixel (location_lat, zoom);
                if (r > 12) {
                    cr.arc (x, y, double.min (r, 2000), 0, 2 * Math.PI);
                    cr.set_source_rgba (accent.red, accent.green, accent.blue, 0.15);
                    cr.fill ();
                }
                cr.arc (x, y, 9, 0, 2 * Math.PI);
                cr.set_source_rgb (1, 1, 1);
                cr.fill ();
                cr.arc (x, y, 6, 0, 2 * Math.PI);
                cr.set_source_rgba (accent.red, accent.green, accent.blue, 1);
                cr.fill ();
            }
            foreach (var m in markers) draw_pin (cr, m, false, accent);
            if (pin != null) draw_pin (cr, pin, true, accent);
            draw_scale (cr, w, h);
        }

        private void draw_pin (Cairo.Context cr, Place p, bool big, Gdk.RGBA accent) {
            double x, y;
            to_screen (p.lat, p.lon, out x, out y);
            double r = big ? 12 : 8;
            double tip = big ? 32 : 22;
            cr.save ();
            cr.translate (x, y);
            cr.move_to (0, 0);
            cr.curve_to (-r * 0.4, -tip * 0.45, -r, -tip + r * 1.1, -r, -tip + r);
            cr.arc (0, -tip + r, r, Math.PI, 2 * Math.PI);
            cr.curve_to (r, -tip + r * 1.1, r * 0.4, -tip * 0.45, 0, 0);
            cr.close_path ();
            cr.set_source_rgba (0, 0, 0, 0.25);
            cr.save ();
            cr.translate (1, 2);
            cr.fill_preserve ();
            cr.restore ();
            cr.new_path ();
            cr.move_to (0, 0);
            cr.curve_to (-r * 0.4, -tip * 0.45, -r, -tip + r * 1.1, -r, -tip + r);
            cr.arc (0, -tip + r, r, Math.PI, 2 * Math.PI);
            cr.curve_to (r, -tip + r * 1.1, r * 0.4, -tip * 0.45, 0, 0);
            cr.close_path ();
            if (big) cr.set_source_rgb (0.88, 0.11, 0.14);
            else cr.set_source_rgba (accent.red, accent.green, accent.blue, 1);
            cr.fill_preserve ();
            cr.set_source_rgba (1, 1, 1, 0.9);
            cr.set_line_width (1.5);
            cr.stroke ();
            cr.arc (0, -tip + r, r * 0.38, 0, 2 * Math.PI);
            cr.set_source_rgb (1, 1, 1);
            cr.fill ();
            cr.restore ();
        }

        private void draw_scale (Cairo.Context cr, int w, int h) {
            double lat, lon;
            center (out lat, out lon);
            double mpp = Geo.meters_per_pixel (lat, zoom);
            bool metric = Geo.metric ();
            double unit = metric ? 1 : 0.3048;
            double target = 110 * mpp / unit;
            double mag = Math.pow (10, Math.floor (Math.log10 (target)));
            double nice = target / mag >= 5 ? 5 * mag : (target / mag >= 2 ? 2 * mag : mag);
            if (!metric && nice >= 5280) nice = Math.round (nice / 5280) * 5280;
            double px = nice * unit / mpp;
            double x0 = 16, y0 = h - 22;
            cr.set_source_rgba (1, 1, 1, 0.8);
            cr.rectangle (x0 - 6, y0 - 16, px + 12, 24);
            cr.fill ();
            cr.set_source_rgba (0.2, 0.2, 0.2, 1);
            cr.set_line_width (2);
            cr.move_to (x0, y0 - 4);
            cr.line_to (x0, y0);
            cr.line_to (x0 + px, y0);
            cr.line_to (x0 + px, y0 - 4);
            cr.stroke ();
            var layout = create_pango_layout (metric ? Geo.format_distance (nice) : (nice >= 5280 ? _("%d mi").printf ((int) (nice / 5280)) : _("%d ft").printf ((int) nice)));
            var fd = new Pango.FontDescription ();
            fd.set_family ("Sans");
            fd.set_absolute_size (10.5 * Pango.SCALE);
            layout.set_font_description (fd);
            cr.move_to (x0 + 2, y0 - 16);
            Pango.cairo_show_layout (cr, layout);
        }
    }
}
