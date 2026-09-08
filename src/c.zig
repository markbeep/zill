pub const c = @cImport({
    @cInclude("geotiff.h");
    @cInclude("geo_normalize.h");
    @cInclude("libxtiff/xtiffio.h");
});
