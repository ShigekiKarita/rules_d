load("@io_bazel_rules_d//d:d.bzl", "d_test", "ldc2_test")

d_test(
    name = "d_library_usage",
    srcs = ["d_library_usage.d"],
    deps = ["//tests/simple_d_library"],
    imports = ["../simple_d_library"],
)

ldc2_test(
    name = "d_library_usage_ldc2",
    srcs = ["d_library_usage.d"],
    deps = ["//tests/simple_d_library:simple_d_library_ldc2"],
    imports = ["../simple_d_library"],
)
