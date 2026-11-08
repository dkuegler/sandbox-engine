# Apptainer: behaviour the launch line and the image build rely on

Last verified: 2026-11-08.

The launch line is `APPTAINER_EXEC` in `functions/apptainer.sh`:
`apptainer exec --containall --no-mount home,cwd,tmp,hostfs,bind-paths`, plus
`--home "$HOME"`, a `/tmp` bind and the run's own binds. Flag and directive
reference: [`apptainer exec`](https://apptainer.org/docs/user/latest/cli/apptainer_exec.html),
[bind paths and mounts](https://apptainer.org/docs/user/latest/bind_paths_and_mounts.html),
[`apptainer.conf`](https://apptainer.org/docs/admin/latest/configfiles.html).
The image build is `backend_build_image` in the same file:
`apptainer build --fakeroot … dockerfile:sandbox/agent`.

## Minimum version: 1.5.0, for OCI/BuildKit-based building

`D` — [Apptainer 1.5.0 release notes](https://apptainer.org/news/apptainer-1-5-0-20260506/):
1.5.0 added OCI/BuildKit-based building, which `backend_build_image`'s
`dockerfile:$context` build source depends on. An apptainer older than
1.5.0 does not have that build source at all, so `apptainer build
--fakeroot … dockerfile:sandbox/agent` fails deep into the run, inside
apptainer's own error, rather than up front.

`M` — `backend_available` (`functions/apptainer.sh`) folds this into the
same check it already did for "is apptainer installed at all": it reads
`apptainer version`'s first `X.Y.Z` token and returns false, with the
version found and the reason in `BACKEND_UNAVAILABLE_REASON`, if it sorts
below `1.5.0`; a missing `apptainer` binary fails the same way. Every
caller before this used "false" to mean "degrade silently" (the
agent-update check, the commit-message generator); `sandbox.sh`, right
after argv parsing so `-h`/`--help` still works with no apptainer
installed, is the one caller that treats it as fatal and prints the
reason:

```
$ PATH=/tmp/old-apptainer:$PATH ./sandbox.sh claude
sandbox: apptainer 1.3.0 found, sandbox-engine requires 1.5.0 or later: the
image build needs 1.5's OCI/BuildKit-based building
(https://apptainer.org/docs/admin/latest/installation.html)
```

An unparsable `apptainer version` output (a vendor string with no `X.Y.Z`
substring) only warns and proceeds: the check is a best-effort fast-fail,
not a defence against a container escape, so a false negative there is a
worse outcome than letting an untested version through.

## `$HOME` exists only where a bind creates it

`M` — with the shipped flags, `HOME` is set but the host's home is not mounted.
`--home "$HOME"` mounts nothing: it sets the variable (every bind destination in
`functions/agents.sh` is written against it) and names a working directory that
apptainer then cannot enter:

```
$ apptainer exec --containall --no-mount home,cwd,tmp,hostfs,bind-paths --home "$HOME" \
    docker://ubuntu sh -c 'echo "HOME=$HOME"; ls -a "$HOME"'
INFO:    Using cached SIF image
WARNING: Error changing the container working directory. Using '/' instead: chdir /home/kueglerd: no such file or directory
HOME=/home/kueglerd
ls: cannot access '/home/kueglerd': No such file or directory
```

For a path under `$HOME`:

| path under `$HOME` | in-container write |
| --- | --- |
| bound read-write | lands on the host |
| bound read-only | `EROFS` |
| unbound, beside a bind (the bind's scaffolding) | `EROFS` |
| unbound, nothing scaffolds it | `ENOENT` |

`M` — the two unbound rows, measured with `--no-home` in place of
`--no-mount home` (documented as equivalent); afterwards neither probe path
existed on the host:

```
$ apptainer exec --containall --no-home --home "$HOME" docker://ubuntu \
    sh -c 'echo probe > "$HOME/.h11-probe"; cat "$HOME/.h11-probe"; ls -a "$HOME"'
WARNING: Error changing the container working directory. Using '/'
         instead: chdir /home/kueglerd: no such file or directory
/usr/bin/sh: 1: cannot create /home/kueglerd/.h11-probe: Directory nonexistent
cat: /home/kueglerd/.h11-probe: No such file or directory
ls: cannot access '/home/kueglerd': No such file or directory

$ apptainer exec --containall --no-home --home "$HOME" \
    -B /etc/hostname:"$HOME/.h11b/nested/bound" docker://ubuntu \
    sh -c 'echo s > "$HOME/.h11b/nested/sibling"; echo "sibling rc=$?";
           echo p > "$HOME/.h11b/parent";        echo "parent  rc=$?"'
cannot create /home/kueglerd/.h11b/nested/sibling: Read-only file system
sibling rc=2
cannot create /home/kueglerd/.h11b/parent: Read-only file system
parent  rc=2
```

`M` — `--no-mount cwd` keeps the host's working directory out of the container,
whatever `apptainer.conf`'s `mount cwd` says:

```
$ mkdir -p "$HOME/h12-probe" && echo SECRET-CWD > "$HOME/h12-probe/canary" && cd "$HOME/h12-probe"
$ apptainer exec --containall --no-mount home,cwd --home "$HOME" docker://ubuntu \
    sh -c 'pwd; ls -a .; cat ./canary 2>&1; ls -a "$HOME" 2>&1'
INFO:    Using cached SIF image
WARNING: Error changing the container working directory. Using '/' instead: chdir /home/kueglerd: no such file or directory
/
.   .exec  .run    .singularity.d  bin   dev          etc   lib    media  opt   root  sbin         srv  tmp  var
..  .rock  .shell  .test           boot  environment  home  lib64  mnt    proc  run   singularity  sys  usr
cat: ./canary: No such file or directory
ls: cannot access '/home/kueglerd': No such file or directory
```

## `/tmp` needs its own bind

`M` — `--writable-tmpfs` gives 64 MiB in total, shared by `/` and `/tmp`: inside
a live agent, `df` reported `tmpfs 64M 64M 0 100% /tmp`. `D` — the size is
`sessiondir max size` in `apptainer.conf`, which is root-owned and has no flag
or environment override.

`M` — `--overlay` does not help `/tmp`, because `--contain` (implied by
`--containall`) mounts a fresh tmpfs over `/tmp` and `/var/tmp`, and that mount
wins over the overlay:

```
$ apptainer exec --containall --no-home --overlay /tmp/ov-test <sif> \
    sh -c 'dd if=/dev/zero of=/tmp/big bs=1M count=200; df -h /tmp /'
67096576 bytes (67 MB, 64 MiB) copied
tmpfs            64M   64M     0 100% /tmp
fuse-overlayfs    31G   80M   31G   1% /
```

So the launch line has no writable layer (`/` is the image's read-only rootfs)
and binds a per-run host directory at `/tmp` (`functions/run-dir.sh`).

## A bind-mounted file cannot be replaced by rename

`M` — a program that saves by writing a temporary file next to the target and
renaming it over the target fails with `EBUSY` when the target is a
single-file bind. The mount point refuses the rename, not a read-only flag.
omp's settings save, against a `config.yml` bound as a file:

```
Error: Failed to save pending settings: EBUSY: resource busy or locked,
rename '/home/<user>/.omp/agent/config.yml.14.<uuid>.tmp' -> '/home/<user>/.omp/agent/config.yml'
```

That is why omp's `config.yml` is a plain file inside a per-run directory
(`functions/omp-home.sh`) instead of a bind. The same holds for every
by-name bind of a file the CLI saves through a rename.

## A file saved beside itself needs a writable directory

`D` — claude 2.1.281 (its bundled source) never writes `~/.claude.json` or
`~/.claude/.credentials.json` in place. Each save creates a lock directory
beside the file (`~/.claude.json.lock`; for the credentials,
`~/.claude/.storage-write.lock`, retried ten times), writes
`<file>.tmp.<suffix>` beside it, and renames that over the file. When the
rename fails with `EBUSY` (or `EXDEV`, `EPERM`, `EEXIST`) it rewrites the target
in place, so a bind-mounted target is fine, but only once the temporary file
exists. A temporary file that cannot be created is not retried in place, and
the save fails.

`M` — with both files bound by name, their directories are the bind's
read-only scaffolding (above), and every save failed. A login completed, and
`~/.claude/.credentials.json` still held the `{}` the sandbox had created:

```
$ ./sandbox.sh claude --debug-file "$PWD/claude-debug.log"    # log in, reach the prompt, /exit
$ grep -nE 'EROFS|Failed to save|storage-write|Config fallback' claude-debug.log | head -20
19:2026-09-24T19:07:55.258Z [ERROR] Failed to save config with lock: Error: EROFS: read-only file system, mkdir '/home/kueglerd/.claude.json.lock'
22:2026-09-24T19:07:55.263Z [ERROR] Failed to write file atomically: Error: EROFS: read-only file system, open '/home/kueglerd/.claude.json.tmp.14.c7147590b422'
24:2026-09-24T19:07:55.263Z [ERROR] Config fallback write also failed; continuing without persisting: Error: EROFS: read-only file system, open '/home/kueglerd/.claude.json.tmp.14.c7147590b422'
$ wc -c ~/.claude/.credentials.json
2 /home/kueglerd/.claude/.credentials.json
```

That is why a claude run's `$HOME` is a per-run directory
(`functions/claude-home.sh`): lock and temporary files land there, and the
rename onto the bound `.credentials.json` falls back to the in-place write.

`D` — apptainer's source (`internal/pkg/util/fs/mount/mount_linux.go`,
`internal/pkg/util/fs/layout/manager.go`) supports that layering. User binds
are mounted shallowest destination first, whatever their order on the
command line. A missing destination under a user bind of a host directory is
created inside that host directory ("force the creation of the destination
directory in the right parent directory (nested binds)"). A per-run `$HOME`
therefore gets the checkout's and every other nested bind's mount points in
`$RUN_DIR`, never in the host's `$HOME`.

## No gVisor through apptainer

`D` — [apptainer's OCI runtime support](https://apptainer.org/docs/user/main/oci_runtime.html):
the `oci` command group requires root and is documented as deprecated. Apptainer
has no flag that selects a different low-level runtime. A gVisor launch path
therefore has to run the unpacked image with `runsc` itself, next to apptainer
rather than through it.

## Image builds reuse the builder's layer cache and drop `--build-arg`

`D` — apptainer 1.5.3, `internal/pkg/build/sources/conveyorPacker_buildkit.go`:
a `dockerfile:DIR` build runs `buildctl build` when `buildctl` is on `PATH` and
`docker build --quiet` otherwise, neither with `--no-cache`. Build args are read
only from a definition file's `buildargs:` header. For a URI spec,
`MakeAllDefs` (`internal/pkg/build/build.go`) returns
`NewDefinitionFromURI(spec)`, a definition holding just `bootstrap` and `from`,
and never consults the `--build-arg` map, so no `--build-arg` reaches the
Dockerfile.

`M` (2026-09-30) — on a host with docker and no `buildctl` (`$img` is the omp
image's SIF), the image lacks the build log that only the `buildctl` path
writes, and docker's cache holds one omp install layer per distinct parent
layer, some served to later builds (a usage count of 3 is one build plus two
cache hits):

```
$ command -v buildctl docker
/usr/bin/docker
$ apptainer exec --containall "$img" sh -c 'omp --version; ls -l /.singularity.d/buildkit_build.log'
omp/18.4.4
ls: cannot access '/.singularity.d/buildkit_build.log': No such file or directory
$ docker buildx du --verbose | awk -v RS= -v ORS='\n\n' '/install\.sh/'
[...]
ID:           ceciadry6cwzwaqlt7ueeilxj
Parents:
 - mlps3gmuh1xjfd3n1587gixih
Created at:   2026-09-15 16:38:07.100642932 +0000 UTC
Mutable:      false
Reclaimable:  true
Shared:       true
Size:         400.8MB
Description:  mount / from exec /bin/sh -c export PI_INSTALL_DIR="/usr/local/omp/bin" ;     curl -fsSL https://omp.sh/install.sh | sh ;
Usage count:  3
Last used:    2 weeks ago
Type:         regular
[...]
```

`M` (2026-09-30), consistent with the dropped build args: a direct `docker build`
of the same generated Dockerfile with the four `--build-arg`s `build_images`
passes (`USERNAME`, `UID`, `GID`, `AGENT`) took the `RUN`s before the
template's `ARG USERNAME`/`UID`/`GID` from cache but re-ran the first `RUN`
after them, which that morning's apptainer build had cached under the ARGs'
defaults:

```
$ docker build --progress=plain --platform linux/amd64 --build-arg USERNAME="$USER" \
    --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" --build-arg AGENT=omp \
    -f sandbox/agent/Dockerfile sandbox/agent
[...]
#5 [base 2/4] RUN apt-get update     && apt-get install -y --no-install-recommends shellcheck dash ksh     && rm -rf /var/lib/apt/lists/*
#5 CACHED
[...]
#7 [base 4/4] RUN apt-get update     && apt-get install -y --no-install-recommends curl ca-certificates gnupg poppler-utils imagemagick git     && rm -rf /var/lib/apt/lists/*
#7 1.272 Get:1 http://deb.debian.org/debian bookworm InRelease [151 kB]
```

So with the Dockerfile text and the base image unchanged, a rebuild's agent
install comes from the cache, holding whatever release was current when that
layer was first built. `generate_dockerfile` (`functions/environment.sh`)
writes a fresh id into the template's first `RUN` for every build, textually
like `$BASE_IMAGE` because a build arg would not arrive. `D` — a `RUN` layer's
cache key covers its command text and its parent, so that layer and every
later one (packages, agent install) miss the cache; the base stage before it
(a preset's or a custom Dockerfile) stays cacheable. The id stays in the image
as `/etc/sandbox-engine-build-id`, and `docker buildx du` then lists one new
install-layer record per build, with usage count 1.

## Which builder a build reaches, and how it can be remote

`D` — apptainer 1.5.3 source, read 2026-11-06; nothing in this section has
been exercised against a remote daemon.

**Client selection** (`buildImage`, `conveyorPacker_buildkit.go`). If
`buildctl` is on `PATH` and `DOCKER_BUILDKIT` is empty or unset, the build
runs `buildctl build`. If `buildctl` is missing, or `DOCKER_BUILDKIT` has any
non-empty value (including `0`), it runs `docker build` and then
`docker save`. If neither binary is on `PATH`, the build fails with
`neither "buildctl" nor "docker" could be found in the PATH`.

**The host environment reaches the client.** `--fakeroot` re-executes the
build in a user namespace, with `Envs: os.Environ()`
(`fakerootExec`, `cmd/internal/cli/build_linux.go`). Both clients inherit
the calling shell's environment. `backend_build_image`
(`functions/apptainer.sh`) neither sets nor clears any builder variable, so
`BUILDKIT_HOST` and `DOCKER_HOST` exported before `sandbox.sh` reach the
client unchanged.

**`buildctl` path.** The daemon address comes from `--buildkit-host`
(`cmd/internal/cli/apptainer.go`, env key `BUILDKIT_HOST`). When that is
empty and `BUILDKIT_HOST` is unset, the build requires
`/run/buildkit/buildkitd.sock` to exist. `buildkitBuild` passes no `--tls*`
flag, and `buildctl` reads TLS settings only from flags
(`cmd/buildctl/main.go`, moby/buildkit). A `tcp://` `BUILDKIT_HOST` therefore
connects in plaintext and unauthenticated. `BUILDKIT_HOST` also accepts
`unix://` and the connection helpers `ssh://`, `docker-container://`,
`podman-container://`, `nerdctl-container://` and `kube-pod://`
(`client/connhelper/`, moby/buildkit).

**`docker` path.** `buildImage` sets `DOCKER_CONFIG` to a temporary
directory. That directory holds only a registry-auth `config.json` and
symlinks to `~/.docker/cli-plugins` and `~/.docker/buildx`. It has no
`contexts/` directory, so a context chosen with `docker context use` (stored
in `~/.docker/config.json`) does not apply to `docker build`. `docker save`
runs with the unmodified environment, so it would see that context, and the
two commands could then reach different daemons. `DOCKER_HOST` is read from
the environment by both commands. The docker CLI defaults `DOCKER_CERT_PATH`
to the config directory (`InstallFlags`, `cli/flags/options.go`,
docker/cli). Under the replaced `DOCKER_CONFIG`, a TLS connection finds no
certificates unless `DOCKER_CERT_PATH` is set. `docker save` requires the
built image to be in the daemon's image store. A buildx builder with a
non-`docker` driver does not put it there unless it loads the image.

**`ssh://` addresses run inside the fakeroot namespace.** Both clients
implement `ssh://` by executing the `ssh` binary, which inside the build runs
as uid 0 of the user namespace. OpenSSH locates `~/.ssh` (config,
`known_hosts`, keys) through the passwd entry of the current uid, not
`$HOME`. The namespace's uid 0 resolves to `/root`, so the user's own SSH
configuration and host keys are not found. An `ssh -L` forward to a local
Unix socket, started by the user before the build, avoids this: the client
then connects through `unix://`, and the namespace's uid 0 maps to the
socket owner's uid.

**What the builder receives and returns.** The build context is
`sandbox/agent/`, which holds the generated `Dockerfile`. In `dockerfile`
mode, that file embeds the project Dockerfile's text. The builder returns
the image every session of that `<agent>.<env-tag>.sif` then runs. A builder
that is not trustworthy, or a connection that is not authenticated,
therefore decides the content of the sandbox's root filesystem.
