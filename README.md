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

## SSH access to the Orange Pi

Board validation requires non-interactive SSH public-key authentication.

The SSH client must have a host entry named `orangepi-rv2`. For example:

```sshconfig
Host orangepi-rv2
    HostName 100.110.155.95
    User caua
    IdentityFile ~/.ssh/id_ed25519_orangepi_rv2
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

Create a dedicated key on the development laptop:

```sh
ssh-keygen \
  -t ed25519 \
  -f ~/.ssh/id_ed25519_orangepi_rv2 \
  -C "rvv-iree-lab board access"
```

Copy its public key to the board:

```sh
ssh-copy-id \
  -i ~/.ssh/id_ed25519_orangepi_rv2.pub \
  orangepi-rv2
```

Verify that SSH no longer requests a password:

```sh
ssh \
  -o BatchMode=yes \
  orangepi-rv2 \
  'uname -m'
```

Expected output:

```text
riscv64
```

Never commit the private key or copy it into the repository.

## Orange Pi validation

```sh
./scripts/board-test.sh
```
