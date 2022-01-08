package(default_visibility = ["//visibility:public"])

load("@io_bazel_rules_d//d:d.bzl", "d_library", "ldc2_library")

d_library(
    name = "lib_that_depends_on_lib",
    srcs = ["lib_that_depends_on_lib.d"],
    imports = [
        "..",
        "../simple_d_library",
    ],
    deps = [
        "//tests/simple_c_library",
        "//tests/simple_c_library:simple_c_library_wrapper",
        "//tests/simple_d_library",
    ],
)

ldc2_library(
    name = "lib_that_depends_on_lib_ldc2",
    srcs = ["lib_that_depends_on_lib.d"],
    imports = [
        "..",
        "../simple_d_library",
    ],
    deps = [
        "//tests/simple_c_library",
        "//tests/simple_c_library:simple_c_library_wrapper",
        "//tests/simple_d_library:simple_d_library_ldc2",
    ],
)
