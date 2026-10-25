# Simulation AST audit setup

Run the audit on the host that configured the build. It reads `compile_commands.json`
and `sim_manifest.json`; it does not change compilation flags, policy or baseline.

## Windows (MSVC)

Recent MSVC standard-library headers require **LLVM 19 or newer**. The Linux
`libclang==18.1.1` wheel is not sufficient. Install x64 LLVM, for example:

```bat
winget install -e --id LLVM.LLVM --version 19.1.7
```

Alternatively use the [official LLVM 19.1.7 Windows x64 installer](https://github.com/llvm/llvm-project/releases/download/llvmorg-19.1.7/LLVM-19.1.7-win64.exe)
from the [LLVM releases](https://github.com/llvm/llvm-project/releases).
`winget install -e --id LLVM.LLVM` selects the current version; when using it,
install Python `clang` bindings matching that LLVM release rather than the 19.x
bindings in this reproducible example. Use 64-bit Python with the x64 DLL.

In a dedicated Python environment (do not install the `clang` and `libclang`
distributions together: they both supply the `clang` Python package):

```bat
python -m venv workspace\sim-audit-venv
call workspace\sim-audit-venv\Scripts\activate.bat
python -m pip install clang==19.1.7 pytest
```

Then use the same **x64 Native Tools Command Prompt for VS 2022** as the build:

```bat
build.bat Release
python tools\sim\sim_audit.py --build engine\build
run_tests.bat
```

`run_tests.bat` also needs its documented Godot console executable and any external
test fixtures. `build.bat` sets up MSVC internally, but its environment is local to
that script: the audit still needs a developer prompt with the MSVC/SDK `INCLUDE`
variable. It reports an error if that variable is empty.

DLL discovery order is `OPENBFME_LIBCLANG_LIBRARY`, then
`%ProgramW6432%\LLVM\bin\libclang.dll` / `%ProgramFiles%\LLVM\bin\libclang.dll`,
then `libclang.dll` beside `clang.exe` on PATH. For a nonstandard installation:

```bat
set "OPENBFME_LIBCLANG_LIBRARY=D:\LLVM\bin\libclang.dll"
```

`OPENBFME_LIBCLANG_PYTHONPATH` can name a directory containing the Python `clang`
package. The actual loaded DLL's version is checked (not just `clang.exe --version`)
and printed. A missing DLL, LLVM < 19, or incompatible bindings is a named error
and a nonzero exit; an invalid explicit DLL is never replaced silently.

The MSVC argument adapter preserves `/I`, `/external:I` (also CMake's
`-external:I` spelling), `/D` and `/FI`, including separated arguments and quoted
paths. Thus Lua's `lua-ea/include` comes from `openbfme_lua`'s SYSTEM PUBLIC
include path in the compile command, not from a hard-coded audit path. Relative
paths use the compile command's working directory. System headers use MSVC's
`INCLUDE` search path. The loaded LLVM installation's `lib/clang/<major>/include`
resource headers precede the SDK headers, as Clang requires for its builtin
`offsetof`; a missing resource directory is an error. Install the complete LLVM
distribution, not a standalone DLL. Windows parsing disables delayed template
parsing so uninstantiated template bodies are inspected as on Linux. These are
AST parser settings only: the build's simulation flags and audit rules are unchanged.

## Linux

Existing setup is unchanged: `python -m pip install libclang==18.1.1`, then
`python tools/sim/sim_audit.py --build <build-dir>` on the build host. Compiler
system includes are probed from that build's compiler.

## macOS

Install the libclang wheel for its Python bindings (`python -m pip install
libclang==18.1.1`), but the AST pass does not load the wheel's libclang 18: the
macOS SDK's libc++ headers use builtins of the SDK's own compiler (libclang 18
fails on `__builtin_clzg` in `<__bit/countl.h>`). `sim_audit.py` loads the
`libclang.dylib` of the active developer toolchain instead (`xcrun --find clang`,
then `../lib/libclang.dylib`: Xcode or the Command Line Tools, the compiler the
build uses). `OPENBFME_LIBCLANG_LIBRARY` overrides it; a missing library is an
error. The universal build's compile commands are parsed for the arm64 slice.

The default is `--ast=require` on every platform. Explicit `--ast=skip` remains
a loud exit 3, never proof that the AST audit passed. Do not use it for acceptance.
