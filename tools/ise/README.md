# Building the core with ISE 14.7

The core is built with Xilinx ISE 14.7 (XST) for the Spartan-6 XC6SLX25-FTG256-2, in a
Linux virtual machine with ISE installed (for example the AMD/Xilinx ISE 14.7 VM image).
One script builds one board in the working copy:

```sh
bash tools/ise/guest/build.sh go      # or mini, minig
```

| Board | Project | Top | Constraints | Bitstream |
| --- | --- | --- | --- | --- |
| `go` | `src/Radio-86RK.xise` | `radio86rk` | `src/pins.ucf` | `src/radio86rk.bin` |
| `mini` | `src/Radio-86RK-mini.xise` | `radio86rk_mini` | `src/pins_mini.ucf` | `src/radio86rk_mini.bin` |
| `minig` | `src/Radio-86RK-minig.xise` | `radio86rk_minig` | `src/pins_minig.ucf` | `src/radio86rk_minig.bin` |

## Repositories side by side

Dependencies are referenced by relative paths and are expected next to this repository,
on the same level:

```
<parent>/
  karabas-go-core-rk86/   this repository
  karabas-go-tools/       make_core/make_core.py: packs the .bin files and the ROMs into src/radio86rk.kg
                          (src/make_core.py is a link to ../../karabas-go-tools/make_core/make_core.py)
```

The bitstream itself needs only this repository; `karabas-go-tools` is needed for the
`.kg` packaging.

## What a build does

1. `regen_cores.sh` generates every Coregen core of the project. The inputs of each core,
   `<core>.xco` and `coregen.cgp`, are tracked in `src/ipcore/`; the generated cores go to
   `src/ipcore_dir/` (ignored), the paths the `.xise` refers to. COE files are referenced
   relative to the `.xco` (`src/roms/FONT.coe`, `src/rtl/osd/osd_font.coe`).
2. `xtclsh` runs "Generate Programming File" with `rerun_all` on the unchanged project:
   XST, Translate, Map, Place & Route, TRCE, BitGen. The project's Working Directory is
   `build/ise/<board>/`, so every ISE output lands there and not next to the sources.
3. The bitstream is copied to `src/<top>.bin`.

Logs are in `build/logs/<board>/` (`coregen/*.log`, `xtclsh.log`,
`project_properties.txt`), temporary files in `build/tmp/`. All of `build/` is ignored.

After a build `git status` is clean, unless the bitstream changed: `src/*.bin` are
tracked, and a changed `.bin` is committed together with the change that caused it.

## In the VM

```sh
git clone https://github.com/andykarpov/karabas-go-core-rk86
git clone https://github.com/andykarpov/karabas-go-tools      # only for the .kg packaging
cd karabas-go-core-rk86
bash tools/ise/guest/build.sh go
```

`build.sh` sources `/opt/Xilinx/14.7/ISE_DS/settings64.sh`; another installation is given
with `ISE_SETTINGS=<path>/settings64.sh`. A license accepted by MAP for `xc6slx25` is
needed: XST, Coregen and NGDBuild run without one, MAP stops with `ERROR:Security:9c` /
`ERROR:Map:258`. The license shipped in the AMD VM image is node-locked to the MAC address
of the first network adapter in the image's `.ovf`; an import that generates new MAC
addresses has to keep them (`VBoxManage import ... --options keepallmacs`) or the adapter
MAC has to be set back to the `.ovf` value.

## From a host checkout through a shared folder

The sources can stay on the host (for example Windows) and be built in the VM: share
the parent directory of the repositories with the VM, so that the side-by-side layout
is the same in the guest.

```sh
# host (VirtualBox): add the shared folder, or use Settings > Shared Folders
VBoxManage sharedfolder add <vm> --name projects --hostpath <parent> --automount

# guest, as root, when the folder is not mounted automatically
mkdir -p /media/sf_projects
mount -t vboxsf -o uid=$(id -u ise),gid=$(getent group vboxsf | cut -d: -f3) projects /media/sf_projects

# guest, as the ISE user
cd /media/sf_projects/karabas-go-core-rk86
bash tools/ise/guest/build.sh go
```

- Call the scripts through `bash`: a shared folder has no executable bits.
- `.gitattributes` turns off line-ending conversion, so a Windows checkout has the same
  bytes as the repository whatever `core.autocrlf` is.
- A shared folder is slower than the guest disk: a build takes about 20 minutes on one
  virtual CPU.

## In the ISE GUI

```sh
source /opt/Xilinx/14.7/ISE_DS/settings64.sh
bash tools/ise/guest/regen_cores.sh src/Radio-86RK.xise   # generates the cores, creates build/ise/go
ise &
```

Open `src/Radio-86RK.xise` (or `-mini`, `-minig`), select the top module and run
"Generate Programming File". The bitstream is written to `build/ise/<board>/`; copy it to
`src/` (or build with `build.sh`, which does both). Decline project or core upgrades
offered by ISE. Regenerate the cores with `regen_cores.sh`, not with "Regenerate Core"
in the GUI: that process skips cores whose wrappers exist.

To change a core, edit it in Coregen from `src/ipcore_dir/` and copy the changed `.xco`
back to `src/ipcore/`, keeping the relative `coe_file` path.

## Reproducibility

Builds of the same commit with the same ISE 14.7 profile give the same bitstream, byte
for byte; the location of the checkout does not matter. Reference SHA256 of the
bitstreams of commit 10ff7fd (equal to the committed release files):

| Board | SHA256 |
| --- | --- |
| Go | `119827fd3c602181cb5a0409c58baf153bd013d7668667a79e940989203e4af5` |
| Mini | `a7acac5902d299b65da8d800f8ea4c3b6fc9de58d094b4366da59c77e2f9d7cd` |
| Mini G | `9e839cfc955ee9d989e9fccad8275ecd25e695a125fca23ff7bf206565c238e2` |

A successful build and an unchanged bitstream show that the configuration was
preserved; they do not show that the core works on a board.
