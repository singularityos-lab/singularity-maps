namespace Singularity.Apps.Maps {

    [DBus (name = "dev.sinty.Maps1")]
    public class TravelBus : Object {
        private unowned GLib.Application app;

        public TravelBus (GLib.Application app) {
            this.app = app;
        }

        public async void travel_time (string destination, string mode, out double seconds, out double meters, out string place) throws Error {
            seconds = meters = 0;
            place = "";
            app.hold ();
            try {
                double lat, lon, accuracy;
                yield new Locator ().locate (out lat, out lon, out accuracy);
                var found = yield Search.query (destination, lat, lon);
                if (found.size == 0) throw new IOError.NOT_FOUND (_("%s was not found on the map").printf (destination));
                var from = new Place (_("Your Location"), "", lat, lon);
                Mode m = mode == "foot" ? Mode.FOOT : (mode == "bike" ? Mode.BIKE : Mode.CAR);
                var route = yield Router.find (from, found[0], m);
                seconds = route.duration;
                meters = route.distance;
                place = found[0].name;
            } finally {
                app.release ();
            }
        }
    }
}
