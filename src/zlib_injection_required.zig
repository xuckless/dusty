//! Replaced by an application's custom `zlib` module when Dusty is built with
//! `use_zlib=true, use_bundled_zlib=false`.

comptime {
    @compileError(
        "Dusty was built with use_bundled_zlib=false, but no zlib module was injected; " ++
            "call dusty.module(\"dusty\").addImport(\"zlib\", custom_zlib_module)",
    );
}
