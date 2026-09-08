pub const c = @cImport({
    @cInclude("geotiff.h");
    @cInclude("geo_normalize.h");
    @cInclude("geovalues.h");
    @cInclude("libxtiff/xtiffio.h");
    @cInclude("proj.h");
});
