using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Maps {

    public class MapsWindow : Singularity.Widgets.Window {
        private MapsApp app;
        private MapView map;
        private Overlay overlay;
        private Box panel;
        private Revealer panel_reveal;
        private SearchBubble search;
        private Label attribution;
        private Favorites favorites;
        private Button fav_bubble;
        private Button layers_bubble;
        private Button locate_bubble;
        private Place? origin;
        private Place? destination;
        private Mode mode = Mode.CAR;
        private Route? route;
        private int search_serial;
        private double located_lat = double.NAN;
        private double located_lon = double.NAN;
        private KeyFile state = new KeyFile ();
        private string state_path;

        public MapsWindow (MapsApp app) {
            Object (application: app);
            this.app = app;
            set_default_size (1180, 800);
            set_title (_("Maps"));
            favorites = app.favorites;
            state_path = Path.build_filename (Environment.get_user_config_dir (), "singularity", "maps.ini");
            var sources = TileSource.all ();
            string layer = "osm";
            try {
                state.load_from_file (state_path, KeyFileFlags.NONE);
                layer = state.get_string ("View", "layer");
            } catch (Error e) {
            }
            TileSource source = sources[0];
            foreach (var s in sources) if (s.id == layer) source = s;
            map = new MapView (source);
            map.hexpand = true;
            map.vexpand = true;
            try {
                map.set_center (state.get_double ("View", "lat"), state.get_double ("View", "lon"), state.get_double ("View", "zoom"));
            } catch (Error e) {
                map.set_center (45.4642, 9.19, 5);
            }
            overlay = new Overlay ();
            overlay.child = map;
            overlay.add_css_class ("maps-overlay");

            panel = new Box (Orientation.VERTICAL, 10);
            panel.add_css_class ("maps-panel-body");
            var panel_scroll = new ScrolledWindow ();
            panel_scroll.hscrollbar_policy = PolicyType.NEVER;
            panel_scroll.propagate_natural_height = true;
            panel_scroll.max_content_height = 560;
            panel_scroll.add_css_class ("maps-panel-scroll");
            panel_scroll.child = panel;
            var card = new Box (Orientation.VERTICAL, 0);
            card.add_css_class ("maps-panel");
            card.overflow = Overflow.HIDDEN;
            card.append (panel_scroll);
            var shadow_room = new Box (Orientation.VERTICAL, 0);
            shadow_room.add_css_class ("maps-panel-room");
            shadow_room.append (card);
            panel_reveal = new Revealer ();
            panel_reveal.transition_type = RevealerTransitionType.CROSSFADE;
            panel_reveal.child = shadow_room;
            panel_reveal.halign = Align.START;
            panel_reveal.valign = Align.START;
            panel_reveal.margin_start = 4;
            Singularity.Widgets.apply_titlebar_inset (panel_reveal);
            panel_reveal.set_size_request (380, -1);
            overlay.add_overlay (panel_reveal);

            var zoom_box = new Box (Orientation.VERTICAL, 8);
            zoom_box.add_css_class ("maps-zoom");
            zoom_box.halign = Align.END;
            zoom_box.valign = Align.END;
            zoom_box.margin_end = 14;
            zoom_box.margin_bottom = 40;
            var zin = new Button.from_icon_name ("zoom-in-symbolic");
            zin.add_css_class ("singularity-hover-btn");
            zin.tooltip_text = _("Zoom In");
            zin.clicked.connect (() => map.zoom_in ());
            var zout = new Button.from_icon_name ("zoom-out-symbolic");
            zout.add_css_class ("singularity-hover-btn");
            zout.tooltip_text = _("Zoom Out");
            zout.clicked.connect (() => map.zoom_out ());
            zoom_box.append (zin);
            zoom_box.append (zout);
            overlay.add_overlay (zoom_box);

            attribution = new Label ("");
            attribution.add_css_class ("maps-attribution");
            attribution.halign = Align.END;
            attribution.valign = Align.END;
            attribution.use_markup = true;
            attribution.activate_link.connect ((uri) => {
                new UriLauncher (uri).launch.begin (this, null);
                return true;
            });
            overlay.add_overlay (attribution);
            update_attribution ();
            set_content (overlay);

            search = add_bubble_search (_("Search for a Place"), (t) => { });
            search.entry.activate.connect (() => run_search (search.text));
            search.entry.search_changed.connect (() => {
                if (search.text.strip ().length >= 3) run_search (search.text, true);
                else if (search.text.strip () == "") hide_panel ();
            });
            locate_bubble = add_bubble_icon ("find-location-symbolic", _("Show My Location"), () => locate ());
            add_bubble_icon ("maps-directions-symbolic", _("Directions"), () => open_route (null, null));
            fav_bubble = add_bubble_icon ("starred-symbolic", _("Favorite Places"), () => show_favorites ());
            layers_bubble = add_bubble_icon ("maps-layers-symbolic", _("Map Type"), () => show_layers ());
            install_actions ();

            map.point_selected.connect ((lat, lon, x, y) => what_is_here (lat, lon));
            map.marker_selected.connect ((p) => show_place (p, false));
            map.moved.connect (schedule_save);
            close_request.connect (() => {
                save_state ();
                return false;
            });
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, st) => {
                bool ctrl = (st & Gdk.ModifierType.CONTROL_MASK) != 0;
                if (ctrl && keyval == Gdk.Key.f) {
                    search.grab_focus_entry ();
                    return true;
                }
                if (keyval == Gdk.Key.Escape && panel_reveal.reveal_child) {
                    hide_panel ();
                    return true;
                }
                return false;
            });
            ((Widget) this).add_controller (keys);
            map.grab_focus ();
        }

        private SimpleAction copy_coords_action;
        private SimpleAction copy_link_action;
        private SimpleAction layer_action;

        private void install_actions () {
            var close_action = new SimpleAction ("close", null);
            close_action.activate.connect (() => close ());
            add_action (close_action);
            var find = new SimpleAction ("find", null);
            find.activate.connect (() => search.grab_focus_entry ());
            add_action (find);
            copy_coords_action = new SimpleAction ("copy-coordinates", null);
            copy_coords_action.activate.connect (() => {
                if (map.pin != null) get_clipboard ().set_text (Geo.format_coords (map.pin.lat, map.pin.lon));
            });
            add_action (copy_coords_action);
            copy_link_action = new SimpleAction ("copy-link", null);
            copy_link_action.activate.connect (() => {
                if (map.pin == null) return;
                char[] b1 = new char[32];
                char[] b2 = new char[32];
                string lat = map.pin.lat.format (b1, "%.6f");
                string lon = map.pin.lon.format (b2, "%.6f");
                get_clipboard ().set_text ("https://www.openstreetmap.org/?mlat=%s&mlon=%s#map=17/%s/%s".printf (lat, lon, lat, lon));
            });
            add_action (copy_link_action);
            update_place_actions ();
            var zin = new SimpleAction ("zoom-in", null);
            zin.activate.connect (() => map.zoom_in ());
            add_action (zin);
            var zout = new SimpleAction ("zoom-out", null);
            zout.activate.connect (() => map.zoom_out ());
            add_action (zout);
            layer_action = new SimpleAction.stateful ("layer", VariantType.STRING, new Variant.string (map.tiles.source.id));
            layer_action.activate.connect ((param) => {
                foreach (var s in TileSource.all ()) {
                    if (s.id == param.get_string ()) set_layer (s);
                }
            });
            add_action (layer_action);
            var locate_action = new SimpleAction ("locate", null);
            locate_action.activate.connect (() => locate ());
            add_action (locate_action);
            var directions = new SimpleAction ("directions", null);
            directions.activate.connect (() => open_route (null, null));
            add_action (directions);
            var favs = new SimpleAction ("favorites", null);
            favs.activate.connect (() => show_favorites ());
            add_action (favs);
        }

        private void update_place_actions () {
            copy_coords_action.set_enabled (map.pin != null);
            copy_link_action.set_enabled (map.pin != null);
        }

        private void set_layer (TileSource src) {
            map.set_source (src);
            layer_action.set_state (new Variant.string (src.id));
            update_attribution ();
            save_state ();
        }

        private uint save_id;

        private void schedule_save () {
            if (save_id != 0) Source.remove (save_id);
            save_id = Timeout.add (1500, () => {
                save_id = 0;
                save_state ();
                return Source.REMOVE;
            });
        }

        private void save_state () {
            double lat, lon;
            map.center (out lat, out lon);
            state.set_double ("View", "lat", lat);
            state.set_double ("View", "lon", lon);
            state.set_double ("View", "zoom", map.zoom);
            state.set_string ("View", "layer", map.tiles.source.id);
            DirUtils.create_with_parents (Path.get_dirname (state_path), 0700);
            try {
                state.save_to_file (state_path);
            } catch (Error e) {
            }
        }

        private void update_attribution () {
            attribution.label = "<a href=\"https://www.openstreetmap.org/copyright\">%s</a>".printf (Markup.escape_text (map.tiles.source.attribution));
        }

        private void clear_panel () {
            Widget? c;
            while ((c = panel.get_first_child ()) != null) panel.remove (c);
        }

        private void hide_panel () {
            panel_reveal.reveal_child = false;
            map.left_inset = 0;
        }

        private void show_panel () {
            panel_reveal.reveal_child = true;
            map.left_inset = get_width () > 800 ? 400 : 0;
        }

        private Box panel_header (string title, string? back = null) {
            var head = new Box (Orientation.HORIZONTAL, 6);
            var l = new Label (title);
            l.add_css_class ("maps-panel-title");
            l.xalign = 0;
            l.hexpand = true;
            l.ellipsize = Pango.EllipsizeMode.END;
            head.append (l);
            var close = new Button.from_icon_name ("window-close-symbolic");
            close.add_css_class ("flat");
            close.add_css_class ("circular");
            close.tooltip_text = _("Close");
            close.clicked.connect (() => {
                hide_panel ();
                if (route != null) {
                    route = null;
                    map.route = null;
                    map.queue_draw ();
                }
            });
            head.append (close);
            return head;
        }

        private Label status (string text) {
            var l = new Label (text);
            l.add_css_class ("dim-label");
            l.wrap = true;
            l.xalign = 0;
            return l;
        }

        private StatusPage panel_status (string icon_name, string title, string description, string action, owned WelcomePage.ActionCallback callback) {
            var sp = new StatusPage ();
            sp.icon_name = icon_name;
            sp.title = title;
            sp.description = description;
            WelcomePage.ActionCallback cb = (owned) callback;
            var b = new Button.with_label (action);
            b.halign = Align.CENTER;
            b.add_css_class ("pill");
            b.add_css_class ("suggested-action");
            b.clicked.connect (() => cb ());
            sp.child = b;
            return sp;
        }

        private void run_search (string text, bool live = false) {
            string q = text.strip ();
            if (q == "") return;
            int serial = ++search_serial;
            if (!live) {
                clear_panel ();
                panel.append (panel_header (_("Results")));
                var spin = new Spinner ();
                spin.spinning = true;
                panel.append (spin);
                show_panel ();
            }
            double lat, lon;
            map.center (out lat, out lon);
            Search.query.begin (q, lat, lon, (o, res) => {
                if (serial != search_serial) return;
                try {
                    var list = Search.query.end (res);
                    show_results (list);
                } catch (Error e) {
                    clear_panel ();
                    panel.append (panel_header (_("Results")));
                    panel.append (panel_status ("network-error", _("Search Not Available"), e.message, _("Try Again"), () => run_search (q)));
                    show_panel ();
                }
            });
        }

        private void show_results (Gee.List<Place> list) {
            clear_panel ();
            panel.append (panel_header (_("Results")));
            map.markers.clear ();
            if (list.size == 0) {
                panel.append (panel_status ("system-search", _("No Places Found"), _("No places match your search."), _("Clear Search"), () => {
                    search.clear ();
                    hide_panel ();
                }));
                show_panel ();
                map.queue_draw ();
                return;
            }
            var box = new ListBox ();
            box.add_css_class ("maps-results");
            box.selection_mode = SelectionMode.NONE;
            foreach (var p in list) {
                map.markers.add (p);
                var row = new ListBoxRow ();
                var inner = new Box (Orientation.HORIZONTAL, 10);
                var icon = new Image.from_icon_name ("mark-location-symbolic");
                icon.valign = Align.START;
                icon.margin_top = 2;
                inner.append (icon);
                var texts = new Box (Orientation.VERTICAL, 2);
                texts.hexpand = true;
                var name = new Label (p.name);
                name.xalign = 0;
                name.wrap = true;
                name.add_css_class ("heading");
                texts.append (name);
                string sub = string.joinv (" · ", non_empty ({ p.category, p.detail }));
                if (sub != "") {
                    var s = new Label (sub);
                    s.xalign = 0;
                    s.wrap = true;
                    s.add_css_class ("dim-label");
                    s.add_css_class ("caption");
                    texts.append (s);
                }
                inner.append (texts);
                row.child = inner;
                row.set_data<Place> ("place", p);
                box.append (row);
            }
            box.row_activated.connect ((row) => show_place (row.get_data<Place> ("place"), true));
            panel.append (box);
            show_panel ();
            double s = 90, n = -90, w = 180, e = -180;
            foreach (var p in list) {
                s = double.min (s, p.lat);
                n = double.max (n, p.lat);
                w = double.min (w, p.lon);
                e = double.max (e, p.lon);
            }
            if (list.size == 1) focus_place (list[0]);
            else if (n - s < 30 && e - w < 60) map.fit (s, w, n, e);
            map.queue_draw ();
        }

        private static string[] non_empty (string[] items) {
            string[] out_v = {};
            foreach (string s in items) if (s.strip () != "") out_v += s.strip ();
            return out_v;
        }

        private void focus_place (Place p) {
            if (p.extent != null) {
                map.fit (p.extent[3], p.extent[0], p.extent[1], p.extent[2]);
                return;
            }
            map.fly_to (p.lat, p.lon, double.max (map.zoom, 16));
        }

        private void what_is_here (double lat, double lon) {
            var p = new Place (_("Dropped Pin"), Geo.format_coords (lat, lon), lat, lon);
            show_place (p, false);
            Search.reverse.begin (lat, lon, (int) map.zoom, (o, res) => {
                try {
                    var found = Search.reverse.end (res);
                    found.lat = lat;
                    found.lon = lon;
                    if (map.pin == p) show_place (found, false);
                } catch (Error e) {
                }
            });
        }

        public void show_place (Place p, bool fly) {
            map.pin = p;
            update_place_actions ();
            map.queue_draw ();
            if (fly) focus_place (p);
            clear_panel ();
            panel.append (panel_header (p.name));
            if (p.category != "" || p.detail != "") {
                var sub = status (string.joinv ("\n", non_empty ({ p.category, p.detail })));
                sub.selectable = true;
                panel.append (sub);
            }
            var coords = new Box (Orientation.HORIZONTAL, 6);
            var cl = new Label (Geo.format_coords (p.lat, p.lon));
            cl.add_css_class ("maps-coords");
            cl.selectable = true;
            cl.hexpand = true;
            cl.xalign = 0;
            coords.append (cl);
            var copy = new Button.from_icon_name ("edit-copy-symbolic");
            copy.add_css_class ("flat");
            copy.tooltip_text = _("Copy Coordinates");
            copy.clicked.connect (() => get_clipboard ().set_text (Geo.format_coords (p.lat, p.lon)));
            coords.append (copy);
            panel.append (coords);
            if (!located_lat.is_nan ()) {
                panel.append (status (_("%s away").printf (Geo.format_distance (Geo.distance (located_lat, located_lon, p.lat, p.lon)))));
            }
            var actions = new Box (Orientation.HORIZONTAL, 8);
            var dir = new Button.with_label (_("Directions"));
            dir.add_css_class ("suggested-action");
            dir.add_css_class ("pill");
            dir.clicked.connect (() => open_route (null, p));
            actions.append (dir);
            bool fav = favorites.contains (p);
            var star = new Button.from_icon_name (fav ? "starred-symbolic" : "non-starred-symbolic");
            star.add_css_class ("maps-round");
            star.tooltip_text = fav ? _("Remove from Favorites") : _("Add to Favorites");
            star.clicked.connect (() => {
                favorites.toggle (p);
                show_place (p, false);
            });
            actions.append (star);
            var share = new Button.from_icon_name ("send-to-symbolic");
            share.add_css_class ("maps-round");
            share.tooltip_text = _("Copy Link");
            char[] b1 = new char[32];
            char[] b2 = new char[32];
            string link = "https://www.openstreetmap.org/?mlat=%s&mlon=%s#map=17/%s/%s".printf (p.lat.format (b1, "%.6f"), p.lon.format (b2, "%.6f"), p.lat.format (new char[32], "%.6f"), p.lon.format (new char[32], "%.6f"));
            share.clicked.connect (() => get_clipboard ().set_text (link));
            actions.append (share);
            var photos = new Button.from_icon_name ("image-x-generic-symbolic");
            photos.add_css_class ("maps-round");
            photos.tooltip_text = _("Photos Taken Here");
            photos.update_property (AccessibleProperty.LABEL, _("Photos Taken Here"), -1);
            double plat = p.lat, plon = p.lon;
            photos.clicked.connect (() => Singularity.ShareTargets.activate_app_action.begin ("dev.sinty.photos", "show-place", new Variant ("(dd)", plat, plon)));
            photos.visible = Singularity.Capabilities.has_app ("dev.sinty.photos");
            actions.append (photos);
            var web = new Button.from_icon_name ("web-browser-symbolic");
            web.add_css_class ("maps-round");
            web.tooltip_text = _("Open in OpenStreetMap");
            web.clicked.connect (() => new UriLauncher (link).launch.begin (this, null));
            actions.append (web);
            panel.append (actions);
            show_panel ();
        }

        private void locate () {
            locate_bubble.sensitive = false;
            var loc = new Locator ();
            loc.locate.begin ((o, res) => {
                locate_bubble.sensitive = true;
                try {
                    double lat, lon, acc;
                    loc.locate.end (res, out lat, out lon, out acc);
                    located_lat = lat;
                    located_lon = lon;
                    map.location_lat = lat;
                    map.location_lon = lon;
                    map.location_accuracy = acc;
                    double z = acc < 100 ? 16 : (acc < 1000 ? 14 : (acc < 10000 ? 12 : 9));
                    map.fly_to (lat, lon, z);
                } catch (Error e) {
                    clear_panel ();
                    panel.append (panel_header (_("Location")));
                    panel.append (panel_status ("find-location", _("Location Not Available"), _("Turn on Location Services in Settings, or search for a place."), _("Try Again"), () => locate ()));
                    show_panel ();
                }
            });
        }

        private void show_layers () {
            var menu = new ContextMenu (overlay);
            Graphene.Rect bounds;
            if (layers_bubble.compute_bounds (overlay, out bounds)) {
                var rect = Gdk.Rectangle ();
                rect.x = (int) bounds.origin.x;
                rect.y = (int) bounds.origin.y;
                rect.width = (int) bounds.size.width;
                rect.height = (int) bounds.size.height;
                menu.pointing_to = rect;
            }
            menu.position = PositionType.BOTTOM;
            foreach (var s in TileSource.all ()) {
                var src = s;
                menu.add_item (s.name, map.tiles.source.id == s.id ? "object-select-symbolic" : null, () => set_layer (src));
            }
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private void show_favorites () {
            clear_panel ();
            if (favorites.places.size == 0) {
                panel.append (panel_header (""));
                var wp = new WelcomePage ();
                wp.is_section = true;
                wp.embedded = true;
                wp.title = _("Favorite Places");
                wp.subtitle = _("Places you mark with the star appear here");
                wp.add_action ("system-search", _("Search for a Place"), _("Find a town, an address or a shop"), () => search.grab_focus_entry ());
                wp.add_action ("find-location", _("Show My Location"), _("Center the map where you are"), () => locate ());
                panel.append (wp);
                show_panel ();
                return;
            }
            panel.append (panel_header (_("Favorite Places")));
            var box = new ListBox ();
            box.add_css_class ("maps-results");
            box.selection_mode = SelectionMode.NONE;
            map.markers.clear ();
            foreach (var p in favorites.places) {
                map.markers.add (p);
                var row = new ListBoxRow ();
                var inner = new Box (Orientation.HORIZONTAL, 10);
                inner.append (new Image.from_icon_name ("starred-symbolic"));
                var texts = new Box (Orientation.VERTICAL, 2);
                var name = new Label (p.name);
                name.xalign = 0;
                name.add_css_class ("heading");
                texts.append (name);
                if (p.detail != "") {
                    var d = new Label (p.detail);
                    d.xalign = 0;
                    d.ellipsize = Pango.EllipsizeMode.END;
                    d.add_css_class ("dim-label");
                    d.add_css_class ("caption");
                    texts.append (d);
                }
                inner.append (texts);
                row.child = inner;
                row.set_data<Place> ("place", p);
                box.append (row);
            }
            box.row_activated.connect ((row) => show_place (row.get_data<Place> ("place"), true));
            panel.append (box);
            map.queue_draw ();
            show_panel ();
        }

        private Entry place_entry (string placeholder, Place? value, bool is_origin) {
            var e = new Entry ();
            e.placeholder_text = placeholder;
            e.text = value != null ? value.name : "";
            e.hexpand = true;
            e.activate.connect (() => pick_place (e, is_origin));
            return e;
        }

        private void pick_place (Entry e, bool is_origin) {
            string q = e.text.strip ();
            if (q == "") return;
            double lat, lon;
            map.center (out lat, out lon);
            Search.query.begin (q, lat, lon, (o, res) => {
                try {
                    var list = Search.query.end (res);
                    if (list.size == 0) return;
                    var menu = new ContextMenu (e);
                    menu.position = PositionType.BOTTOM;
                    int shown = 0;
                    foreach (var p in list) {
                        if (shown++ >= 8) break;
                        var place = p;
                        string where = p.detail != "" ? p.detail.split (",")[0].strip () : "";
                        if (p.detail.split (",").length > 2) where = p.detail.split (",")[p.detail.split (",").length - 3].strip ();
                        menu.add_item (where != "" && where != p.name ? "%s · %s".printf (p.name, where) : p.name, "mark-location-symbolic", () => {
                            if (is_origin) origin = place;
                            else destination = place;
                            e.text = place.name;
                            compute_route ();
                        });
                    }
                    menu.closed.connect (() => Idle.add (() => {
                        menu.unparent ();
                        return Source.REMOVE;
                    }));
                    menu.popup ();
                } catch (Error err) {
                }
            });
        }

        private void open_route (Place? from, Place? to) {
            if (to != null) destination = to;
            if (from != null) origin = from;
            if (origin == null && !located_lat.is_nan ()) origin = new Place (_("My Location"), "", located_lat, located_lon);
            build_route_panel ();
            compute_route ();
        }

        private Box? route_results;

        private void build_route_panel () {
            clear_panel ();
            panel.append (panel_header (_("Directions")));
            var modes = new Box (Orientation.HORIZONTAL, 4);
            modes.add_css_class ("maps-modes");
            ToggleButton? first = null;
            Mode[] all = { Mode.CAR, Mode.BIKE, Mode.FOOT };
            string[] icons = { "maps-car-symbolic", "maps-bike-symbolic", "maps-walk-symbolic" };
            for (int i = 0; i < all.length; i++) {
                var tb = new ToggleButton ();
                var inner = new Box (Orientation.HORIZONTAL, 6);
                inner.append (new Image.from_icon_name (icons[i]));
                inner.append (new Label (all[i].label ()));
                tb.child = inner;
                tb.add_css_class ("maps-mode");
                if (first == null) first = tb;
                else tb.group = first;
                tb.active = all[i] == mode;
                var m = all[i];
                tb.toggled.connect (() => {
                    if (!tb.active) return;
                    mode = m;
                    compute_route ();
                });
                modes.append (tb);
            }
            panel.append (modes);
            var fields = new Box (Orientation.HORIZONTAL, 6);
            var col = new Box (Orientation.VERTICAL, 6);
            col.hexpand = true;
            var from_e = place_entry (_("From"), origin, true);
            var to_e = place_entry (_("To"), destination, false);
            col.append (from_e);
            col.append (to_e);
            fields.append (col);
            var swap = new Button.from_icon_name ("maps-swap-symbolic");
            swap.add_css_class ("flat");
            swap.valign = Align.CENTER;
            swap.tooltip_text = _("Swap");
            swap.clicked.connect (() => {
                var t = origin;
                origin = destination;
                destination = t;
                build_route_panel ();
                compute_route ();
            });
            fields.append (swap);
            panel.append (fields);
            route_results = new Box (Orientation.VERTICAL, 6);
            panel.append (route_results);
            show_panel ();
        }

        private void compute_route () {
            if (route_results == null) return;
            Widget? c;
            while ((c = route_results.get_first_child ()) != null) route_results.remove (c);
            if (origin == null || destination == null) {
                route_results.append (status (_("Choose where you start and where you are going. You can also right-click the map.")));
                return;
            }
            var spin = new Spinner ();
            spin.spinning = true;
            route_results.append (spin);
            var from = origin, to = destination;
            Router.find.begin (from, to, mode, (o, res) => {
                if (from != origin || to != destination) return;
                while ((c = route_results.get_first_child ()) != null) route_results.remove (c);
                try {
                    route = Router.find.end (res);
                    map.route = route.points;
                    map.pin = to;
                    update_place_actions ();
                    map.markers.clear ();
                    map.fit (route.south, route.west, route.north, route.east);
                    var summary = new Label ("%s · %s".printf (Geo.format_duration (route.duration), Geo.format_distance (route.distance)));
                    summary.add_css_class ("maps-route-summary");
                    summary.xalign = 0;
                    route_results.append (summary);
                    var list = new ListBox ();
                    list.add_css_class ("maps-steps");
                    list.selection_mode = SelectionMode.NONE;
                    foreach (var st in route.steps) {
                        var row = new Box (Orientation.HORIZONTAL, 10);
                        row.margin_top = row.margin_bottom = 6;
                        var ic = new Image.from_icon_name (st.icon);
                        ic.valign = Align.START;
                        row.append (ic);
                        var t = new Label (st.text);
                        t.wrap = true;
                        t.xalign = 0;
                        t.hexpand = true;
                        row.append (t);
                        if (st.distance > 0) {
                            var d = new Label (Geo.format_distance (st.distance));
                            d.add_css_class ("dim-label");
                            d.add_css_class ("caption");
                            d.valign = Align.START;
                            row.append (d);
                        }
                        list.append (row);
                    }
                    route_results.append (list);
                    var credit = new Label (_("Routes by OSRM with OpenStreetMap data"));
                    credit.add_css_class ("dim-label");
                    credit.add_css_class ("caption");
                    route_results.append (credit);
                } catch (Error e) {
                    map.route = null;
                    route_results.append (status (e.message));
                }
                map.queue_draw ();
            });
        }

        public void open_geo (string uri) {
            string rest = uri.substring (4);
            string q = "";
            int qi = rest.index_of ("?q=");
            if (qi >= 0) {
                q = Uri.unescape_string (rest.substring (qi + 3).replace ("+", " ")) ?? "";
                int amp = q.index_of ("&");
                if (amp >= 0) q = q.substring (0, amp);
                rest = rest.substring (0, qi);
            }
            int semi = rest.index_of (";");
            if (semi >= 0) rest = rest.substring (0, semi);
            double lat, lon;
            bool has_coords = Geo.parse_coords (rest, out lat, out lon) && !(lat == 0 && lon == 0);
            if (q != "") {
                int paren = q.index_of ("(");
                if (paren > 0 && has_coords) q = q.substring (0, paren).strip ();
                search.text = q;
                if (!has_coords) {
                    run_search (q);
                    return;
                }
            }
            if (has_coords) {
                var p = new Place (q != "" ? q : _("Shared Location"), Geo.format_coords (lat, lon), lat, lon);
                show_place (p, true);
            }
        }
    }
}
