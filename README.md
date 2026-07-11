# RVV IREE Lab

A development lab for experimenting with RISC-V, RVV, compiler behavior,
native execution on the Orange Pi RV2, and eventual IREE integration.

## Local build

Configure:

```sh
cmake -S . -B build/host -G Ninja -DCMAKE_BUILD_TYPE=Debug
```

Build:

```sh
cmake --build build/host
```

Run tests:

```sh
ctest --test-dir build/host --output-on-failure
```

Run the program:

```sh
./build/host/arch-info
```

## Continuous integration

GitHub Actions builds and tests the project on an x86-64 Linux runner.

The CI workflow runs:

- When a pull request is opened or updated.
- When a commit is pushed to `main`.
- When manually started from GitHub.

The workflow performs the equivalent of:

```sh
cmake -S . -B build/ci -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug

cmake --build build/ci --parallel 2

ctest --test-dir build/ci --output-on-failure

./build/ci/arch-info
```

This workflow only validates the host build. Native RISC-V validation remains a
separate step:

```sh
./scripts/board-test.sh
```

## Orange Pi validation

```sh
./scripts/board-test.sh
```
