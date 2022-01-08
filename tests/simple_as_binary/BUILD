load("@io_bazel_rules_d//d:d.bzl", "d_binary", "ldc2_binary")

d_binary(
    name = "simple",
    srcs = ["simple.d"],
)

ldc2_binary(
    name = "simple_ldc2",
    srcs = ["simple.d"],
)

sh_test(
    name = "simple_as_binary",
    srcs = ["run_simple.sh"],
    data = [":simple"],
)

sh_test(
    name = "simple_as_binary_ldc2",
    srcs = ["run_simple_ldc2.sh"],
    data = [":simple_ldc2"],
)

genrule(
    name = "run_simple",
    outs = ["run_simple.sh"],
    executable = True,
    cmd = "echo $(rootpath :simple) > $@",
    tools = [":simple"],
)

genrule(
    name = "run_simple_ldc2",
    outs = ["run_simple_ldc2.sh"],
    executable = True,
    cmd = "echo $(rootpath :simple_ldc2) > $@",
    tools = [":simple_ldc2"],
)
