namespace Singularity.Apps.Maps {

    public class MapsSearch : Singularity.SearchProviderService {
        private const string[] PREFIXES = { "map", "maps", "mappa", "mappe", "karte", "carte", "mapa", "kaart" };
        private const uint DELAY_MS = 450;

        private MapsApp app;
        private uint generation;
        private Gee.HashMap<string, Place> places = new Gee.HashMap<string, Place> ();

        public MapsSearch (MapsApp app) {
            this.app = app;
        }

        public static string? query_text (string[] terms) {
            if (terms.length == 0) return null;
            string first = terms[0].down ();
            string rest_of_first = "";
            bool matched = false;
            foreach (string p in PREFIXES) {
                if (first == p || first == p + ":") {
                    matched = true;
                    break;
                }
                if (first.has_prefix (p + ":")) {
                    matched = true;
                    rest_of_first = terms[0].substring (p.length + 1);
                    break;
                }
            }
            if (!matched) return null;
            string[] words = {};
            if (rest_of_first != "") words += rest_of_first;
            for (int i = 1; i < terms.length; i++) words += terms[i];
            string text = string.joinv (" ", words).strip ();
            return text.char_count () >= 2 ? text : null;
        }

        private static void bias (out double lat, out double lon) {
            lat = 0;
            lon = 0;
            var kf = new KeyFile ();
            try {
                kf.load_from_file (Path.build_filename (Environment.get_user_config_dir (), "singularity", "maps.ini"), KeyFileFlags.NONE);
                lat = kf.get_double ("View", "lat");
                lon = kf.get_double ("View", "lon");
            } catch (Error e) {
            }
        }

        private async void pause (uint ms) {
            Timeout.add (ms, () => {
                pause.callback ();
                return Source.REMOVE;
            });
            yield;
        }

        public override async string[] get_initial_results (string[] terms, Cancellable? cancellable) throws Error {
            uint mine = ++generation;
            string? text = query_text (terms);
            if (text == null) return {};
            yield pause (DELAY_MS);
            if (mine != generation) return {};
            double lat, lon;
            bias (out lat, out lon);
            var found = yield Search.query (text, lat, lon);
            if (mine != generation) return {};
            string[] ids = {};
            foreach (var p in found) {
                string id = Json.to_string (p.to_json (), false);
                places[id] = p;
                ids += id;
            }
            return ids;
        }

        private Place? place_for (string id) {
            var p = places[id];
            if (p != null) return p;
            try {
                var node = Json.from_string (id);
                if (node == null || node.get_node_type () != Json.NodeType.OBJECT) return null;
                p = Place.from_json (node.get_object ());
                places[id] = p;
                return p;
            } catch (Error e) {
                return null;
            }
        }

        public override async Singularity.SearchResultMeta[] get_result_metas (string[] ids, Cancellable? cancellable) throws Error {
            Singularity.SearchResultMeta[] metas = {};
            foreach (string id in ids) {
                var p = place_for (id);
                if (p == null) continue;
                var meta = new Singularity.SearchResultMeta (id, p.name);
                string[] parts = {};
                if (p.category != "") parts += p.category;
                if (p.detail != "") parts += p.detail;
                if (parts.length > 0) meta.description = string.joinv (", ", parts);
                meta.add_action ("copy-coordinates", _("Copy Coordinates"), "edit-copy-symbolic");
                metas += meta;
            }
            return metas;
        }

        public override async Singularity.SearchActivationReply? activate_result (string id, string[] terms, uint32 timestamp) throws Error {
            var p = place_for (id);
            if (p != null) app.show_place (p);
            return null;
        }

        public override async Singularity.SearchActivationReply? activate_action (string id, string action_id, string[] terms, uint32 timestamp) throws Error {
            var p = place_for (id);
            if (p == null || action_id != "copy-coordinates") return null;
            return Singularity.SearchActivationReply.copy (Geo.format_coords (p.lat, p.lon));
        }

        public override void launch_search (string[] terms, uint32 timestamp) {
            string? text = query_text (terms);
            if (text != null) app.search_for (text);
            else app.activate ();
        }
    }
}
