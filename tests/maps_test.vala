using Singularity.Apps.Maps;

Json.Node load (string name) {
    var p = new Json.Parser ();
    try {
        p.load_from_file (Path.build_filename (Environment.get_variable ("MAPS_FIXTURES"), name));
    } catch (Error e) {
        assert_not_reached ();
    }
    return p.get_root ();
}

void test_geo () {
    double x = Geo.lon_to_x (9.19, 12), y = Geo.lat_to_y (45.4642, 12);
    assert (Math.fabs (Geo.x_to_lon (x, 12) - 9.19) < 1e-9);
    assert (Math.fabs (Geo.y_to_lat (y, 12) - 45.4642) < 1e-9);
    assert (Math.floor (x / TILE) == 2152 && Math.floor (y / TILE) == 1465);
    assert (Math.fabs (Geo.distance (45.4642, 9.19, 41.9028, 12.4964) - 477000) < 3000);
    double lat, lon;
    assert (Geo.parse_coords ("45.46, 9.19", out lat, out lon) && lat == 45.46 && lon == 9.19);
    assert (Geo.parse_coords ("-33.86 151.21", out lat, out lon) && lat == -33.86);
    assert (!Geo.parse_coords ("95, 10", out lat, out lon));
    assert (!Geo.parse_coords ("Milano", out lat, out lon));
}

void test_photon () {
    var list = Search.parse_photon (load ("photon.json"));
    assert (list.size == 2);
    assert (list[0].name == "Milano" && list[0].detail == "Lombardia, Italia");
    assert (list[0].extent != null && list[0].extent.length == 4);
    assert (list[1].name == "Piazza del Duomo 1" && list[1].category != "");
    assert (list[1].detail.contains ("20122"));
}

void test_reverse () {
    var p = Search.parse_reverse (load ("reverse.json"), 45.07, 7.68);
    assert (p.name == "Via Roma 12");
    assert (p.detail == "Centro, Torino, Italia");
    assert (p.osm_type == "W" && p.osm_id == 123);
}

void test_route () {
    try {
        var r = Router.parse (load ("osrm.json"));
        assert (r.points.length == 6 && r.points[0] == 45.46 && r.points[1] == 9.19);
        assert (r.steps.size == 4);
        assert (r.steps[0].text.contains ("Via Torino"));
        assert (r.steps[1].text.contains ("Corso Magenta"));
        assert (r.steps[2].icon == "maps-roundabout-symbolic");
        assert (r.south == 45.46 && r.north == 45.465);
    } catch (Error e) {
        assert_not_reached ();
    }
}

void test_favorites () {
    string path = Path.build_filename (Environment.get_tmp_dir (), "maps-fav-%d.json".printf (Random.int_range (0, 1000000)));
    var f = new Favorites (path);
    var p = new Place ("Home", "Via X", 1.5, 2.5);
    f.toggle (p);
    var g = new Favorites (path);
    assert (g.places.size == 1 && g.places[0].name == "Home" && g.contains (p));
    g.toggle (p);
    assert (!new Favorites (path).contains (p));
    FileUtils.remove (path);
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "C");
    Test.init (ref args);
    Test.add_func ("/maps/geo", test_geo);
    Test.add_func ("/maps/photon", test_photon);
    Test.add_func ("/maps/reverse", test_reverse);
    Test.add_func ("/maps/route", test_route);
    Test.add_func ("/maps/favorites", test_favorites);
    return Test.run ();
}
