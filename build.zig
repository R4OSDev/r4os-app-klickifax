const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const libraries_build = b.lazyImport(@This(), "r4os_libraries") orelse return;
    const libraries_dep = b.dependencyFromBuildZig(libraries_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MFWithOptions(b.path("module.R4MF"), .{
        .zig_module_roots = &.{
            libraries_dep.namedLazyPath("r4img_zig_binding"),
            libraries_dep.namedLazyPath("r4font_app_fonts"),
            libraries_dep.namedLazyPath("r4std_zig_binding"),
        },
    });

    const model_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/model.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    model_tests.root_module.addImport("r4os", sdk.createR4osModule(b.graph.host, .Debug));
    const run_model_tests = b.addRunArtifact(model_tests);
    const inline_svg_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/inline_svg.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    inline_svg_tests.root_module.addImport("r4os", sdk.createR4osModule(b.graph.host, .Debug));
    const run_inline_svg_tests = b.addRunArtifact(inline_svg_tests);
    const storage_layout_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/storage_layout.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    storage_layout_tests.root_module.addImport("r4os", sdk.createR4osModule(b.graph.host, .Debug));
    const run_storage_layout_tests = b.addRunArtifact(storage_layout_tests);
    const font_cache_store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/font_cache_store.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    font_cache_store_tests.root_module.addImport("r4os", sdk.createR4osModule(b.graph.host, .ReleaseSafe));
    const run_font_cache_store_tests = b.addRunArtifact(font_cache_store_tests);
    const font_source_match_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/font_source_match.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_font_source_match_tests = b.addRunArtifact(font_source_match_tests);
    const font_run_mask_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/font_run_mask.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_font_run_mask_tests = b.addRunArtifact(font_run_mask_tests);
    const native_paint_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native_paint.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    native_paint_tests.root_module.addImport("r4os", sdk.createR4osModule(b.graph.host, .ReleaseSafe));
    const run_native_paint_tests = b.addRunArtifact(native_paint_tests);
    const loading_view_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/loading_view.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const loading_r4os = sdk.createR4osModule(b.graph.host, .ReleaseSafe);
    const loading_r4img = b.createModule(.{
        .root_source_file = libraries_dep.path("R4IMG/Bindings/Zig/r4img.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    loading_r4img.addImport("r4os", loading_r4os);
    loading_view_tests.root_module.addImport("r4os", loading_r4os);
    loading_view_tests.root_module.addImport("r4img", loading_r4img);
    const run_loading_view_tests = b.addRunArtifact(loading_view_tests);
    const font_test_r4os = sdk.createR4osModule(b.graph.host, .ReleaseSafe);
    const font_contract = b.createModule(.{
        .root_source_file = libraries_dep.path("R4FONT/Contract/Generated/implementation_abi.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    font_contract.addImport("r4os", font_test_r4os);
    const font_provider = b.createModule(.{
        .root_source_file = libraries_dep.path("R4FONT/Source/main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    font_provider.addImport("r4os", font_test_r4os);
    font_provider.addImport("r4l_contract", font_contract);
    libraries_build.addR4fontHostDecoder(b, font_provider, libraries_dep.path("R4FONT/ThirdParty/r4font"));
    const font_binding_abi = b.createModule(.{
        .root_source_file = libraries_dep.path("R4FONT/Bindings/Zig/r4font_abi.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    font_binding_abi.addImport("r4os", font_test_r4os);
    const font_binding = b.createModule(.{
        .root_source_file = libraries_dep.path("R4FONT/Bindings/Zig/r4font.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    font_binding.addImport("r4os", font_test_r4os);
    font_binding.addImport("r4font_abi.zig", font_binding_abi);
    const app_fonts = b.createModule(.{
        .root_source_file = libraries_dep.path("R4FONT/Bindings/Zig/app_fonts.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    app_fonts.addImport("r4os", font_test_r4os);

    const webfont_fixture_module = b.createModule(.{
        .root_source_file = b.path("src/webfont_fixture_test.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    webfont_fixture_module.addImport("r4font", font_binding);
    webfont_fixture_module.addImport("r4font_provider", font_provider);
    const webfont_fixture_tests = b.addTest(.{ .root_module = webfont_fixture_module });
    const run_webfont_fixture_tests = b.addRunArtifact(webfont_fixture_tests);
    run_webfont_fixture_tests.setCwd(b.path("Tests/Fixture/Browser/Fonts06241"));
    const document_font_module = b.createModule(.{
        .root_source_file = b.path("src/document_fonts.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    document_font_module.addImport("r4os", font_test_r4os);
    document_font_module.addImport("app_fonts", app_fonts);
    document_font_module.addImport("r4font_provider", font_provider);
    const document_font_tests = b.addTest(.{ .root_module = document_font_module });
    const run_document_font_tests = b.addRunArtifact(document_font_tests);
    run_document_font_tests.setCwd(b.path("Tests/Fixture/Browser/Fonts06241"));
    const test_step = b.step("test", "Run Klickifax navigation, inline SVG, storage and font source/cache tests");
    test_step.dependOn(&run_model_tests.step);
    test_step.dependOn(&run_inline_svg_tests.step);
    test_step.dependOn(&run_storage_layout_tests.step);
    test_step.dependOn(&run_font_cache_store_tests.step);
    test_step.dependOn(&run_font_source_match_tests.step);
    test_step.dependOn(&run_font_run_mask_tests.step);
    test_step.dependOn(&run_native_paint_tests.step);
    test_step.dependOn(&run_loading_view_tests.step);
    test_step.dependOn(&run_webfont_fixture_tests.step);
    test_step.dependOn(&run_document_font_tests.step);
}
