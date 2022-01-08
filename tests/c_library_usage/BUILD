load("@io_bazel_rules_d//d:d.bzl", "d_test", "ldc2_test")

d_test(
    name = "c_library_usage",
    srcs = ["c_library_usage.d"],
    deps = [
        "//tests/simple_c_library",
        "//tests/simple_c_library:simple_c_library_wrapper",
    ],
    imports = [".."],
)

ldc2_test(
    name = "c_library_usage_ldc2",
    srcs = ["c_library_usage.d"],
    deps = [
        "//tests/simple_c_library",
        "//tests/simple_c_library:simple_c_library_wrapper",
    ],
    imports = [".."],
)
