# Copyright 2015 The Bazel Authors. All rights reserved
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""D rules for Bazel."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def _is_windows(ctx):
    return ctx.configuration.host_path_separator == ";"

def a_filetype(ctx, files):
    lib_suffix = ".lib" if _is_windows(ctx) else ".a"
    return [f for f in files if f.basename.endswith(lib_suffix)]

D_FILETYPE = [".d", ".di"]

ZIP_PATH = "/usr/bin/zip"

def _files_directory(files):
    """Returns the shortest parent directory of a list of files."""
    dir = files[0].dirname
    for f in files:
        if len(dir) > len(f.dirname):
            dir = f.dirname
    return dir

def _d_toolchain(ctx):
    """Returns a struct containing info about the D toolchain.

    Args:
      ctx: The ctx object.

    Return:
      Struct containing the following fields:
        d_compiler_path: The path to the D compiler.
        link_flags: Linker (-L) flags for adding the standard library to the
            library search paths.
        import_flags: import (-I) flags for adding the standard library sources
            to the import paths.
    """

    d_compiler_path = ctx.file._d_compiler.path
    return struct(
        d_compiler_path = d_compiler_path,
        link_flags = [("-L/LIBPATH:" if _is_windows(ctx) else "-L-L") + ctx.files._d_stdlib[0].dirname],
        import_flags = [
            "-I" + _files_directory(ctx.files._d_stdlib_src),
            "-I" + _files_directory(ctx.files._d_runtime_import_src),
        ],
    )

COMPILATION_MODE_FLAGS_POSIX = {
    "fastbuild": ["-g"],
    "dbg": ["-debug", "-g"],
    "opt": ["-checkaction=halt", "-boundscheck=safeonly", "-O"],
}

COMPILATION_MODE_FLAGS_WINDOWS = {
    "fastbuild": ["-g", "-m64", "-mscrtlib=msvcrt"],
    "dbg": ["-debug", "-g", "-m64", "-mscrtlib=msvcrtd"],
    "opt": ["-checkaction=halt", "-boundscheck=safeonly", "-O",
        "-m64", "-mscrtlib=msvcrt"],
}

def _compilation_mode_flags(ctx):
    """Returns a list of flags based on the compilation_mode."""
    if _is_windows(ctx):
        return COMPILATION_MODE_FLAGS_WINDOWS[ctx.var["COMPILATION_MODE"]]
    else:
        return COMPILATION_MODE_FLAGS_POSIX[ctx.var["COMPILATION_MODE"]]

def _format_version(name):
    """Formats the string name to be used in a --version flag."""
    return name.replace("-", "_")

def _build_import(label, im):
    """Builds the import path under a specific label"""
    import_path = ""
    if label.workspace_root:
        import_path += label.workspace_root + "/"
    if label.package:
        import_path += label.package + "/"
    import_path += im
    return import_path

def _build_compile_arglist(ctx, out, depinfo, extra_flags = []):
    """Returns a list of strings constituting the D compile command arguments."""
    toolchain = _d_toolchain(ctx)
    return (
        _compilation_mode_flags(ctx) +
        extra_flags + [
            "-of" + out.path,
            "-I.",
            "-w",
        ] +
        ["-I%s" % _build_import(ctx.label, im) for im in ctx.attr.imports] +
        ["-I%s" % im for im in depinfo.imports] +
        toolchain.import_flags +
        ["%s=Have_%s" % (ctx.attr._d_flag_version, _format_version(ctx.label.name))] +
        ["%s=%s" % (ctx.attr._d_flag_version, v) for v in ctx.attr.versions] +
        ["%s=%s" % (ctx.attr._d_flag_version, v) for v in depinfo.versions]
    )

def _build_link_arglist(ctx, objs, out, depinfo):
    """Returns a list of strings constituting the D link command arguments."""
    toolchain = _d_toolchain(ctx)
    return (
        _compilation_mode_flags(ctx) +
        ["-of" + out.path] +
        toolchain.link_flags +
        [f.path for f in depset(transitive = [depinfo.libs, depinfo.transitive_libs]).to_list()] +
        depinfo.link_flags +
        objs
    )

def _setup_deps(ctx, deps, name, working_dir):
    """Sets up dependencies.

    Walks through dependencies and constructs the commands and flags needed
    for linking the necessary dependencies.

    Args:
      deps: List of deps labels from ctx.attr.deps.
      name: Name of the current target.
      working_dir: The output directory of the current target's output.

    Returns:
      Returns a struct containing the following fields:
        libs: List of Files containing the target's direct library dependencies.
        transitive_libs: List of Files containing all of the target's
            transitive libraries.
        d_srcs: List of Files representing D source files of dependencies that
            will be used as inputs for this target.
        versions: List of D versions to be used for compiling the target.
        imports: List of Strings containing input paths that will be passed
            to the D compiler via -I flags.
        link_flags: List of linker flags.
    """

    libs = []
    transitive_libs = []
    d_srcs = []
    transitive_d_srcs = []
    versions = []
    imports = []
    link_flags = []
    for dep in deps:
        if hasattr(dep, "d_lib"):
            # The dependency is a d_library.
            libs.append(dep.d_lib)
            transitive_libs.append(dep.transitive_libs)
            d_srcs += dep.d_srcs
            transitive_d_srcs.append(dep.transitive_d_srcs)
            versions += dep.versions + ["Have_%s" % _format_version(dep.label.name)]
            link_flags.extend(dep.link_flags)
            imports += [_build_import(dep.label, im) for im in dep.imports]

        elif hasattr(dep, "d_srcs"):
            # The dependency is a d_source_library.
            d_srcs += dep.d_srcs
            transitive_d_srcs.append(dep.transitive_d_srcs)
            transitive_libs.append(dep.transitive_libs)
            link_flags += ["-L%s" % linkopt for linkopt in dep.linkopts]
            imports += [_build_import(dep.label, im) for im in dep.imports]
            versions += dep.versions

        elif CcInfo in dep:
            # The dependency is a cc_library
            native_libs = a_filetype(ctx, _get_libs_for_static_executable(dep))
            libs.extend(native_libs)
            transitive_libs.append(depset(native_libs))

        else:
            fail("D targets can only depend on d_library, d_source_library, or " +
                 "cc_library targets.", "deps")

    return struct(
        libs = depset(libs),
        transitive_libs = depset(transitive = transitive_libs),
        d_srcs = depset(d_srcs).to_list(),
        transitive_d_srcs = depset(transitive = transitive_d_srcs),
        versions = versions,
        imports = depset(imports).to_list(),
        link_flags = depset(link_flags).to_list(),
    )

def _d_library_impl(ctx):
    """Implementation of the d_library rule."""
    d_lib = ctx.actions.declare_file((ctx.label.name + ".lib") if _is_windows(ctx) else ("lib" + ctx.label.name + ".a"))

    # Dependencies
    depinfo = _setup_deps(ctx, ctx.attr.deps, ctx.label.name, d_lib.dirname)

    # Build compile command.
    compile_args = _build_compile_arglist(
        ctx = ctx,
        out = d_lib,
        depinfo = depinfo,
        extra_flags = ["-lib"],
    )

    # Convert sources to args
    # This is done to support receiving a File that is a directory, as
    # args will auto-expand this to the contained files
    args = ctx.actions.args()
    args.add_all(compile_args)
    args.add_all(ctx.files.srcs)

    compile_inputs = depset(
        ctx.files.srcs +
        depinfo.d_srcs +
        ctx.files._d_stdlib +
        ctx.files._d_stdlib_src +
        ctx.files._d_runtime_import_src,
        transitive = [
            depinfo.transitive_d_srcs,
            depinfo.libs,
            depinfo.transitive_libs,
        ],
    )

    ctx.actions.run(
        inputs = compile_inputs,
        tools = [ctx.file._d_compiler],
        outputs = [d_lib],
        mnemonic = "Dcompile",
        executable = ctx.file._d_compiler.path,
        arguments = [args],
        use_default_shell_env = True,
        progress_message = "Compiling D library " + ctx.label.name,
    )

    return struct(
        files = depset([d_lib]),
        d_srcs = ctx.files.srcs,
        transitive_d_srcs = depset(depinfo.d_srcs),
        transitive_libs = depset(transitive = [depinfo.libs, depinfo.transitive_libs]),
        link_flags = depinfo.link_flags,
        versions = ctx.attr.versions,
        imports = ctx.attr.imports,
        d_lib = d_lib,
    )

def _d_binary_impl_common(ctx, extra_flags = []):
    """Common implementation for rules that build a D binary."""
    d_bin = ctx.actions.declare_file(ctx.label.name + ".exe" if _is_windows(ctx) else ctx.label.name)
    d_obj = ctx.actions.declare_file(ctx.label.name + (".obj" if _is_windows(ctx) else ".o"))
    depinfo = _setup_deps(ctx, ctx.attr.deps, ctx.label.name, d_bin.dirname)

    # Build compile command
    compile_args = _build_compile_arglist(
        ctx = ctx,
        depinfo = depinfo,
        out = d_obj,
        extra_flags = ["-c"] + extra_flags,
    )

    # Convert sources to args
    # This is done to support receiving a File that is a directory, as
    # args will auto-expand this to the contained files
    args = ctx.actions.args()
    args.add_all(compile_args)
    args.add_all(ctx.files.srcs)

    toolchain_files = (
        ctx.files._d_stdlib +
        ctx.files._d_stdlib_src +
        ctx.files._d_runtime_import_src
    )

    compile_inputs = depset(
        ctx.files.srcs + depinfo.d_srcs + toolchain_files,
        transitive = [depinfo.transitive_d_srcs],
    )
    ctx.actions.run(
        inputs = compile_inputs,
        tools = [ctx.file._d_compiler],
        outputs = [d_obj],
        mnemonic = "Dcompile",
        executable = ctx.file._d_compiler.path,
        arguments = [args],
        use_default_shell_env = True,
        progress_message = "Compiling D binary " + ctx.label.name,
    )

    # Build link command
    link_args = _build_link_arglist(
        ctx = ctx,
        objs = [d_obj.path],
        depinfo = depinfo,
        out = d_bin,
    )

    link_inputs = depset(
        [d_obj] + toolchain_files,
        transitive = [depinfo.libs, depinfo.transitive_libs],
    )

    ctx.actions.run(
        inputs = link_inputs,
        tools = [ctx.file._d_compiler],
        outputs = [d_bin],
        mnemonic = "Dlink",
        executable = ctx.file._d_compiler.path,
        arguments = link_args,
        use_default_shell_env = True,
        progress_message = "Linking D binary " + ctx.label.name,
    )

    return struct(
        d_srcs = ctx.files.srcs,
        transitive_d_srcs = depset(depinfo.d_srcs),
        imports = ctx.attr.imports,
        executable = d_bin,
    )

def _d_binary_impl(ctx):
    """Implementation of the d_binary rule."""
    return _d_binary_impl_common(ctx)

def _d_test_impl(ctx):
    """Implementation of the d_test rule."""
    return _d_binary_impl_common(ctx, extra_flags = ["-unittest"])

def _get_libs_for_static_executable(dep):
    """
    Finds the libraries used for linking an executable statically.
    This replaces the old API dep.cc.libs
    Args:
      dep: Target
    Returns:
      A list of File instances, these are the libraries used for linking.
    """
    libs = []
    for li in dep[CcInfo].linking_context.linker_inputs.to_list():
        for library_to_link in li.libraries:
            if library_to_link.static_library != None:
                libs.append(library_to_link.static_library)
            elif library_to_link.pic_static_library != None:
                libs.append(library_to_link.pic_static_library)
            elif library_to_link.interface_library != None:
                libs.append(library_to_link.interface_library)
            elif library_to_link.dynamic_library != None:
                libs.append(library_to_link.dynamic_library)
    return libs

def _d_source_library_impl(ctx):
    """Implementation of the d_source_library rule."""
    transitive_d_srcs = []
    transitive_libs = []
    transitive_transitive_libs = []
    transitive_imports = depset()
    transitive_linkopts = depset()
    transitive_versions = depset()
    for dep in ctx.attr.deps:
        if hasattr(dep, "d_srcs"):
            # Dependency is another d_source_library target.
            transitive_d_srcs.append(dep.d_srcs)
            transitive_imports = depset(dep.imports, transitive = [transitive_imports])
            transitive_linkopts = depset(dep.linkopts, transitive = [transitive_linkopts])
            transitive_versions = depset(dep.versions, transitive = [transitive_versions])
            transitive_transitive_libs.append(dep.transitive_libs)

        elif CcInfo in dep:
            # Dependency is a cc_library target.
            native_libs = a_filetype(ctx, _get_libs_for_static_executable(dep))
            transitive_libs.extend(native_libs)

        else:
            fail("d_source_library can only depend on other " +
                 "d_source_library or cc_library targets.", "deps")

    return struct(
        d_srcs = ctx.files.srcs,
        transitive_d_srcs = depset(transitive = transitive_d_srcs, order = "postorder"),
        transitive_libs = depset(transitive_libs, transitive = transitive_transitive_libs),
        imports = ctx.attr.imports + transitive_imports.to_list(),
        linkopts = ctx.attr.linkopts + transitive_linkopts.to_list(),
        versions = ctx.attr.versions + transitive_versions.to_list(),
    )

# TODO(dzc): Use ddox for generating HTML documentation.
def _d_docs_impl(ctx):
    """Implementation for the d_docs rule

      This rule runs the following steps to generate an archive containing
      HTML documentation generated from doc comments in D source code:
        1. Run the D compiler with the -D flags to generate HTML code
           documentation.
        2. Create a ZIP archive containing the HTML documentation.
    """
    d_docs_zip = ctx.outputs.d_docs
    docs_dir = d_docs_zip.dirname + "/_d_docs"
    objs_dir = d_docs_zip.dirname + "/_d_objs"

    target = struct(
        name = ctx.attr.dep.label.name,
        srcs = ctx.attr.dep.d_srcs,
        transitive_srcs = ctx.attr.dep.transitive_d_srcs,
        imports = ctx.attr.dep.imports,
    )

    # Build D docs command
    toolchain = _d_toolchain(ctx)
    doc_cmd = (
        [
            "set -e;",
            "rm -rf %s; mkdir -p %s;" % (docs_dir, docs_dir),
            "rm -rf %s; mkdir -p %s;" % (objs_dir, objs_dir),
            toolchain.d_compiler_path,
            "-c",
            "-D",
            "-Dd%s" % docs_dir,
            "-od%s" % objs_dir,
            "-I.",
        ] +
        ["-I%s" % _build_import(ctx.label, im) for im in target.imports] +
        toolchain.import_flags +
        [src.path for src in target.srcs] +
        [
            "&&",
            "(cd %s &&" % docs_dir,
            ZIP_PATH,
            "-qR",
            d_docs_zip.basename,
            "$(find . -type f) ) &&",
            "mv %s/%s %s" % (docs_dir, d_docs_zip.basename, d_docs_zip.path),
        ]
    )

    toolchain_files = (
        ctx.files._d_stdlib +
        ctx.files._d_stdlib_src +
        ctx.files._d_runtime_import_src
    )
    ddoc_inputs = depset(target.srcs + toolchain_files, transitive = [target.transitive_srcs])
    ctx.actions.run_shell(
        inputs = ddoc_inputs,
        tools = [ctx.file._d_compiler],
        outputs = [d_docs_zip],
        mnemonic = "Ddoc",
        command = " ".join(doc_cmd),
        use_default_shell_env = True,
        progress_message = "Generating D docs for " + ctx.label.name,
    )

_d_common_attrs = {
    "srcs": attr.label_list(allow_files = D_FILETYPE),
    "imports": attr.string_list(),
    "linkopts": attr.string_list(),
    "versions": attr.string_list(),
    "deps": attr.label_list(),
}

_d_compile_attrs = {
    "_d_flag_version": attr.string(default = "-version"),
    "_d_compiler": attr.label(
        default = Label("//d:dmd"),
        executable = True,
        allow_single_file = True,
        cfg = "host",
    ),
    "_d_runtime_import_src": attr.label(
        default = Label("//d:druntime-import-src"),
    ),
    "_d_stdlib": attr.label(
        default = Label("//d:libphobos2"),
    ),
    "_d_stdlib_src": attr.label(
        default = Label("//d:phobos-src"),
    ),
}

d_library = rule(
    _d_library_impl,
    attrs = dict(_d_common_attrs.items() + _d_compile_attrs.items()),
)

d_source_library = rule(
    _d_source_library_impl,
    attrs = _d_common_attrs,
)

d_binary = rule(
    _d_binary_impl,
    attrs = dict(_d_common_attrs.items() + _d_compile_attrs.items()),
    executable = True,
)

d_test = rule(
    _d_test_impl,
    attrs = dict(_d_common_attrs.items() + _d_compile_attrs.items()),
    executable = True,
    test = True,
)

_d_docs_attrs = {
    "dep": attr.label(mandatory = True),
}

d_docs = rule(
    _d_docs_impl,
    attrs = dict(_d_docs_attrs.items() + _d_compile_attrs.items()),
    outputs = {
        "d_docs": "%{name}-docs.zip",
    },
)

DMD_BUILD_FILE = """
package(default_visibility = ["//visibility:public"])

config_setting(
    name = "darwin",
    values = {"host_cpu": "darwin"},
)

config_setting(
    name = "k8",
    values = {"host_cpu": "k8"},
)

config_setting(
    name = "x64_windows",
    values = {"host_cpu": "x64_windows"},
)

filegroup(
    name = "dmd",
    srcs = select({
        ":darwin": ["dmd2/osx/bin/dmd"],
        ":k8": ["dmd2/linux/bin64/dmd"],
        ":x64_windows": ["dmd2/windows/bin64/dmd.exe"],
    }),
)

filegroup(
    name = "libphobos2",
    srcs = select({
        ":darwin": ["dmd2/osx/lib/libphobos2.a"],
        ":k8": [
            "dmd2/linux/lib64/libphobos2.a",
            "dmd2/linux/lib64/libphobos2.so",
        ],
        ":x64_windows": ["dmd2/windows/lib64/phobos64.lib"],
    }),
)

filegroup(
    name = "phobos-src",
    srcs = glob(["dmd2/src/phobos/**/*.*"]),
)

filegroup(
    name = "druntime-import-src",
    srcs = glob([
        "dmd2/src/druntime/import/*.*",
        "dmd2/src/druntime/import/**/*.*",
    ]),
)
"""

def d_repositories():
    http_archive(
        name = "dmd_linux_x86_64",
        urls = [
            "http://downloads.dlang.org/releases/2021/dmd.2.097.1.linux.tar.xz",
        ],
        sha256 = "030fd1bc3b7308dadcf08edc1529d4a2e46496d97ee92ed532b246a0f55745e6",
        build_file_content = DMD_BUILD_FILE,
    )

    http_archive(
        name = "dmd_darwin_x86_64",
        urls = [
            "http://downloads.dlang.org/releases/2021/dmd.2.097.1.osx.tar.xz",
        ],
        sha256 = "383a5524266417bcdd3126da947be7caebd4730f789021e9ec26d869c8448f6a",
        build_file_content = DMD_BUILD_FILE,
    )

    http_archive(
        name = "dmd_windows_x86_64",
        urls = [
            "http://downloads.dlang.org/releases/2021/dmd.2.097.1.windows.zip",
        ],
        sha256 = "63a00e624bf23ab676c543890a93b5325d6ef6b336dee2a2f739f2bbcef7ef1f",
        build_file_content = DMD_BUILD_FILE,
    )
    ldc2_repositories()


### LDC2 rules for Bazel. ###

def ldc2_sha256dict(s):
    d = {}
    for line in s.strip().splitlines():
        v, k = line.split("  ")
        d[k] = v
    return d

# https://github.com/ldc-developers/ldc/releases/download/v1.28.0/ldc2-1.28.0.sha256sums.txt
_LDC2_SHA256SUMS = ldc2_sha256dict("""
17fee8bb535bcb8cda0a45947526555c46c045f302a7349cc8711b254e54cf09  ldc-1.28.0-src.tar.gz
f59936c1c816698ab790b13b4a8cd0b2954bc5f43a38e4dd7ffaa29e28c2f3a6  ldc-1.28.0-src.zip
52666ebeaeddee402c022cbcdc39b8c27045e6faab15e53c72564b9eaf32ccff  ldc2-1.28.0-android-aarch64.tar.xz
c9b22ea84ed5738afcdf1740f501eea68a3269bda7e1a9eb1f139f9c4e5b96de  ldc2-1.28.0-android-armv7a.tar.xz
9786c36c4dfd29dd308a50c499c115e4c2079baeaded07e5ac5396c4a7fd0278  ldc2-1.28.0-linux-x86_64.tar.xz
f9786b8c28d8af1fdd331d8eb889add80285dbebfb97ea47d5dd9110a7df074b  ldc2-1.28.0-osx-arm64.tar.xz
02472507de988c8b5dd83b189c6df3b474741546589496c2ff3d673f26b8d09a  ldc2-1.28.0-osx-x86_64.tar.xz
8917876e2dbe763feec2d2d2ba81f20bfd32ed13753e5ea1bc5ce0ea564f3eaf  ldc2-1.28.0-windows-multilib.7z
e6ce44b6533fc4b7639b6ed078bdb107294fefc7b638141c42bf37b46e491990  ldc2-1.28.0-windows-multilib.exe
26bb3ece7774ef70d9c7485eab5fbc182d4e74411e4a8d2f339e9b421a76f069  ldc2-1.28.0-windows-x64.7z
af5465b316dfb582ded4fd6f83dfa02dfdd896fad6d397cc53d098e3ba9f9281  ldc2-1.28.0-windows-x86.7z
""")

_LDC2_BUILD_FILE = """
package(default_visibility = ["//visibility:public"])

config_setting(
    name = "darwin",
    values = {"host_cpu": "darwin"},
)

config_setting(
    name = "k8",
    values = {"host_cpu": "k8"},
)

config_setting(
    name = "x64_windows",
    values = {"host_cpu": "x64_windows"},
)

filegroup(
    name = "ldc2",
    srcs = ["bin/ldc2"],
)

filegroup(
    name = "libphobos2",
    srcs = select({
        ":darwin": ["lib/libphobos2-ldc.a", "lib/libphobos2-ldc-shared.dylib"],
        ":k8": ["lib/libphobos2-ldc.a", "lib/libphobos2-ldc-shared.so"],
        ":x64_windows": ["lib/phobos2-ldc.lib"],
    }),
)

filegroup(
    name = "phobos-src",
    srcs = glob([
        "import/std/*.*",
        "import/std/**/*.*",
    ]),
)

filegroup(
    name = "druntime-import-src",
    srcs = glob([
        "import/*.*",
        "import/core/*.*",
        "import/core/**/*.*",
        "import/etc/*.*",
        "import/etc/**/*.*",
        "import/ldc/*.*",
        "import/ldc/**/*.*",
    ]),
)
"""

def ldc2_archive(version, os, kernel, arch, ext):
    name = "ldc2_" + kernel + "_" + arch
    prefix = "ldc2-" + version + "-" + os + "-" + arch
    tarxz = prefix + ext
    return http_archive(
        name = name,
        urls = ["https://github.com/ldc-developers/ldc/releases/download/v" + version + "/" + tarxz],
        sha256 = _LDC2_SHA256SUMS[tarxz],
        strip_prefix=prefix,
        build_file_content = _LDC2_BUILD_FILE,
    )

def ldc2_repositories(version="1.28.0"):
    # TODO(karita): Support non x86_64 arch
    ldc2_archive(version, "linux", "linux", "x86_64", ".tar.xz")
    ldc2_archive(version, "osx", "darwin", "x86_64", ".tar.xz")
    ldc2_archive(version, "windows", "windows", "x64", ".7z")

_ldc2_compile_attrs = {
    "_d_flag_version": attr.string(default = "--d-version"),
    "_d_compiler": attr.label(
        default = Label("//d:ldc2"),
        executable = True,
        allow_single_file = True,
        cfg = "host",
    ),
    "_d_runtime_import_src": attr.label(
        default = Label("//d:druntime-import-src-ldc2"),
    ),
    "_d_stdlib": attr.label(
        default = Label("//d:libphobos2-ldc2"),
    ),
    "_d_stdlib_src": attr.label(
        default = Label("//d:phobos-src-ldc2"),
    ),
}

ldc2_library = rule(
    _d_library_impl,
    attrs = dict(_d_common_attrs.items() + _ldc2_compile_attrs.items()),
)

ldc2_binary = rule(
    _d_binary_impl,
    attrs = dict(_d_common_attrs.items() + _ldc2_compile_attrs.items()),
    executable = True,
)

ldc2_test = rule(
    _d_test_impl,
    attrs = dict(_d_common_attrs.items() + _ldc2_compile_attrs.items()),
    executable = True,
    test = True,
)
