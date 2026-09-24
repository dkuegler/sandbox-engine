# Apptainer: behaviour the launch line relies on

Last verified: 2026-09-24.

The launch line is `APPTAINER_EXEC` in `functions/apptainer.sh`:
`apptainer exec --containall --no-mount home,cwd,tmp,hostfs,bind-paths`, plus
`--home "$HOME"`, a `/tmp` bind and the run's own binds. Flag and directive
reference: [`apptainer exec`](https://apptainer.org/docs/user/latest/cli/apptainer_exec.html),
[bind paths and mounts](https://apptainer.org/docs/user/latest/bind_paths_and_mounts.html),
[`apptainer.conf`](https://apptainer.org/docs/admin/latest/configfiles.html).

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

## No gVisor through apptainer

`D` — [apptainer's OCI runtime support](https://apptainer.org/docs/user/main/oci_runtime.html):
the `oci` command group requires root and is documented as deprecated. Apptainer
has no flag that selects a different low-level runtime. A gVisor launch path
therefore has to run the unpacked image with `runsc` itself, next to apptainer
rather than through it.
