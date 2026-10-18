//! Replaced by an application's `zstd` module (bindings of zstd.h, with
//! ZSTD_STATIC_LINKING_ONLY, linking libzstd) when Dusty is built with
//! `use_zstd=true`.

comptime {
    @compileError(
        "Dusty was built with use_zstd=true, but no zstd module was injected; " ++
            "call dusty.module(\"dusty\").addImport(\"zstd\", zstd_module)",
    );
}
