# fire

run [firecracker](https://github.com/firecracker-microvm/firecracker) microVMs on macOS apple silicon. no fuss.

firecracker needs KVM. macOS doesn't have KVM. this repo bridges the gap with a transparent [lima](https://lima-vm.io) VM layer so you never have to think about it.

```
macOS (apple silicon)
  └── lima VM (Virtualization.framework, nested virt)
        └── KVM
              └── firecracker microVM ← you are here
```

## requirements

| what | why |
|------|-----|
| **apple silicon mac (M3+)** | nested virtualization requires M3 or later. M1/M2 won't work. |
| **macOS 15+** | Virtualization.framework with nested virt support |
| **[homebrew](https://brew.sh)** | `fire setup` auto-installs everything else via brew |
| **~10 GB disk** | lima VM + kernel + base rootfs |

you do **not** need to install lima, jq, or anything else manually. `fire setup` handles all of it.

## install

### homebrew (recommended)

```bash
brew tap sigkillme0/fire
brew install fire
fire setup              # one-time: creates lima VM, downloads firecracker (~5 min)
```

### from source

```bash
git clone https://github.com/sigkillme0/fire.git
cd fire
make setup              # installs deps, symlinks fire, creates lima VM (~5 min)
```

## quickstart

```bash
fire create myvm        # create a microVM (2 vcpu, 512M ram)
fire start myvm         # boot it (~6 seconds)
fire ssh myvm           # you're in
```

that's it. `brew install` + `fire setup` + three commands, and you're inside a firecracker microVM on your mac.

## uninstall

```bash
fire vm delete          # delete the lima VM and all microVMs
brew uninstall fire     # remove fire (or: make uninstall)
brew untap sigkillme0/fire
```

## commands

### microVM lifecycle

```bash
fire create <name> [vcpus] [mem] [disk]   # create a VM (default: 2 cpu, 512M, 2G disk)
fire start  <name>                         # start a VM (re-validates budget)
fire stop   <name>                         # stop a VM
fire ssh    <name> [cmd...]                # ssh in, or run a remote command
fire destroy <name>                        # stop + delete a VM permanently
```

### microVM introspection

```bash
fire status [name]   # show status (one VM or all)
fire list            # list all VMs
fire logs <name> [-f] # view/tail console log
```

### resource management

```bash
fire resources                                   # 3-layer resource dashboard (host → lima → microVMs)
fire resize <name> [--cpus N] [--mem N] [--disk N] # resize a microVM (must be stopped)
```

### lima host VM

```bash
fire vm start                                    # start the underlying lima VM
fire vm stop                                     # stop it (kills all running microVMs!)
fire vm shell                                    # drop into the lima VM shell
fire vm status                                   # show lima VM info
fire vm resize [--cpus N] [--mem N] [--disk N]   # resize lima VM (validates all constraints)
fire vm delete                                   # nuke the lima VM entirely
```

### other

```bash
fire setup        # bootstrap everything (idempotent)
fire version      # show version and state info
fire help         # command reference
```

## what `fire setup` does

on a fresh mac, `fire setup` will:

1. **check your chip** — verifies M3 or later (M1/M2 will be rejected with a clear error)
2. **install lima** — `brew install lima` if not already installed (skipped if installed via `brew install fire`)
3. **install jq** — `brew install jq` if not already installed (skipped if installed via `brew install fire`)
4. **create the lima VM** — downloads ubuntu, enables nested virtualization, provisions firecracker, kernel, and rootfs inside it

everything is idempotent — running `fire setup` again skips what's already done.

## examples

```bash
# create a beefy VM with 4 cpus, 2G ram, 8G disk
fire create bigbox 4 2048 8192

# run a command without interactive shell
fire ssh myvm "uname -a"

# internet works out of the box (via proxy)
fire ssh myvm "curl -s https://example.com | head -5"

# apt uses apt-fast + aria2 under the hood (16 parallel connections)
fire ssh myvm "apt-get update && apt-get install -y htop"

# spin up multiple VMs
fire create web 2 512
fire create db 2 1024
fire start web
fire start db
fire list

# see the full resource picture
fire resources

# resize a stopped VM
fire stop db
fire resize db --cpus 4 --mem 2048 --disk 4096
fire start db

# give lima more juice (requires restart, prompts for confirmation)
fire vm resize --cpus 8 --mem 16384
```

## how it works

### the stack

1. **`fire`** (macOS) — the only command you interact with. checks prerequisites, manages the lima VM, enforces host-level resource constraints, and transparently proxies microVM commands into the VM.

2. **lima VM** — an ubuntu VM running on Virtualization.framework with `nestedVirtualization: true`. provides `/dev/kvm`. provisioned automatically with firecracker, kernel, rootfs, and networking tools.

3. **`fcctl`** (internal, linux) — lives in `lib/`, auto-deployed into the lima VM by `fire`. creates tap devices, configures networking, launches firecracker processes, manages lifecycle, enforces VM-level resource budgets. you never run this directly.

4. **firecracker** — AWS's microVM monitor. boots a linux kernel with a rootfs in ~125ms on bare metal, ~6s through our nested stack.

### resource budget system

resources are tracked across 3 layers with hard constraints that prevent OOM and disk-full scenarios:

```
HOST (Apple M4 Pro, 14 cores, 48G RAM)
  ├── 8G reserved for macOS (non-negotiable)
  └── LIMA VM (4 cores, 4G RAM, 100G disk)
        ├── 1G reserved for lima OS (kernel, systemd, networking services)
        ├── 5G disk reserved for system (kernel image, base rootfs, apt cache)
        └── microVMs
              ├── vm1:  2 vcpu, 512M ram, 2G disk
              └── vm2:  2 vcpu, 1024M ram, 2G disk
              TOTAL:    4 vcpu, 1.5G ram, 4G disk
              CEILING:  4 vcpu, 3G ram,   95G disk
```

**hard constraints** (violating = crash):
- `sum(vm.mem) + 1G OS reserve <= lima.mem` — prevents OOM inside lima
- `sum(vm.disk) + 5G reserve <= lima.disk` — prevents disk full
- `lima.mem + 8G host reserve <= host.mem` — keeps macOS responsive
- `lima.cpus <= host.cpus` — can't exceed physical cores

**soft constraints** (warn but allow):
- CPU overcommit across microVMs is allowed with a warning

every `create`, `start`, `resize`, and `vm resize` validates the full constraint set before proceeding. if it would violate a hard constraint, it dies with a clear explanation of what's over budget and why.

### networking

this was the hard part. Apple's Virtualization.framework NAT (vzNAT) silently drops kernel-forwarded TCP packets — only locally-originated TCP from the VM's own stack gets through. ICMP works, TCP doesn't. this is not a bug you can fix with iptables.

**solution:** userspace proxy stack per microVM:

```
microVM guest
  → tinyproxy (HTTP/HTTPS proxy on host tap interface)
    → lima VM makes real TCP connection (locally originated, VZ allows it)
      → vzNAT → internet
  → dnsmasq (DNS forwarder on host tap interface)
    → forwards to 8.8.8.8/8.8.4.4
```

each microVM gets its own isolated `/30` point-to-point subnet:

```
VM "myvm" (id=148):
  tap148:  172.16.148.1/30  (lima-side)
  guest:   172.16.148.2/30  (microVM-side)
  dns:     172.16.148.1:53
  proxy:   172.16.148.1:9036
```

proxy environment variables are baked into the guest rootfs during `create`, so `curl`, `apt`, `wget` etc. work transparently.

### rootfs

the base rootfs is ubuntu 24.04 converted from squashfs (firecracker CI) to ext4. each `fire create` copies this 2GB image (or creates a larger one if `disk` is specified) and configures:

- static IP (systemd-networkd)
- hostname
- DNS resolver → dnsmasq on host tap
- proxy env vars → tinyproxy on host tap
- root password: `root` (SSH enabled)
- `apt-fast` + `aria2` (parallel package downloads — transparently replaces `apt`/`apt-get`)

disk can be grown after creation via `fire resize <name> --disk N`. shrinking is not supported (too dangerous for ext4).

### VM ID derivation

VM names are hashed to a deterministic ID (1–253) via `cksum | mod 253 + 1`. this ID drives the tap device number, subnet, proxy port, and MAC address. collisions are detected at create time and rejected.

## known limitations

| limitation | detail | workaround |
|-----------|--------|------------|
| **HTTP/HTTPS only** | vzNAT blocks forwarded TCP. only proxied HTTP/HTTPS works. | use `fire vm shell` and add `socat` relays for specific ports |
| **no raw TCP/UDP** | database connections, custom protocols won't work from inside the guest to the internet | run services inside the microVM or use socat port forwarding |
| **no jailer** | firecracker's jailer conflicts with ubuntu's apparmor | acceptable for dev. don't use this in production. |
| **root:root SSH** | guest auth is password-based | inject SSH keys into rootfs for production use |
| **no snapshots** | firecracker supports it, not wired up yet | — |
| **no graceful shutdown on ARM** | `SendCtrlAltDel` unsupported on aarch64 | VMs are killed with SIGTERM/SIGKILL |
| **no disk shrink** | ext4 shrink is dangerous, only growth supported | plan ahead or recreate the VM |
| **VM ID collisions** | hash mod 253 can collide on different names | detected at create time and rejected |
| **M3+ only** | nested virtualization requires M3 chip or later | M1/M2 users are out of luck (use docker instead) |
| **lima resize restarts VM** | changing lima CPU/mem requires a full stop/start | all running microVMs are killed, must be restarted |

## troubleshooting

### `fire setup` hangs or fails

```bash
# check if lima can create VMs at all
limactl create --name test template://default
limactl delete test

# check nested virt support (must be M3+)
sysctl kern.hv_support  # should return 1
```

### microVM won't start

```bash
# check console log
fire logs myvm

# check if KVM is available inside lima
fire vm shell
ls -la /dev/kvm

# if /dev/kvm is missing, nested virt isn't working
# verify your chip: M3, M3 Pro, M3 Max, M4, etc.
```

### can't reach internet from inside the microVM

```bash
# verify proxy is running
fire vm shell
ps aux | grep tinyproxy

# test DNS
fire ssh myvm "nslookup example.com"

# test proxy manually
fire ssh myvm "source /etc/environment && curl -v https://example.com"
```

### SSH connection refused

```bash
# VM might still be booting — wait for it
fire ssh myvm "echo ok"

# check if sshd is running
fire logs myvm | grep ssh
```

### `fire setup` or `make setup` fails on a fresh mac

```bash
# if homebrew isn't installed:
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# then:
brew tap sigkillme0/fire && brew install fire
fire setup

# or from source without make:
./bin/fire setup
```

### M1/M2 mac — "incompatible hardware"

nested virtualization requires M3 or later. there is no workaround. on M1/M2, use docker or UTM instead.

### publishing the homebrew tap

to host your own tap, create a repo named `homebrew-fire` with the formula:

```bash
# create the tap repo
mkdir homebrew-fire && cd homebrew-fire
git init
mkdir Formula
cp /path/to/fire/Formula/fire.rb Formula/

# update the sha256 in the formula after tagging a release:
shasum -a 256 /path/to/v1.0.0.tar.gz

git add . && git commit -m "fire 1.0.0"
git remote add origin git@github.com:<you>/homebrew-fire.git
git push -u origin main
```

then users install with `brew tap <you>/fire && brew install fire`.

## file layout

```
fire/
├── README.md
├── Makefile                         # make install / make setup
├── Formula/
│   └── fire.rb                      # homebrew formula
├── bin/
│   └── fire                         # the only command you run
├── lib/
│   └── fcctl                        # internal — auto-deployed into the lima VM
├── lima/
│   └── firecracker.yaml             # lima VM template
└── firecracker-setup.txt            # original research notes

inside the lima VM:
  /opt/firecracker/vmlinux           # arm64 kernel
  /opt/firecracker/rootfs.ext4       # base ubuntu 24.04 rootfs (2GB)
  /usr/local/bin/firecracker         # firecracker v1.14.1
  /usr/local/bin/fcctl               # auto-synced from lib/fcctl by fire
  /srv/firecracker/<name>/           # per-VM directory
    ├── rootfs.ext4                  # VM's own rootfs copy
    ├── vm_config.json               # firecracker config
    ├── metadata                     # VM metadata
    ├── pid                          # firecracker PID (when running)
    ├── console.log                  # serial console output
    └── firecracker.socket           # API socket (when running)
```

## performance

| metric | value |
|--------|-------|
| boot time (create → ssh-ready) | ~6 seconds |
| ping latency (lima → guest) | 1–3 ms |
| HTTP via proxy | ~300 ms |
| HTTPS via CONNECT | ~350–500 ms |
| rootfs size | 2 GB per VM |
| memory overhead | lima VM: 8 GB + per-microVM allocation |

## license

MIT

## acknowledgments

built on top of [firecracker](https://github.com/firecracker-microvm/firecracker) by AWS and [lima](https://github.com/lima-vm/lima).