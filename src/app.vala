using Gtk;

namespace Singularity.Apps.Maps {

    public class MapsApp : Singularity.Application {
        public Favorites favorites;
        private Singularity.DockMenu dock_menu;
        private string? pending_action;

        public MapsApp () {
            Object (application_id: "dev.sinty.maps", flags: ApplicationFlags.HANDLES_OPEN);
            add_main_option ("directions", 0, OptionFlags.NONE, OptionArg.NONE, _("Plan a route"), null);
        }

        protected override int handle_local_options (VariantDict options) {
            if (!options.contains ("directions")) return -1;
            try {
                register (null);
            } catch (Error e) {
                warning ("maps: %s", e.message);
                return 1;
            }
            if (get_is_remote ()) {
                activate_action ("directions", null);
                return 0;
            }
            pending_action = "directions";
            return -1;
        }

        protected override void startup () {
            base.startup ();
            favorites = new Favorites ();
            dock_menu = new Singularity.DockMenu ("dev.sinty.maps");
            dock_menu.activated.connect ((id) => {
                foreach (var p in favorites.places) {
                    if (p.key () == id) {
                        show_place (p);
                        return;
                    }
                }
            });
            favorites.changed.connect (() => publish_dock_menu ());
            publish_dock_menu ();
            IconTheme.get_for_display (Gdk.Display.get_default ()).add_resource_path ("/dev/sinty/maps/icons");
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);
            var menu = new GLib.Menu ();
            var file = new GLib.Menu ();
            file.append (_("Close Window"), "win.close");
            file.append (_("Quit"), "app.quit");
            menu.append_submenu (_("File"), file);
            var edit = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Copy Coordinates"), "win.copy-coordinates");
            e1.append (_("Copy Link"), "win.copy-link");
            edit.append_section (null, e1);
            var e2 = new GLib.Menu ();
            e2.append (_("Find"), "win.find");
            edit.append_section (null, e2);
            var e3 = new GLib.Menu ();
            e3.append (_("Settings"), "app.settings");
            edit.append_section (null, e3);
            menu.append_submenu (_("Edit"), edit);
            var view = new GLib.Menu ();
            var v1 = new GLib.Menu ();
            v1.append (_("Zoom In"), "win.zoom-in");
            v1.append (_("Zoom Out"), "win.zoom-out");
            view.append_section (null, v1);
            var v2 = new GLib.Menu ();
            foreach (var s in TileSource.all ()) v2.append (s.name, "win.layer::" + s.id);
            view.append_section (null, v2);
            menu.append_submenu (_("View"), view);
            var go = new GLib.Menu ();
            go.append (_("My Location"), "win.locate");
            go.append (_("Directions"), "win.directions");
            go.append (_("Favorite Places"), "win.favorites");
            menu.append_submenu (_("Go"), go);
            set_menubar (menu);
            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => {
                foreach (var w in get_windows ()) w.close ();
            });
            add_action (quit);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.maps");
                } catch (Error e) {
                    warning ("Failed to open settings: %s", e.message);
                }
            });
            add_action (settings_action);
            var directions = new SimpleAction ("directions", null);
            directions.activate.connect (() => main_window ().activate_action ("directions", null));
            add_action (directions);
            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.find", { "<Control>f" });
            set_accels_for_action ("win.copy-coordinates", { "<Control><Shift>c" });
            set_accels_for_action ("win.zoom-in", { "<Control>plus", "<Control>equal" });
            set_accels_for_action ("win.zoom-out", { "<Control>minus" });
            set_accels_for_action ("win.locate", { "<Control>l" });
            set_accels_for_action ("win.directions", { "<Control>d" });
            set_accels_for_action ("win.favorites", { "<Control>b" });
        }

        private void publish_dock_menu () {
            dock_menu.clear ();
            if (favorites.places.size == 0) {
                dock_menu.unpublish ();
                return;
            }
            foreach (var p in favorites.places) dock_menu.add_item (p.key (), p.name, "starred-symbolic");
            dock_menu.publish ();
        }

        private MapsWindow main_window () {
            var w = get_active_window () as MapsWindow;
            if (w == null) {
                foreach (var win in get_windows ()) {
                    if (win is MapsWindow) w = (MapsWindow) win;
                }
            }
            if (w == null) w = new MapsWindow (this);
            w.present ();
            return w;
        }

        public void show_place (Place p) {
            main_window ().show_place (p, true);
        }

        public void search_for (string text) {
            main_window ().open_geo ("geo:0,0?q=" + Uri.escape_string (text, null, false));
        }

        public override void activate () {
            if (pending_action != null) {
                string action = pending_action;
                pending_action = null;
                activate_action (action, null);
                return;
            }
            main_window ();
        }

        public override void open (File[] files, string hint) {
            var w = main_window ();
            foreach (var f in files) {
                string uri = f.get_uri ();
                if (uri.has_prefix ("geo:")) w.open_geo (uri);
            }
        }

        private const string CSS = """
.maps-panel-room {
    padding: 24px 10px 24px 10px;
}

.maps-panel {
    border-radius: 18px;
    background-color: alpha(@window_bg_color, 0.97);
    box-shadow: 0 8px 26px alpha(black, 0.22);
}

.maps-panel-scroll {
    background: transparent;
}

.maps-panel-body {
    padding: 14px;
}

.maps-panel-title {
    font-weight: 800;
    font-size: 17px;
}

.maps-results {
    background: transparent;
}

.maps-results > row {
    border-radius: 10px;
    padding: 8px 6px;
}

.maps-coords {
    font-feature-settings: "tnum";
    font-size: 13px;
    opacity: 0.8;
}

.maps-round {
    border-radius: 99px;
    min-width: 34px;
    min-height: 34px;
    padding: 0;
}

.maps-mode {
    border-radius: 99px;
    padding: 4px 12px;
}

.maps-mode:checked {
    background-color: @hover_btn_bg;
    color: @hover_btn_fg;
}

.maps-route-summary {
    font-weight: 800;
    font-size: 17px;
    margin-top: 4px;
}

.maps-steps {
    background: transparent;
}

.maps-attribution {
    font-size: 11px;
    padding: 2px 8px;
    margin: 0 0 4px 0;
    border-radius: 8px 0 0 0;
    background-color: alpha(white, 0.8);
    color: #333333;
}

.maps-attribution link {
    color: #333333;
}

.maps-zoom .singularity-hover-btn {
    min-width: 38px;
    min-height: 38px;
    border-radius: 99px;
    background-color: @hover_btn_bg;
    color: @hover_btn_fg;
    border: 1px solid @hover_btn_border;
    box-shadow: 0 4px 14px alpha(black, 0.2);
}
""";
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-maps", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-maps", "UTF-8");
        Intl.textdomain ("singularity-maps");
        var app = new MapsApp ();
        new MapsSearch (app).export (app);
        return app.run (args);
    }
}
